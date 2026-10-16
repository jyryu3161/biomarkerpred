//! The same process primitive is used by CLI calls, doctor, and cancellation tests.
use super::{engine_types::EngineEvent, hide_console};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    io::{BufRead, BufReader, Read},
    path::PathBuf,
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU32, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

pub type EventSink = Arc<dyn Fn(EngineEvent) + Send + Sync>;
#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub job_id: String,
    pub operation: String,
    pub phase: String,
    pub last_event: Option<Value>,
    pub response: Option<super::engine_types::EngineResponse>,
}
pub struct Job {
    pub id: String,
    pub operation: String,
    pub cancel: AtomicBool,
    pub pid: AtomicU32,
    pub target: Mutex<Option<ProcessTarget>>,
    pub snapshot: Mutex<Snapshot>,
    pub run_dirs: Mutex<Vec<PathBuf>>,
    pub locks: Mutex<Vec<(PathBuf, Value)>>,
}
impl Job {
    pub fn new(id: String, operation: String) -> Self {
        Self {
            target: Mutex::new(None),
            snapshot: Mutex::new(Snapshot {
                job_id: id.clone(),
                operation: operation.clone(),
                phase: "starting".into(),
                last_event: None,
                response: None,
            }),
            id,
            operation,
            cancel: AtomicBool::new(false),
            pid: AtomicU32::new(0),
            run_dirs: Mutex::new(Vec::new()),
            locks: Mutex::new(Vec::new()),
        }
    }
}
#[derive(Default)]
pub struct JobRegistry {
    inner: Mutex<(Option<String>, HashMap<String, Arc<Job>>)>,
    used: Mutex<HashSet<String>>,
    recent: Mutex<VecDeque<String>>,
}
impl JobRegistry {
    pub fn reserve(&self, id: &str, operation: &str) -> Result<Arc<Job>, String> {
        if id.is_empty()
            || id.len() > 100
            || !id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"-_".contains(&c))
        {
            return Err(
                "jobId must contain 1–100 ASCII letters, digits, hyphens or underscores".into(),
            );
        }
        let mut state = self.inner.lock().map_err(|e| e.to_string())?;
        if let Some(active) = &state.0 {
            return Err(format!("A mutating job is already active: {active}"));
        }
        if self.used.lock().unwrap().contains(id) {
            return Err("jobId has already been used; create a new ID".into());
        }
        let job = Arc::new(Job::new(id.into(), operation.into()));
        self.used.lock().unwrap().insert(id.into());
        state.0 = Some(id.into());
        state.1.insert(id.into(), job.clone());
        Ok(job)
    }
    pub fn get(&self, id: &str) -> Result<Arc<Job>, String> {
        self.inner
            .lock()
            .map_err(|e| e.to_string())?
            .1
            .get(id)
            .cloned()
            .ok_or_else(|| "Unknown jobId".into())
    }
    pub fn cancel(&self, id: &str) -> Result<(Arc<Job>, bool), String> {
        let state = self.inner.lock().map_err(|e| e.to_string())?;
        let job = state.1.get(id).cloned().ok_or("Unknown or expired jobId")?;
        let mut retry = false;
        {
            let mut snapshot = job.snapshot.lock().unwrap();
            if snapshot.phase != "finished" {
                job.cancel.store(true, Ordering::SeqCst);
                retry = snapshot.phase == "cancellation_unverified";
                snapshot.phase = "cancelling".into();
            }
        }
        Ok((job, retry))
    }
    pub fn finish(
        &self,
        job: &Job,
        mut response: super::engine_types::EngineResponse,
    ) -> super::engine_types::EngineResponse {
        let mut state = self.inner.lock().unwrap();
        if state.0.as_deref() != Some(&job.id) {
            return response;
        }
        // Serialized with cancel(): no acknowledged cancellation can be replaced
        // by a late successful completion, even after the child drained instantly.
        if job.cancel.load(Ordering::SeqCst) {
            response.success = false;
            response.cancelled = true;
        }
        {
            let mut s = job.snapshot.lock().unwrap();
            s.phase = "finished".into();
            s.response = Some(response.clone());
        }
        state.0 = None;
        let mut recent = self.recent.lock().unwrap();
        recent.push_back(job.id.clone());
        while recent.len() > 32 {
            if let Some(id) = recent.pop_front() {
                state.1.remove(&id);
            }
        }
        response
    }
    pub fn active(&self) -> Option<Snapshot> {
        let state = self.inner.lock().unwrap();
        state
            .0
            .as_ref()
            .and_then(|id| state.1.get(id))
            .map(|j| j.snapshot.lock().unwrap().clone())
    }
}
#[derive(Clone)]
pub struct DockerProcess {
    pub executable: String,
    pub name: String,
}
#[derive(Clone)]
pub struct ProcessTarget {
    pub pid: u32,
    pub docker: Option<DockerProcess>,
    pub start_identity: Option<String>,
}
fn process_identity(pid: u32) -> Option<String> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat.rsplit_once(") ")?
        .1
        .split_whitespace()
        .nth(19)
        .map(str::to_owned)
}
#[derive(Debug)]
pub struct ProcessOutput {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: Vec<String>,
    pub cancelled: bool,
    pub timed_out: bool,
}
pub fn grouped_command(mut command: Command) -> Command {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    hide_console(command)
}
fn bounded_command(command: Command, limit: Duration) -> Result<bool, String> {
    let mut child = grouped_command(command)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| e.to_string())?;
    let start = Instant::now();
    loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            return Ok(status.success());
        }
        if start.elapsed() > limit {
            let _ = kill_tree(child.id(), true);
            let _ = child.wait();
            return Err("Container control command timed out".into());
        }
        std::thread::sleep(Duration::from_millis(40));
    }
}
pub fn stop_container(d: &DockerProcess) -> Result<(), String> {
    stop_container_inner(d)
        .map_err(|e| format!("[termination-unverified] Container {}: {e}", d.name))
}
fn stop_container_inner(d: &DockerProcess) -> Result<(), String> {
    let mut stop = Command::new(&d.executable);
    stop.args(["stop", "--time", "2", &d.name]);
    let _ = bounded_command(stop, Duration::from_secs(10));
    // Creation and start are separate. rm --force also removes a confirmed
    // stopped container when cancellation arrives between those two operations.
    let mut remove = Command::new(&d.executable);
    remove.args(["rm", "--force", &d.name]);
    if bounded_command(remove, Duration::from_secs(10))? {
        return Ok(());
    }
    let mut inspect = Command::new(&d.executable);
    inspect.args(["inspect", "--type", "container", &d.name]);
    if !bounded_command(inspect, Duration::from_secs(10))? {
        let mut daemon = Command::new(&d.executable);
        daemon.args(["info", "--format", "{{.ServerVersion}}"]);
        if bounded_command(daemon, Duration::from_secs(10))? {
            return Ok(());
        }
    }
    Err("[termination-unverified] Cannot verify Docker container termination. Restore Docker connectivity and stop the named container before recovering its lock.".into())
}
pub fn kill_tree(pid: u32, force: bool) -> Result<(), String> {
    #[cfg(unix)]
    {
        let result = unsafe {
            libc::kill(
                -(pid as i32),
                if force { libc::SIGKILL } else { libc::SIGTERM },
            )
        };
        if result != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(format!(
                    "[termination-unverified] Cannot signal process group {pid}: {error}"
                ));
            }
        }
    }
    #[cfg(windows)]
    {
        let mut c = Command::new("taskkill");
        c.args(["/PID", &pid.to_string(), "/T"]);
        if force {
            c.arg("/F");
        }
        let status = hide_console(c)
            .status()
            .map_err(|e| format!("[termination-unverified] taskkill failed: {e}"))?;
        if !status.success() {
            return Err(
                "[termination-unverified] taskkill did not confirm tree termination".into(),
            );
        }
    }
    Ok(())
}
#[cfg(unix)]
fn group_alive(pid: u32) -> bool {
    #[cfg(target_os = "linux")]
    {
        if let Ok(entries) = std::fs::read_dir("/proc") {
            return entries.flatten().any(|entry| {
                let Ok(stat) = std::fs::read_to_string(entry.path().join("stat")) else {
                    return false;
                };
                let Some((_, fields)) = stat.rsplit_once(") ") else {
                    return false;
                };
                let f: Vec<_> = fields.split_whitespace().collect();
                f.get(2).and_then(|x| x.parse::<u32>().ok()) == Some(pid)
                    && !matches!(f.first(), Some(&"Z") | Some(&"X"))
            });
        }
    }
    unsafe { libc::kill(-(pid as i32), 0) == 0 }
}
pub fn verify_termination(job: &Job) -> Result<(), String> {
    let target = job.target.lock().unwrap().clone();
    if let Some(ProcessTarget {
        pid,
        docker,
        start_identity,
    }) = target
    {
        let docker_result = docker.as_ref().map(stop_container).transpose();
        // Never signal a reused process/group identifier during delayed recovery.
        if let (Some(original), Some(current)) = (start_identity, process_identity(pid)) {
            if original != current {
                docker_result?;
                *job.target.lock().unwrap() = None;
                return Ok(());
            }
        }
        docker_result?;
        #[cfg(unix)]
        kill_tree(pid, true)?;
        // A successful Docker stop/removal already ended the container tree.
        // Its Windows attach client may have exited before taskkill is called.
        #[cfg(windows)]
        if docker.is_none() {
            kill_tree(pid, true)?;
        }
        #[cfg(unix)]
        {
            let start = Instant::now();
            while group_alive(pid) {
                if start.elapsed() > Duration::from_secs(2) {
                    return Err(format!(
                        "[termination-unverified] Process group {pid} is still alive"
                    ));
                }
                std::thread::sleep(Duration::from_millis(40));
            }
        }
    }
    *job.target.lock().unwrap() = None;
    Ok(())
}
pub fn run_process(
    command: Command,
    job: Arc<Job>,
    timeout: Option<Duration>,
    docker: Option<DockerProcess>,
    on_line: Arc<dyn Fn(&str) + Send + Sync>,
) -> Result<ProcessOutput, String> {
    if job.cancel.load(Ordering::SeqCst) {
        return Ok(ProcessOutput {
            code: None,
            stdout: String::new(),
            stderr: vec![],
            cancelled: true,
            timed_out: false,
        });
    }
    let mut child = grouped_command(command)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Cannot start runtime: {e}"))?;
    job.pid.store(child.id(), Ordering::SeqCst);
    *job.target.lock().unwrap() = Some(ProcessTarget {
        pid: child.id(),
        docker: docker.clone(),
        start_identity: process_identity(child.id()),
    });
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let (out_tx, out_rx) = std::sync::mpsc::channel();
    let (err_tx, err_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut text = String::new();
        let result = BufReader::new(stdout)
            .take(128 * 1024 * 1024)
            .read_to_string(&mut text)
            .and_then(|n| {
                if n >= 128 * 1024 * 1024 {
                    Err(std::io::Error::other(
                        "CLI stdout exceeded the 128 MiB protocol limit",
                    ))
                } else {
                    Ok(text)
                }
            });
        let _ = out_tx.send(result);
    });
    std::thread::spawn(move || {
        let mut tail = VecDeque::new();
        let mut reader = BufReader::new(stderr);
        let mut bytes = Vec::new();
        while reader.read_until(b'\n', &mut bytes).is_ok_and(|n| n > 0) {
            let line = String::from_utf8_lossy(&bytes)
                .trim_end_matches(['\r', '\n'])
                .to_owned();
            bytes.clear();
            on_line(&line);
            if tail.len() == 200 {
                tail.pop_front();
            }
            tail.push_back(line);
        }
        let _ = err_tx.send(tail.into_iter().collect::<Vec<_>>());
    });
    let start = Instant::now();
    let mut cancelled = false;
    let mut timed_out = false;
    let mut termination_error = None;
    let mut status = None;
    let mut exited_at = None;
    let mut terminated_at = None;
    let mut stdout = None;
    let mut stderr = None;
    let mut reader_failed = false;
    loop {
        if stdout.is_none() {
            if let Ok(value) = out_rx.try_recv() {
                match value {
                    Ok(value) => stdout = Some(value),
                    Err(error) => {
                        reader_failed = true;
                        stdout = Some(String::new());
                        termination_error = Some(format!("CLI stdout could not be read: {error}"));
                    }
                }
            }
        }
        if stderr.is_none() {
            if let Ok(value) = err_rx.try_recv() {
                stderr = Some(value);
            }
        }
        if status.is_none() {
            status = child.try_wait().map_err(|e| e.to_string())?;
            if status.is_some() {
                exited_at = Some(Instant::now());
            }
        }
        if status.is_some() && stdout.is_some() && stderr.is_some() {
            if job.cancel.load(Ordering::SeqCst) {
                cancelled = true;
                verify_termination(&job)?;
            }
            break;
        }
        let orphaned = exited_at.is_some_and(|at| at.elapsed() > Duration::from_secs(3));
        if terminated_at.is_none()
            && (job.cancel.load(Ordering::SeqCst)
                || timeout.is_some_and(|t| start.elapsed() > t)
                || orphaned
                || reader_failed)
        {
            cancelled = job.cancel.load(Ordering::SeqCst);
            timed_out = !cancelled && !orphaned && !reader_failed;
            #[cfg(unix)]
            let _ = kill_tree(child.id(), false);
            std::thread::sleep(Duration::from_millis(300));
            if let Err(e) = verify_termination(&job) {
                termination_error = Some(e);
            }
            terminated_at = Some(Instant::now());
            if orphaned && !cancelled && termination_error.is_none() {
                termination_error=Some("Runtime parent exited while a worker held its output pipes; remaining process group was terminated".into());
            }
        }
        if terminated_at.is_some_and(|at| at.elapsed() > Duration::from_secs(5)) {
            return Err(termination_error.unwrap_or_else(||"[termination-unverified] Runtime output pipes did not close after process-tree termination".into()));
        }
        std::thread::sleep(Duration::from_millis(40));
    }
    if let Some(error) = termination_error {
        return Err(error);
    }
    Ok(ProcessOutput {
        code: status.and_then(|s| s.code()),
        stdout: stdout.unwrap_or_default(),
        stderr: stderr.unwrap_or_default(),
        cancelled,
        timed_out,
    })
}

pub fn emit(job: &Job, sink: &EventSink, kind: &str, payload: Value) {
    job.snapshot.lock().unwrap().last_event = Some(json!({"type":kind,"payload":payload}));
    sink(EngineEvent {
        job_id: job.id.clone(),
        operation: job.operation.clone(),
        r#type: kind.into(),
        payload,
    });
}
