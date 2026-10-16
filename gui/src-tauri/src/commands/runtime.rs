use super::{
    artifacts::{atomic_json, read_json},
    engine_types::RuntimeSettings,
    hide_console,
};
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    process::Command,
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
    let executable = settings.docker_path.unwrap_or_else(super::find_docker);
    let image = settings.docker_image;
    tauri::async_runtime::spawn_blocking(move || {
        let mut command = Command::new(executable);
        command.args(["pull", &image]);
        let job = std::sync::Arc::new(super::engine_process::Job::new(
            "image-pull".into(),
            "pull".into(),
        ));
        let out = super::engine_process::run_process(
            hide_console(command),
            job,
            Some(std::time::Duration::from_secs(300)),
            None,
            std::sync::Arc::new(|_| {}),
        )?;
        if out.code != Some(0) || out.timed_out {
            return Err(format!(
                "Image pull failed or timed out: {}",
                out.stderr.join("\n")
            ));
        }
        Ok(image)
    })
    .await
    .map_err(|e| e.to_string())?
}
