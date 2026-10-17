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
#[cfg(not(windows))]
fn process_identity(pid: u32) -> Option<String> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat.rsplit_once(") ")?
        .1
        .split_whitespace()
        .nth(19)
        .map(str::to_owned)
}
#[cfg(windows)]
fn process_identity(pid: u32) -> Option<String> {
    windows_live_process_start(pid).map(|start| start.to_string())
}
#[cfg(windows)]
fn windows_live_process_start(pid: u32) -> Option<u64> {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, FILETIME, WAIT_TIMEOUT},
        System::Threading::{
            GetProcessTimes, OpenProcess, WaitForSingleObject, PROCESS_QUERY_LIMITED_INFORMATION,
            PROCESS_SYNCHRONIZE,
        },
    };
    unsafe {
        let handle = OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
            0,
            pid,
        );
        if handle.is_null() {
            return None;
        }
        let mut created: FILETIME = std::mem::zeroed();
        let mut exited: FILETIME = std::mem::zeroed();
        let mut kernel: FILETIME = std::mem::zeroed();
        let mut user: FILETIME = std::mem::zeroed();
        let valid = WaitForSingleObject(handle, 0) == WAIT_TIMEOUT
            && GetProcessTimes(handle, &mut created, &mut exited, &mut kernel, &mut user) != 0;
        CloseHandle(handle);
        valid
            .then_some((u64::from(created.dwHighDateTime) << 32) | u64::from(created.dwLowDateTime))
    }
}
pub fn job_owns_process(job: &Job, owner_pid: u32) -> bool {
    let root = job.pid.load(Ordering::SeqCst);
    #[cfg(not(windows))]
    return owner_pid != 0 && owner_pid == root;
    #[cfg(windows)]
    {
        use windows_sys::Win32::{
            Foundation::{CloseHandle, GetLastError, ERROR_NO_MORE_FILES, INVALID_HANDLE_VALUE},
            System::Diagnostics::ToolHelp::{
                CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
                TH32CS_SNAPPROCESS,
            },
        };
        let target = job.target.lock().unwrap().clone();
        let Some(target) = target.filter(|target| target.pid == root) else {
            return false;
        };
        if target.start_identity.is_none() || process_identity(root) != target.start_identity {
            return false;
        }
        // Rscript.exe can launch the R process which owns the lock. Require a
        // live, creation-time-ordered ancestry chain to this exact launcher.
        let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
        if snapshot == INVALID_HANDLE_VALUE {
            return false;
        }
        let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        let mut parents = HashMap::new();
        let mut next = unsafe { Process32FirstW(snapshot, &mut entry) };
        while next != 0 {
            parents.insert(entry.th32ProcessID, entry.th32ParentProcessID);
            next = unsafe { Process32NextW(snapshot, &mut entry) };
        }
        let complete = unsafe { GetLastError() } == ERROR_NO_MORE_FILES;
        unsafe {
            CloseHandle(snapshot);
        }
        if !complete {
            return false;
        }
        let mut current = owner_pid;
        let mut child_start = u64::MAX;
        let mut seen = HashSet::new();
        while current != 0 && seen.insert(current) {
            let Some(start) = windows_live_process_start(current) else {
                return false;
            };
            if start > child_start {
                return false;
            }
            if current == root {
                return Some(start.to_string()) == target.start_identity;
            }
            child_start = start;
            let Some(parent) = parents.get(&current) else {
                return false;
            };
            current = *parent;
        }
        false
    }
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
                #[cfg(target_os = "macos")]
                return macos_signal_error(pid, error, || process_table_group_alive(pid));
                #[cfg(not(target_os = "macos"))]
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
#[cfg(any(target_os = "macos", all(test, unix)))]
fn macos_signal_error(
    pid: u32,
    error: std::io::Error,
    inspect: impl FnOnce() -> Result<bool, String>,
) -> Result<(), String> {
    // Darwin can return EPERM for an unreaped zombie-only process group. The
    // errno alone never establishes termination: inspect every group member.
    if error.raw_os_error() == Some(libc::EPERM) && !inspect()? {
        return Ok(());
    }
    Err(format!(
        "[termination-unverified] Cannot signal process group {pid}: {error}"
    ))
}
#[cfg(any(target_os = "macos", all(test, unix)))]
fn parse_group_process_table(table: &str, group: u32, observer: u32) -> Result<bool, String> {
    let invalid = || "[termination-unverified] Invalid or incomplete process table".to_owned();
    let mut found_observer = false;
    let mut alive = false;
    for line in table.lines().filter(|line| !line.trim().is_empty()) {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() != 3 {
            return Err(invalid());
        }
        let pid = fields[0].parse::<u32>().map_err(|_| invalid())?;
        let pgid = fields[1].parse::<u32>().map_err(|_| invalid())?;
        let state = fields[2].as_bytes()[0];
        found_observer |= pid == observer;
        if pgid == group {
            match state {
                b'Z' | b'X' | b'x' => (),
                b'D' | b'I' | b'R' | b'S' | b'T' | b't' | b'U' | b'W' => alive = true,
                _ => return Err(invalid()),
            }
        }
    }
    // An empty/truncated/error response must not be mistaken for an absent group.
    if !found_observer {
        return Err(invalid());
    }
    Ok(alive)
}
#[cfg(any(target_os = "macos", all(test, unix)))]
fn process_table_group_alive(group: u32) -> Result<bool, String> {
    use std::io::{Seek, SeekFrom};
    let inspect = || -> Result<bool, String> {
        // A file avoids blocked output pipes while waiting with a strict timeout.
        let mut output = tempfile::tempfile().map_err(|e| e.to_string())?;
        let mut child = Command::new("/bin/ps")
            .args(["-axo", "pid=,pgid=,stat="])
            .env("LC_ALL", "C")
            .stdin(Stdio::null())
            .stdout(output.try_clone().map_err(|e| e.to_string())?)
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| e.to_string())?;
        let start = Instant::now();
        let status = loop {
            if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
                break status;
            }
            if start.elapsed() > Duration::from_secs(1) {
                let _ = child.kill();
                // Reap without extending the caller's deadline if the OS is stuck.
                std::thread::spawn(move || child.wait());
                return Err("process table command timed out".into());
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        if !status.success() {
            return Err(format!("process table command failed: {status}"));
        }
        output.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        let mut table = String::new();
        output
            .take(16 * 1024 * 1024 + 1)
            .read_to_string(&mut table)
            .map_err(|e| e.to_string())?;
        if table.len() > 16 * 1024 * 1024 {
            return Err("process table exceeded diagnostic limit".into());
        }
        parse_group_process_table(&table, group, std::process::id())
    };
    inspect()
        .map_err(|e| format!("[termination-unverified] Cannot inspect process group {group}: {e}"))
}
#[cfg(unix)]
fn group_alive(pid: u32) -> Result<bool, String> {
    #[cfg(target_os = "linux")]
    {
        if let Ok(entries) = std::fs::read_dir("/proc") {
            return Ok(entries.flatten().any(|entry| {
                let Ok(stat) = std::fs::read_to_string(entry.path().join("stat")) else {
                    return false;
                };
                let Some((_, fields)) = stat.rsplit_once(") ") else {
                    return false;
                };
                let f: Vec<_> = fields.split_whitespace().collect();
                f.get(2).and_then(|x| x.parse::<u32>().ok()) == Some(pid)
                    && !matches!(f.first(), Some(&"Z") | Some(&"X"))
            }));
        }
    }
    #[cfg(target_os = "macos")]
    return process_table_group_alive(pid);
    #[cfg(not(target_os = "macos"))]
    {
        if unsafe { libc::kill(-(pid as i32), 0) } == 0 {
            return Ok(true);
        }
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            Ok(false)
        } else {
            Err(format!(
                "[termination-unverified] Cannot inspect process group {pid}: {error}"
            ))
        }
    }
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
                #[cfg(windows)]
                if docker.is_none() {
                    return Err(format!(
                        "[termination-unverified] Launcher PID {pid} was reused; cannot verify termination of its original descendants"
                    ));
                }
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
            while group_alive(pid)? {
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

#[cfg(test)]
mod process_portability_tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn process_table_requires_complete_known_states_for_every_group_member() {
        let table = "10 10 S\n20 20 Z\n21 20 Z+\n22 22 R\n";
        assert!(!parse_group_process_table(table, 20, 10).unwrap());
        assert!(!parse_group_process_table(table, 99, 10).unwrap());
        assert!(parse_group_process_table(&format!("{table}23 20 S\n"), 20, 10).unwrap());
        for invalid in [
            "",
            "20 20 Z\n",
            "10 10 S\n20 20 ?\n",
            "10 10 S\n20 broken Z\n",
            "10 10 S\n20 20\n",
        ] {
            assert!(parse_group_process_table(invalid, 20, 10).is_err());
        }
    }

    #[cfg(unix)]
    #[test]
    fn macos_eperm_requires_positive_evidence_and_other_errors_stay_errors() {
        assert!(
            macos_signal_error(20, std::io::Error::from_raw_os_error(libc::EPERM), || Ok(
                false
            ))
            .is_ok()
        );
        assert!(
            macos_signal_error(20, std::io::Error::from_raw_os_error(libc::EPERM), || Ok(
                true
            ))
            .is_err()
        );
        assert!(
            macos_signal_error(20, std::io::Error::from_raw_os_error(libc::EPERM), || Err(
                "[termination-unverified] scan failed".into()
            ))
            .unwrap_err()
            .contains("scan failed")
        );
        assert!(macos_signal_error(
            20,
            std::io::Error::from_raw_os_error(libc::EINVAL),
            || panic!("must not excuse another signal error")
        )
        .is_err());
    }

    #[cfg(unix)]
    #[test]
    fn actual_process_table_distinguishes_live_and_terminated_groups() {
        let mut command = Command::new("sleep");
        command.arg("60");
        let mut child = grouped_command(command).spawn().unwrap();
        let pid = child.id();
        let alive = process_table_group_alive(pid);
        kill_tree(pid, true).unwrap();
        child.wait().unwrap();
        assert!(alive.unwrap());
        assert!(!process_table_group_alive(pid).unwrap());
    }

    #[cfg(windows)]
    #[test]
    fn windows_lock_owner_requires_live_ancestry_and_exact_launcher_identity() {
        let pid = std::process::id();
        let job = Job::new("ownership".into(), "analyze".into());
        job.pid.store(pid, Ordering::SeqCst);
        *job.target.lock().unwrap() = Some(ProcessTarget {
            pid,
            docker: None,
            start_identity: process_identity(pid),
        });
        let mut child = Command::new("cmd")
            .args(["/C", "ping -n 60 127.0.0.1 >nul"])
            .spawn()
            .unwrap();
        let owned = job_owns_process(&job, child.id());
        kill_tree(child.id(), true).unwrap();
        child.wait().unwrap();
        assert!(owned, "Live child must belong to this exact launcher");
        assert!(!job_owns_process(&job, child.id()));
        assert!(!job_owns_process(&job, 0));
        assert!(!job_owns_process(&job, 4));
        job.target.lock().unwrap().as_mut().unwrap().start_identity =
            Some("incorrect birth time".into());
        assert!(!job_owns_process(&job, pid));
        let error = verify_termination(&job).unwrap_err();
        assert!(error.contains("[termination-unverified]") && error.contains("was reused"));
        assert!(
            job.target.lock().unwrap().is_some(),
            "Unverified tree must remain tracked"
        );
    }
}
