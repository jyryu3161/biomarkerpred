use super::{
    artifacts::{atomic_json, read_json},
    engine_process::{run_process, Job},
    engine_types::RuntimeSettings,
    hide_console,
};
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::{atomic::Ordering, Arc},
    time::Duration,
};
use tauri::Manager;

pub fn valid_root(root: &Path) -> bool {
    root.join("BiomarkerCLI.R").is_file()
        && root.join("R/load.R").is_file()
        && root.join("config/schema.json").is_file()
}
pub fn resolve_engine(resource_dir: Option<&Path>) -> Result<PathBuf, String> {
    if let Some(path) = resource_dir {
        let bundled = path.join("engine");
        if valid_root(&bundled) {
            return bundled.canonicalize().map_err(|e| e.to_string());
        }
    }
    #[cfg(debug_assertions)]
    {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
        if valid_root(&root) {
            return root.canonicalize().map_err(|e| e.to_string());
        }
    }
    Err("Bundled BioMarkerPred engine is incomplete. Reinstall the application; BiomarkerCLI.R, R modules and config/schema.json are required.".into())
}
pub fn app_engine(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    resolve_engine(app.path().resource_dir().ok().as_deref())
}
pub fn r_executable(settings: &RuntimeSettings, root: &Path) -> String {
    settings
        .r_path
        .clone()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| std::env::var("BMP_RSCRIPT").ok())
        .or_else(|| {
            let suffix = if cfg!(windows) {
                "Scripts/Rscript.exe"
            } else {
                "bin/Rscript"
            };
            [
                root.join(".pixi/envs/default").join(suffix),
                root.join("tests/runtime/.pixi/envs/default").join(suffix),
            ]
            .into_iter()
            .find(|p| p.is_file())
            .map(|p| p.to_string_lossy().into_owned())
        })
        .or_else(|| find_executable("Rscript"))
        .unwrap_or_else(|| "Rscript".into())
}
pub fn find_executable(name: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        for suffix in if cfg!(windows) {
            vec!["", ".exe", ".cmd"]
        } else {
            vec![""]
        } {
            let candidate = dir.join(format!("{name}{suffix}"));
            if candidate.is_file() {
                return Some(candidate.to_string_lossy().into_owned());
            }
        }
    }
    None
}
pub fn docker_executable(settings: &RuntimeSettings) -> String {
    settings
        .docker_path
        .clone()
        .filter(|path| !path.trim().is_empty())
        .unwrap_or_else(super::find_docker)
}

