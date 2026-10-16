use super::{
    artifacts::{atomic_json, read_json, verify_run},
    engine_plan::{prepare, PathMap},
    engine_process::{emit, run_process, EventSink, Job, JobRegistry},
    engine_types::*,
    runtime,
};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::{atomic::Ordering, Arc},
    time::Duration,
};
use tauri::Emitter;

#[derive(Default)]
pub struct EngineState {
    pub jobs: Arc<JobRegistry>,
}
fn doctor_compatible(v: &Value) -> Result<(), String> {
    if v["ok"] != true
        || v["application"] != "BioMarkerPred"
        || v["interface_version"] != 1
        || v["config_version"] != 1
        || v["model_version"] != 1
    {
        return Err(format!("Incompatible engine runtime. Choose a compatible R installation or rebuild the configured engine image. Diagnostic: {v}"));
    }
    for capability in ["cairo", "png", "tiff"] {
        if v["graphics"][capability] != true {
            return Err(format!(
                "R graphics capability '{capability}' is required for report exports"
            ));
        }
    }
    for package in ["yaml", "jsonlite", "digest", "survival", "glmnet", "pROC"] {
        if v["packages"][package].as_str().is_none_or(str::is_empty) {
            return Err(format!("Missing core R package: {package}"));
        }
    }
    Ok(())
}
fn capture_lock(job: &Job, run: &Path, docker_name: Option<&str>) {
    let path = run.join(".mutation.lock");
    if let Ok(owner) = read_json(&path.join("owner.json")) {
        let ours = if let Some(name) = docker_name {
            owner["context"]["host"] == name
        } else {
            owner["pid"].as_u64() == Some(job.pid.load(Ordering::SeqCst) as u64)
                && owner["context"] == local_lock_context()
        };
        if ours {
            let mut locks = job.locks.lock().unwrap();
            if !locks
                .iter()
                .any(|(p, o)| p == &path && o["token"] == owner["token"])
            {
                locks.push((path, owner));
            }
        }
    }
}
fn local_lock_context() -> Value {
    #[cfg(unix)]
    let host = {
        let mut bytes = [0u8; 256];
        if unsafe { libc::gethostname(bytes.as_mut_ptr().cast(), bytes.len() - 1) } == 0 {
            String::from_utf8_lossy(&bytes[..bytes.iter().position(|c| *c == 0).unwrap_or(255)])
                .into_owned()
        } else {
            "unknown".into()
        }
    };
    #[cfg(windows)]
    let host = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "unknown".into());
    let boot = std::fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .map(|v| v.trim().to_owned())
        .unwrap_or_else(|_| "unknown".into());
    let namespace = std::fs::read_link("/proc/self/ns/pid")
        .map(|v| v.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "unknown".into());
    json!({"host":host,"boot":boot,"pid_namespace":namespace})
}
fn cancel_cleanup(job: &Job) -> Result<(), String> {
    // Only invoked after the production process primitive confirmed termination.
    // A pathway event carries its derivative run_dir; the source is lock-only.
    for run in job.run_dirs.lock().unwrap().iter() {
        let path = run.join("manifest.json");
        if let Ok(mut manifest) = read_json(&path) {
            if manifest["status"] == "completed" {
                continue;
            }
            if job.operation == "ora" && manifest["operation"] != "ora" {
                continue;
            }
            manifest["status"] = json!("cancelled");
            manifest["stage"] = json!("cancelled");
            let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
            manifest["updated_at"] = json!(now);
            manifest["finished_at"] = json!(now);
            manifest["desktop_cancellation"] = json!({"job_id":job.id,"terminated":true,"unix_seconds":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()});
            atomic_json(&path, &manifest)?;
            if let Some(output_root) = run.parent().and_then(Path::parent) {
                let pointer = output_root.join("latest.json");
                if let Ok(mut latest) = read_json(&pointer) {
                    if latest["run_id"] == manifest["run_id"] {
                        latest["status"] = json!("cancelled");
                        latest["updated_at"] = json!(now);
                        atomic_json(&pointer, &latest)?;
                    }
                }
            }
        }
    }
    for (path, owner) in job.locks.lock().unwrap().iter() {
        if let Ok(current) = read_json(&path.join("owner.json")) {
            if current["token"] == owner["token"]
                && current["pid"] == owner["pid"]
                && current["context"] == owner["context"]
            {
                let archive = path.parent().unwrap().join(format!(
                    ".cancelled-lock-{}",
                    owner["token"].as_str().unwrap_or(&job.id)
                ));
                std::fs::rename(path, archive)
                    .map_err(|e| format!("Process stopped, but cannot archive its lock: {e}"))?;
            }
        }
    }
    Ok(())
}
fn save_runtime_context(
    run: &Path,
    map: &PathMap,
    image_id: &Option<String>,
    temp: &Path,
) -> Result<(), String> {
    let mut map = map.clone();
    let temp = temp.canonicalize().unwrap_or_else(|_| temp.to_path_buf());
    map.mounts.retain(|m| {
        !Path::new(&m.host)
            .canonicalize()
            .unwrap_or_else(|_| PathBuf::from(&m.host))
            .starts_with(&temp)
    });
    atomic_json(
        &run.join(".desktop-runtime.json"),
        &json!({"version":1,"path_map":map,"image_id":image_id}),
    )
}
fn run_once(
    request: &EngineRequest,
    settings: &RuntimeSettings,
    root: &Path,
    job: Arc<Job>,
    sink: EventSink,
) -> Result<EngineResponse, String> {
    let mut plan = prepare(request, settings, root, job.clone())?;
    if let Some(create) = plan.create_command.take() {
        let created = run_process(
            create,
            job.clone(),
            Some(Duration::from_secs(30)),
            None,
            Arc::new(|_| {}),
        )?;
        if created.cancelled || created.timed_out || created.code != Some(0) {
            // A cancelled create can leave only a stopped container: start is
            // never called without a confirmed successful create response.
            if let Some(d) = &plan.docker {
                let _ = super::engine_process::stop_container(d);
            }
            if created.cancelled {
                return Ok(failure(
                    "Cancelled before Docker container start".into(),
                    true,
                ));
            }
            return Err(format!(
                "Docker container creation failed: {}",
                created.stderr.join("\n")
            ));
        }
        if job.cancel.load(Ordering::SeqCst) {
            if let Some(d) = &plan.docker {
                super::engine_process::stop_container(d)?;
            }
            return Ok(failure(
                "Cancelled before Docker container start".into(),
                true,
            ));
        }
    }
    let map = plan.map.clone();
    let job_lines = job.clone();
    let event_sink = sink.clone();
    let source = request
        .options
        .get("run")
        .and_then(Value::as_str)
        .map(PathBuf::from);
    let source_lines = source.clone();
    let docker_name = plan.docker.as_ref().map(|d| d.name.clone());
    let docker_lines = docker_name.clone();
    let context_map = map.clone();
    let image_id = plan.image_id.clone();
    let temp = plan._temp.path().to_path_buf();
    let handler = Arc::new(move |line: &str| {
        if let Some(event) = line
            .strip_prefix("BMP_EVENT:")
            .and_then(|s| serde_json::from_str::<Value>(s).ok())
        {
            let mut event = event;
            context_map.map_result(&mut event);
            if let Some(run) = event["run_dir"].as_str() {
                let run = PathBuf::from(run);
                let mut dirs = job_lines.run_dirs.lock().unwrap();
                if !dirs.contains(&run) {
                    dirs.push(run.clone());
                }
                drop(dirs);
                capture_lock(&job_lines, &run, docker_lines.as_deref());
                if let Some(source) = &source_lines {
                    capture_lock(&job_lines, source, docker_lines.as_deref());
                }
                if job_lines.operation != "doctor" {
                    if let Err(e) = save_runtime_context(&run, &context_map, &image_id, &temp) {
                        emit(&job_lines, &event_sink, "warning", json!({"message":e}));
                    }
                }
            }
            emit(&job_lines, &event_sink, "progress", event);
        } else {
            emit(&job_lines, &event_sink, "log", json!({"message":line}));
        }
    });
    let timeout = if request.operation == Operation::Doctor {
        Some(Duration::from_secs(30))
    } else if !request.operation.mutates() {
        Some(Duration::from_secs(120))
    } else {
        None
    };
    let out = run_process(plan.command, job.clone(), timeout, plan.docker, handler)?;
    if let Some(source) = &source {
        capture_lock(&job, source, docker_name.as_deref());
    }
    if out.cancelled {
        cancel_cleanup(&job)?;
        return Ok(EngineResponse {
            success: false,
            cancelled: true,
            exit_code: out.code,
            result: json!({"ok":false,"status":"cancelled","error":"Operation cancelled; the process tree has stopped."}),
            verification_error: None,
            stderr_tail: out.stderr,
        });
    }
    if out.timed_out {
        return Err(format!(
            "{} exceeded its runtime check limit",
            request.operation.name()
        ));
    }
    let mut result: Value = serde_json::from_str(&out.stdout).map_err(|e| {
        format!(
            "CLI protocol error: expected exactly one JSON result object ({e}). {}",
            out.stderr.join("\n")
        )
    })?;
    if !result.is_object() || !result["ok"].is_boolean() {
        return Err("CLI protocol error: result must be an object with boolean ok".into());
    }
    map.map_result(&mut result);
    let mut verification_error = None;
    if result["ok"] == true {
        let verification = (|| -> Result<(), String> {
            match request.operation {
                Operation::Doctor => doctor_compatible(&result),
                Operation::Analyze
                | Operation::Evaluate
                | Operation::Resume
                | Operation::Ora
                | Operation::Report => {
                    let run = result["run_dir"]
                        .as_str()
                        .ok_or("CLI success did not identify its actual run_dir")?;
                    let manifest =
                        verify_run(Path::new(run), request.operation != Operation::Report)?;
                    if manifest["run_id"] != result["run_id"]
                        || manifest["status"] != result["status"]
                    {
                        return Err("CLI result and saved manifest identity/status disagree".into());
                    }
                    save_runtime_context(Path::new(run), &map, &plan.image_id, plan._temp.path())?;
                    Ok(())
                }
                Operation::Predict => {
                    let output = result["paths"]["predictions"]
                        .as_str()
                        .ok_or("Missing prediction output")?;
                    if !Path::new(output).is_file()
                        || std::fs::metadata(output).map_err(|e| e.to_string())?.len() == 0
                    {
                        return Err("Prediction result file is missing or empty".into());
                    }
                    if result["model_unchanged"] != true {
                        return Err("Frozen model hash changed during prediction".into());
                    }
                    Ok(())
                }
                _ => Ok(()),
            }
        })();
        if let Err(error) = verification {
            verification_error = Some(error);
        }
    }
    let success = out.code == Some(0) && result["ok"] == true && verification_error.is_none();
    Ok(EngineResponse {
        success,
        cancelled: false,
        exit_code: out.code,
        result,
        verification_error,
        stderr_tail: out.stderr,
    })
}
pub fn execute(
    request: &EngineRequest,
    settings: &RuntimeSettings,
    root: &Path,
    job: Arc<Job>,
    sink: EventSink,
) -> Result<EngineResponse, String> {
    request.validate()?;
    if request.operation != Operation::Doctor {
        let doctor = EngineRequest {
            operation: Operation::Doctor,
            options: Default::default(),
            config: None,
            settings: None,
        };
        let checked = run_once(&doctor, settings, root, job.clone(), sink.clone())?;
        if checked.cancelled {
            return Ok(checked);
        }
        if !checked.success {
            return Err(checked
                .verification_error
                .unwrap_or_else(|| format!("Runtime is unavailable: {}", checked.result)));
        }
    }
    job.snapshot.lock().unwrap().phase = "running".into();
    emit(&job, &sink, "started", json!({"backend":settings.backend}));
    run_once(request, settings, root, job, sink)
}
fn failure(message: String, cancelled: bool) -> EngineResponse {
    EngineResponse {
        success: false,
        cancelled,
        exit_code: None,
        result: json!({"ok":false,"status":if cancelled{"cancelled"}else{"failed"},"error":message}),
        verification_error: None,
        stderr_tail: vec![],
    }
}
async fn settings_for(
    request: &EngineRequest,
    app: &tauri::AppHandle,
) -> Result<RuntimeSettings, String> {
    match &request.settings {
        Some(s) => Ok(s.clone()),
        None => runtime::engine_get_settings(app.clone()).await,
    }
}
#[tauri::command]
pub async fn engine_call(
    request: EngineRequest,
    app: tauri::AppHandle,
) -> Result<EngineResponse, String> {
    request.validate()?;
    if request.operation.mutates() {
        return Err("Mutating operations require engine_start and a unique jobId".into());
    }
    let root = runtime::app_engine(&app)?;
    let settings = settings_for(&request, &app).await?;
    tauri::async_runtime::spawn_blocking(move || {
        let job = Arc::new(Job::new(
            format!(
                "read-{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            ),
            request.operation.name().into(),
        ));
        execute(&request, &settings, &root, job, Arc::new(|_| {}))
    })
    .await
    .map_err(|e| e.to_string())?
}
#[tauri::command]
pub async fn engine_start(
    request: EngineRequest,
    job_id: String,
    app: tauri::AppHandle,
    state: tauri::State<'_, EngineState>,
) -> Result<Value, String> {
    request.validate()?;
    if !request.operation.mutates() {
        return Err("Use engine_call for this read-only operation".into());
    }
    let root = runtime::app_engine(&app)?;
    let settings = settings_for(&request, &app).await?;
    // Reserve before any process/doctor can start. The caller already knows the
    // ID and listens before invoking, so a quick completion cannot be lost.
    let job = state.jobs.reserve(&job_id, request.operation.name())?;
    let jobs = state.jobs.clone();
    let accepted = job.snapshot.lock().unwrap().clone();
    let handle = app.clone();
    std::thread::spawn(move || {
        let sink: EventSink = Arc::new(move |event| {
            let _ = handle.emit("engine://event", event);
        });
        emit(&job, &sink, "accepted", json!({"phase":"starting"}));
        let response = execute(&request, &settings, &root, job.clone(), sink.clone())
            .unwrap_or_else(|e| {
                let cancelled =
                    job.cancel.load(Ordering::SeqCst) && !e.contains("[termination-unverified]");
                failure(e, cancelled)
            });
        if response.result["error"]
            .as_str()
            .is_some_and(|e| e.contains("[termination-unverified]"))
        {
            let mut snapshot = job.snapshot.lock().unwrap();
            snapshot.phase = "cancellation_unverified".into();
            snapshot.response = Some(response.clone());
            drop(snapshot);
            emit(
                &job,
                &sink,
                "cancellation_unverified",
                serde_json::to_value(response).unwrap(),
            );
        } else {
            let response = jobs.finish(&job, response);
            emit(
                &job,
                &sink,
                "complete",
                serde_json::to_value(response).unwrap(),
            );
        }
    });
    Ok(json!(accepted))
}
#[tauri::command]
pub async fn engine_cancel(
    job_id: String,
    app: tauri::AppHandle,
    state: tauri::State<'_, EngineState>,
) -> Result<Value, String> {
    let (job, retry) = state.jobs.cancel(&job_id)?;
    if retry {
        job.snapshot.lock().unwrap().phase = "cancelling".into();
        let jobs = state.jobs.clone();
        let retry_job = job.clone();
        std::thread::spawn(move || {
            let sink: EventSink = Arc::new(move |event| {
                let _ = app.emit("engine://event", event);
            });
            let result = super::engine_process::verify_termination(&retry_job)
                .and_then(|_| cancel_cleanup(&retry_job));
            match result {
                Ok(()) => {
                    let response = jobs.finish(
                        &retry_job,
                        failure("Cancellation verified; process tree stopped".into(), true),
                    );
                    emit(&retry_job, &sink, "complete", json!(response));
                }
                Err(error) => {
                    let response = failure(error, false);
                    let mut snapshot = retry_job.snapshot.lock().unwrap();
                    snapshot.phase = "cancellation_unverified".into();
                    snapshot.response = Some(response.clone());
                    drop(snapshot);
                    emit(
                        &retry_job,
                        &sink,
                        "cancellation_unverified",
                        json!(response),
                    );
                }
            }
        });
    }
    let snapshot = job.snapshot.lock().unwrap().clone();
    Ok(json!(snapshot))
}
#[tauri::command]
pub async fn engine_job_status(
    job_id: Option<String>,
    state: tauri::State<'_, EngineState>,
) -> Result<Value, String> {
    if let Some(id) = job_id {
        Ok(json!(state.jobs.get(&id)?.snapshot.lock().unwrap().clone()))
    } else {
        Ok(json!(state.jobs.active()))
    }
}