#[derive(Debug, PartialEq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DockerState {
    CliMissing,
    EngineUnreachable,
    WrongContainerMode,
    ImageMissing,
    ImageCheckFailed,
    Ready,
}
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerDiagnostic {
    phase: String,
    exit_code: Option<i32>,
    stdout: String,
    stderr: Vec<String>,
    timed_out: bool,
    error: Option<String>,
}
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DockerStatus {
    pub state: DockerState,
    pub executable: String,
    pub image: String,
    pub image_id: Option<String>,
    server_os: Option<String>,
    pub message: String,
    diagnostics: Vec<DockerDiagnostic>,
}
impl DockerStatus {
    pub fn error_message(&self) -> String {
        let details = self
            .diagnostics
            .iter()
            .flat_map(|d| d.stderr.iter().chain(d.error.iter()))
            .cloned()
            .collect::<Vec<_>>()
            .join("\n");
        if details.is_empty() {
            self.message.clone()
        } else {
            format!("{}\n{details}", self.message)
        }
    }
}
fn docker_probe(
    executable: &str,
    args: &[&str],
    phase: &str,
    job: Arc<Job>,
) -> Result<DockerDiagnostic, String> {
    let mut command = Command::new(executable);
    command.args(args);
    let result = run_process(
        command,
        job.clone(),
        Some(Duration::from_secs(20)),
        None,
        Arc::new(|_| {}),
    );
    if job.cancel.load(Ordering::SeqCst) {
        return Err("Operation cancelled during Docker inspection".into());
    }
    Ok(match result {
        Ok(out) => DockerDiagnostic {
            phase: phase.into(),
            exit_code: out.code,
            stdout: out.stdout,
            stderr: out.stderr,
            timed_out: out.timed_out,
            error: None,
        },
        Err(error) => DockerDiagnostic {
            phase: phase.into(),
            exit_code: None,
            stdout: String::new(),
            stderr: vec![],
            timed_out: false,
            error: Some(error),
        },
    })
}
fn check_server(status: &mut DockerStatus, job: Arc<Job>, phase: &str) -> Result<bool, String> {
    // Query only the server's container OS, keeping unrelated host/container metadata private.
    let probe = docker_probe(
        &status.executable,
        &["info", "--format", "{{.OSType}}"],
        phase,
        job,
    )?;
    let os = probe.stdout.trim().to_lowercase();
    let connected = probe.exit_code == Some(0) && !probe.timed_out && probe.error.is_none();
    status.diagnostics.push(probe);
    status.server_os = connected.then_some(os.clone());
    if !connected || !matches!(os.as_str(), "linux" | "windows") {
        status.state = DockerState::EngineUnreachable;
        status.message = "Cannot connect to a usable Docker Engine with the selected executable and current Docker context. On Windows/macOS, start Docker Desktop and wait for its Linux engine, then check runtime again. If Docker is already running, check its context and permissions. The analysis image has not been verified.".into();
        return Ok(false);
    }
    if os != "linux" {
        status.state = DockerState::WrongContainerMode;
        status.message = "Docker Engine is running Windows containers. BioMarkerPred requires Linux containers; switch Docker Desktop to Linux containers and check runtime again.".into();
        return Ok(false);
    }
    Ok(true)
}
/// Read-only prerequisites, shared by diagnostics, engine planning and explicit downloads.
/// Never infer a missing image from a failed connection to the Docker server.
pub fn inspect_docker(settings: &RuntimeSettings, job: Arc<Job>) -> Result<DockerStatus, String> {
    let executable = docker_executable(settings);
    let mut status = DockerStatus {
        state: DockerState::CliMissing,
        executable,
        image: settings.docker_image.clone(),
        image_id: None,
        server_os: None,
        message: "Docker CLI was not found. Install Docker Desktop/Engine or select its Docker executable, then check runtime again.".into(),
        diagnostics: vec![],
    };
    if job.cancel.load(Ordering::SeqCst) {
        return Err("Operation cancelled during Docker inspection".into());
    }
    if !Path::new(&status.executable).is_file() && find_executable(&status.executable).is_none() {
        return Ok(status);
    }
    if !check_server(&mut status, job.clone(), "server")? {
        return Ok(status);
    }
    let probe = docker_probe(
        &status.executable,
        &["image", "inspect", "--format", "{{.Id}}", &status.image],
        "image",
        job.clone(),
    )?;
    let id = probe.stdout.trim().to_owned();
    let available = probe.exit_code == Some(0)
        && !probe.timed_out
        && probe.error.is_none()
        && id
            .strip_prefix("sha256:")
            .is_some_and(|hash| hash.len() == 64 && hash.bytes().all(|c| c.is_ascii_hexdigit()));
    let missing = probe.exit_code != Some(0)
        && !probe.timed_out
        && probe
            .stderr
            .iter()
            .any(|line| line.to_lowercase().contains("no such image"));
    status.diagnostics.push(probe);
    if available {
        status.state = DockerState::Ready;
        status.image_id = Some(id);
        status.message = "Docker Engine and the analysis image are available. The actual engine doctor must pass before analysis.".into();
    } else if check_server(&mut status, job, "server_recheck")? {
        if missing {
            status.state = DockerState::ImageMissing;
            status.message = format!("Docker Engine is running Linux containers, but analysis image {} is not downloaded. Choose Download analysis image.", status.image);
        } else {
            status.state = DockerState::ImageCheckFailed;
            status.message = "Docker Engine is running Linux containers, but the analysis image could not be inspected. Check the Docker diagnostics and permissions; this does not establish that the image is missing.".into();
        }
    }
    Ok(status)
}
#[tauri::command]
pub async fn runtime_docker_status(settings: RuntimeSettings) -> Result<DockerStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        inspect_docker(
            &settings,
            Arc::new(Job::new("docker-status".into(), "doctor".into())),
        )
    })
    .await
    .map_err(|e| e.to_string())?
}
/// Explicit user action; only this fixed official page may be opened.
#[tauri::command]
pub async fn runtime_open_docker_download() -> Result<(), String> {
    #[cfg(target_os = "windows")]
    let program = "explorer";
    #[cfg(target_os = "macos")]
    let program = "open";
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    let program = "xdg-open";
    let mut command = Command::new(program);
    command.arg("https://www.docker.com/products/docker-desktop/");
    let mut child = hide_console(command)
        .spawn()
        .map_err(|e| format!("Cannot open the Docker Desktop download page: {e}"))?;
    // A browser may stay open; reap the launcher without blocking desktop IPC.
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}
fn settings_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_config_dir()
        .map_err(|e| e.to_string())?
        .join("runtime-settings.json"))
}
#[tauri::command]
pub async fn engine_get_settings(app: tauri::AppHandle) -> Result<RuntimeSettings, String> {
    let path = settings_path(&app)?;
    if !path.exists() {
        return Ok(RuntimeSettings::default());
    }
    serde_json::from_value(read_json(&path)?)
        .map_err(|e| format!("Invalid saved runtime settings: {e}"))
}
#[tauri::command]
pub async fn engine_save_settings(
    settings: RuntimeSettings,
    app: tauri::AppHandle,
) -> Result<RuntimeSettings, String> {
    if settings.docker_image.trim().is_empty() {
        return Err("Docker image is required".into());
    }
    atomic_json(
        &settings_path(&app)?,
        &serde_json::to_value(&settings).map_err(|e| e.to_string())?,
    )?;
    Ok(settings)
}
#[tauri::command]
pub async fn engine_schema(app: tauri::AppHandle) -> Result<Value, String> {
    read_json(&app_engine(&app)?.join("config/schema.json"))
}
/// A pull is deliberately explicit and uses the same configured executable/image.
/// Image presence still does not mean compatibility: follow with engine_call doctor.
#[tauri::command]
pub async fn runtime_pull_image(settings: RuntimeSettings) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let job = Arc::new(Job::new("image-pull".into(), "pull".into()));
        pull_image(&settings, job)
    })
    .await
    .map_err(|e| e.to_string())?
}
fn pull_image(settings: &RuntimeSettings, job: Arc<Job>) -> Result<String, String> {
    let status = inspect_docker(settings, job.clone())?;
    if !matches!(status.state, DockerState::Ready | DockerState::ImageMissing) {
        return Err(status.error_message());
    }
    let mut command = Command::new(&status.executable);
    command.args(["pull", &settings.docker_image]);
    let out = run_process(
        hide_console(command),
        job,
        Some(Duration::from_secs(1800)),
        None,
        Arc::new(|_| {}),
    )?;
    if out.code != Some(0) || out.timed_out || out.cancelled {
        return Err(format!(
            "Analysis image download failed, was cancelled or exceeded 30 minutes: {}",
            out.stderr.join("\n")
        ));
    }
    Ok(settings.docker_image.clone())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{fs, os::unix::fs::PermissionsExt, time::Instant};

    fn fake(dir: &Path, body: &str) -> RuntimeSettings {
        let exe = dir.join("selected docker");
        let log = dir.join("calls");
        fs::write(&exe, format!("#!/usr/bin/python3\nimport sys,time\nwith open({:?},'a') as f: f.write(' '.join(sys.argv[1:])+'\\n')\n{body}\n", log.to_string_lossy())).unwrap();
        fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
        RuntimeSettings {
            docker_path: Some(exe.to_string_lossy().into_owned()),
            ..Default::default()
        }
    }
    fn job() -> Arc<Job> {
        Arc::new(Job::new("docker-status-test".into(), "doctor".into()))
    }

    #[test]
    fn docker_npipe_and_permission_failures_stop_before_image_inspection_or_pull() {
        for message in [
            "open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified.",
            "permission denied while trying to connect to the Docker daemon socket",
        ] {
            let dir = tempfile::tempdir().unwrap();
            let settings = fake(
                dir.path(),
                &format!("print({message:?},file=sys.stderr)\nsys.exit(1)"),
            );
            let status = inspect_docker(&settings, job()).unwrap();
            assert_eq!(status.state, DockerState::EngineUnreachable);
            assert!(status.error_message().contains(message));
            assert!(!status.message.contains("not downloaded"));
            assert!(pull_image(&settings, job()).unwrap_err().contains(message));
            let calls = fs::read_to_string(dir.path().join("calls")).unwrap();
            assert!(calls.lines().all(|line| line.starts_with("info --format")));
        }
    }
    #[test]
    fn docker_live_server_distinguishes_missing_image_from_inspection_denial() {
        for (message, state) in [
            (
                "Error response from daemon: No such image: example:tag",
                DockerState::ImageMissing,
            ),
            (
                "authorization denied: image inspect",
                DockerState::ImageCheckFailed,
            ),
        ] {
            let dir = tempfile::tempdir().unwrap();
            let settings = fake(dir.path(), &format!("if sys.argv[1]=='info': print('linux')\nelse:\n print({message:?},file=sys.stderr)\n sys.exit(1)"));
            let status = inspect_docker(&settings, job()).unwrap();
            assert_eq!(status.state, state);
            assert_eq!(status.server_os.as_deref(), Some("linux"));
            assert!(status.error_message().contains(message));
            let calls = fs::read_to_string(dir.path().join("calls")).unwrap();
            assert_eq!(calls.lines().count(), 3);
            assert!(!calls.contains("pull"));
        }
    }
    #[test]
    fn docker_engine_disappearing_during_image_check_is_not_missing_image() {
        let dir = tempfile::tempdir().unwrap();
        let count = dir.path().join("server_seen");
        let settings = fake(dir.path(), &format!("from pathlib import Path\np=Path({:?})\nif sys.argv[1]=='info' and not p.exists():\n p.touch()\n print('linux')\nelse:\n print('Cannot connect to Docker daemon',file=sys.stderr)\n sys.exit(1)", count.to_string_lossy()));
        let status = inspect_docker(&settings, job()).unwrap();
        assert_eq!(status.state, DockerState::EngineUnreachable);
        assert_eq!(status.diagnostics.len(), 3);
    }
    #[test]
    fn docker_windows_containers_are_rejected_before_image_inspection() {
        let dir = tempfile::tempdir().unwrap();
        let settings = fake(dir.path(), "print('windows')");
        let status = inspect_docker(&settings, job()).unwrap();
        assert_eq!(status.state, DockerState::WrongContainerMode);
        assert!(status.message.contains("Linux containers"));
        assert_eq!(
            fs::read_to_string(dir.path().join("calls"))
                .unwrap()
                .lines()
                .count(),
            1
        );
    }
    #[test]
    fn docker_missing_cli_and_blank_path_fallback() {
        let dir = tempfile::tempdir().unwrap();
        let settings = RuntimeSettings {
            docker_path: Some(dir.path().join("absent").to_string_lossy().into_owned()),
            ..Default::default()
        };
        assert_eq!(
            inspect_docker(&settings, job()).unwrap().state,
            DockerState::CliMissing
        );
        let settings = RuntimeSettings {
            docker_path: Some("  ".into()),
            ..Default::default()
        };
        assert_eq!(docker_executable(&settings), super::super::find_docker());
    }
    #[test]
    fn docker_explicit_pull_uses_selected_executable_and_exact_image() {
        let dir = tempfile::tempdir().unwrap();
        let settings = fake(dir.path(), "if sys.argv[1]=='info': print('linux')\nelif sys.argv[1]=='image':\n print('No such image',file=sys.stderr)\n sys.exit(1)\nelif sys.argv[1]=='pull': print('Downloaded')\nelse: sys.exit(2)");
        assert_eq!(pull_image(&settings, job()).unwrap(), settings.docker_image);
        let calls = fs::read_to_string(dir.path().join("calls")).unwrap();
        assert_eq!(
            calls.lines().last(),
            Some(format!("pull {}", settings.docker_image).as_str())
        );
    }
    #[test]
    fn docker_server_probe_cancellation_is_bounded_and_never_inspects_image() {
        let dir = tempfile::tempdir().unwrap();
        let settings = fake(dir.path(), "time.sleep(60)");
        let pending = job();
        let thread_job = pending.clone();
        let thread = std::thread::spawn(move || inspect_docker(&settings, thread_job));
        let start = Instant::now();
        while pending.pid.load(Ordering::SeqCst) == 0 {
            assert!(start.elapsed() < Duration::from_secs(5));
            std::thread::sleep(Duration::from_millis(10));
        }
        pending.cancel.store(true, Ordering::SeqCst);
        assert!(thread.join().unwrap().unwrap_err().contains("cancelled"));
        assert!(start.elapsed() < Duration::from_secs(10));
        if let Ok(calls) = fs::read_to_string(dir.path().join("calls")) {
            assert!(!calls.contains("image"));
        }
    }
}
