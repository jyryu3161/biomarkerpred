use super::{find_docker, hide_console};
use crate::commands::analysis::find_project_root;
use crate::commands::runtime::find_executable;
use crate::models::config::{EnvStatus, ImageUpdateStatus};
use crate::models::error::AppError;
use std::io::{BufRead, BufReader};
use std::sync::Mutex;
use tauri::{Emitter, State};

pub struct SetupProcess {
    pub child: Mutex<Option<u32>>,
}

/// Check environment status: pixi, R, packages, Docker
#[tauri::command]
pub async fn setup_check_env() -> Result<EnvStatus, String> {
    // 1. Check pixi
    let pixi_path = find_executable("pixi").or_else(|| {
        // Check common pixi install locations
        let home = dirs_next().unwrap_or_default();
        let candidates = [
            format!("{}/.pixi/bin/pixi", home),
            "/usr/local/bin/pixi".to_string(),
        ];
        for c in &candidates {
            if std::path::Path::new(c).exists() {
                return Some(c.clone());
            }
        }
        None
    });
    let pixi_installed = pixi_path.is_some();

    // 2. Check R via pixi env
    let project_root = find_project_root();
    let (r_available, r_path, r_version) = check_r(&project_root, &pixi_path);

    // 3. Check packages (quick check of a few key ones)
    let packages_ok = if r_available {
        check_packages(&r_path, &project_root)
    } else {
        false
    };

    // 4. Check Docker
    let docker_available = check_docker_daemon();

    // 5. Check Docker image
    let docker_image_present = if docker_available {
        check_docker_image("jyryu3161/biomarkerpred")
    } else {
        false
    };

    Ok(EnvStatus {
        pixi_installed,
        r_available,
        packages_ok,
        docker_available,
        docker_image_present,
        pixi_path,
        r_path,
        r_version,
    })
}

/// Install environment: pixi + R + packages with progress events
#[tauri::command]
pub async fn setup_install_env(
    app: tauri::AppHandle,
    state: State<'_, SetupProcess>,
) -> Result<(), String> {
    let project_root = find_project_root().ok_or_else(|| {
        String::from(AppError::setup_failed(
            "Cannot find project root (Main_Binary.R not found).",
        ))
    })?;

    // Step 1/3: Install pixi if not present
    let _ = app.emit("setup://progress", serde_json::json!({ "step": 1, "total": 3, "message": "Installing pixi..." }));
    let _ = app.emit("setup://log", "Step 1/3: Checking pixi installation...");

    if find_executable("pixi").is_none() {
        let _ = app.emit("setup://log", "pixi not found. Installing...");

        let (program, args): (&str, Vec<&str>) = if cfg!(windows) {
            ("powershell", vec!["-ExecutionPolicy", "ByPass", "-Command",
                "iwr -useb https://pixi.sh/install.ps1 | iex"])
        } else {
            ("bash", vec!["-c", "curl -fsSL https://pixi.sh/install.sh | bash"])
        };

        let mut child = hide_console(std::process::Command::new(program))
            .args(&args)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| String::from(AppError::setup_failed(&format!("Failed to start pixi installer: {}", e))))?;

        {
            let mut guard = state.child.lock().map_err(|e| e.to_string())?;
            *guard = Some(child.id());
        }

        stream_output(&app, &mut child, "setup://log");
        let status = child.wait().map_err(|e| e.to_string())?;

        { let mut guard = state.child.lock().map_err(|e| e.to_string())?; *guard = None; }

        if !status.success() {
            return Err(String::from(AppError::setup_failed("pixi installation failed")));
        }

        let _ = app.emit("setup://log", "pixi installed successfully.");
    } else {
        let _ = app.emit("setup://log", "pixi already installed. Skipping.");
    }

    // Resolve pixi path (may have just been installed)
    let pixi_cmd = find_executable("pixi").unwrap_or_else(|| {
        let home = dirs_next().unwrap_or_default();
        format!("{}/.pixi/bin/pixi", home)
    });

    // Step 2/3: pixi install (installs R and conda dependencies)
    let _ = app.emit("setup://progress", serde_json::json!({ "step": 2, "total": 3, "message": "Installing R environment (this may take several minutes)..." }));
    let _ = app.emit("setup://log", "Step 2/3: Running pixi install...");

    {
        let mut child = hide_console(std::process::Command::new(&pixi_cmd))
            .args(["install"])
            .current_dir(&project_root)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| String::from(AppError::setup_failed(&format!("Failed to run pixi install: {}", e))))?;

        {
            let mut guard = state.child.lock().map_err(|e| e.to_string())?;
            *guard = Some(child.id());
        }

        stream_output(&app, &mut child, "setup://log");
        let status = child.wait().map_err(|e| e.to_string())?;

        { let mut guard = state.child.lock().map_err(|e| e.to_string())?; *guard = None; }

        if !status.success() {
            return Err(String::from(AppError::setup_failed("pixi install failed")));
        }
    }

    let _ = app.emit("setup://log", "R environment installed successfully.");

    // Step 3/3: Install R packages
    let _ = app.emit("setup://progress", serde_json::json!({ "step": 3, "total": 3, "message": "Installing R packages..." }));
    let _ = app.emit("setup://log", "Step 3/3: Running pixi run install-r-packages...");

    {
        let mut child = hide_console(std::process::Command::new(&pixi_cmd))
            .args(["run", "install-r-packages"])
            .current_dir(&project_root)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| String::from(AppError::setup_failed(&format!("Failed to run install-r-packages: {}", e))))?;

        {
            let mut guard = state.child.lock().map_err(|e| e.to_string())?;
            *guard = Some(child.id());
        }

        stream_output(&app, &mut child, "setup://log");
        let status = child.wait().map_err(|e| e.to_string())?;

        { let mut guard = state.child.lock().map_err(|e| e.to_string())?; *guard = None; }

        if !status.success() {
            return Err(String::from(AppError::setup_failed("R package installation failed")));
        }
    }

    let _ = app.emit("setup://log", "All R packages installed successfully.");
    let _ = app.emit("setup://complete", serde_json::json!({ "success": true }));

    Ok(())
}

/// Cancel ongoing setup process
#[tauri::command]
pub async fn setup_cancel(state: State<'_, SetupProcess>) -> Result<(), String> {
    let mut guard = state.child.lock().map_err(|e| e.to_string())?;
    if let Some(pid) = *guard {
        #[cfg(unix)]
        {
            unsafe {
                libc::kill(pid as i32, libc::SIGTERM);
            }
        }
        #[cfg(windows)]
        {
            let _ = hide_console(std::process::Command::new("taskkill"))
                .args(["/PID", &pid.to_string(), "/F"])
                .output();
        }
        *guard = None;
    }
    Ok(())
}

/// Pull Docker image with progress events
#[tauri::command]
pub async fn setup_pull_docker(
    app: tauri::AppHandle,
    state: State<'_, SetupProcess>,
) -> Result<(), String> {
    let _ = app.emit("setup://log", "Pulling Docker image jyryu3161/biomarkerpred...");
    let _ = app.emit("setup://progress", serde_json::json!({ "step": 1, "total": 1, "message": "Pulling Docker image..." }));

    let mut child = hide_console(std::process::Command::new(&find_docker()))
        .args(["pull", "jyryu3161/biomarkerpred"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| String::from(AppError::docker_not_found(&format!("Failed to start docker pull: {}", e))))?;

    {
        let mut guard = state.child.lock().map_err(|e| e.to_string())?;
        *guard = Some(child.id());
    }

    stream_output(&app, &mut child, "setup://log");
    let status = child.wait().map_err(|e| e.to_string())?;

    { let mut guard = state.child.lock().map_err(|e| e.to_string())?; *guard = None; }

    if !status.success() {
        return Err(String::from(AppError::docker_not_found("docker pull failed")));
    }

    let _ = app.emit("setup://log", "Docker image pulled successfully.");
    let _ = app.emit("setup://complete", serde_json::json!({ "success": true }));

    Ok(())
}

/// Check whether a newer Docker image is available on Docker Hub.
/// Compares the local image's repo-digest with digests reported by the Hub API.
/// Returns has_update=false (silently) on network errors so startup is never blocked.
#[tauri::command]
pub async fn setup_check_image_update() -> Result<ImageUpdateStatus, String> {
    // 1. Get the local image's repo digest (set when the image was pulled)
    let local_out = hide_console(std::process::Command::new(&find_docker()))
        .args([
            "image",
            "inspect",
            "jyryu3161/biomarkerpred:latest",
            "--format",
            "{{index .RepoDigests 0}}",
        ])
        .output()
        .map_err(|e| format!("Docker error: {}", e))?;

    if !local_out.status.success() {
        return Ok(ImageUpdateStatus { has_update: false, error: None });
    }

    let local_str = String::from_utf8_lossy(&local_out.stdout).trim().to_string();
    let local_sha = extract_sha256(&local_str);

    if local_sha.is_empty() {
        // Locally built image (no repo digest) — cannot compare
        return Ok(ImageUpdateStatus { has_update: false, error: None });
    }

    // 2. Fetch tag metadata from Docker Hub (no auth required for public images)
    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .user_agent("biomarkerpred-desktop")
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            return Ok(ImageUpdateStatus {
                has_update: false,
                error: Some(format!("HTTP client: {}", e)),
            });
        }
    };

    let resp = match client
        .get("https://hub.docker.com/v2/repositories/jyryu3161/biomarkerpred/tags/latest")
        .send()
        .await
    {
        Ok(r) => r,
        Err(_) => {
            // Network unavailable — skip check silently
            return Ok(ImageUpdateStatus { has_update: false, error: None });
        }
    };

    let json: serde_json::Value = match resp.json().await {
        Ok(v) => v,
        Err(e) => {
            return Ok(ImageUpdateStatus {
                has_update: false,
                error: Some(format!("Parse error: {}", e)),
            });
        }
    };

    // Collect all digests: manifest-list digest + per-platform digests
    let mut remote_shas: Vec<String> = Vec::new();
    if let Some(d) = json["digest"].as_str() {
        let s = extract_sha256(d);
        if !s.is_empty() {
            remote_shas.push(s);
        }
    }
    if let Some(images) = json["images"].as_array() {
        for img in images {
            if let Some(d) = img["digest"].as_str() {
                let s = extract_sha256(d);
                if !s.is_empty() {
                    remote_shas.push(s);
                }
            }
        }
    }

    let has_update = !remote_shas.is_empty() && !remote_shas.contains(&local_sha);

    Ok(ImageUpdateStatus { has_update, error: None })
}

fn extract_sha256(s: &str) -> String {
    if let Some(pos) = s.find("sha256:") {
        s[pos..].trim().to_string()
    } else {
        s.trim().to_string()
    }
}

// ── Helper functions ──

fn dirs_next() -> Option<String> {
    std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .ok()
}

fn check_r(
    project_root: &Option<std::path::PathBuf>,
    pixi_path: &Option<String>,
) -> (bool, Option<String>, Option<String>) {
    // First check pixi-managed R
    if let Some(root) = project_root {
        let pixi_r = if cfg!(windows) {
            root.join(".pixi/envs/default/Scripts/Rscript.exe")
        } else {
            root.join(".pixi/envs/default/bin/Rscript")
        };
        if pixi_r.exists() {
            let version = get_r_version(pixi_r.to_string_lossy().as_ref());
            return (true, Some(pixi_r.to_string_lossy().to_string()), version);
        }
    }

    // Try pixi run Rscript
    if let Some(ref pixi) = pixi_path {
        if let Some(root) = project_root {
            let output = hide_console(std::process::Command::new(pixi))
                .args(["run", "Rscript", "--version"])
                .current_dir(root)
                .output();
            if let Ok(out) = output {
                if out.status.success() {
                    let combined = format!(
                        "{}{}",
                        String::from_utf8_lossy(&out.stdout),
                        String::from_utf8_lossy(&out.stderr)
                    );
                    let version = combined.lines().find(|l| l.contains("version")).map(|l| l.trim().to_string());
                    return (true, Some(format!("{} run Rscript", pixi)), version);
                }
            }
        }
    }

    // Fall back to system Rscript
    if let Some(sys_r) = find_executable("Rscript") {
        let version = get_r_version(&sys_r);
        return (true, Some(sys_r), version);
    }

    (false, None, None)
}

fn get_r_version(rscript_path: &str) -> Option<String> {
    hide_console(std::process::Command::new(rscript_path))
        .args(["--version"])
        .output()
        .ok()
        .and_then(|out| {
            let combined = format!(
                "{}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            combined.lines().find(|l| l.contains("version")).map(|l| l.trim().to_string())
        })
}

fn check_packages(r_path: &Option<String>, project_root: &Option<std::path::PathBuf>) -> bool {
    let rscript = match r_path {
        Some(p) => p.clone(),
        None => return false,
    };

    // Quick check: test a few essential packages
    let check_code = "cat(all(sapply(c('survival','glmnet','yaml','ggplot2'), function(p) requireNamespace(p, quietly=TRUE))))";

    let mut cmd = hide_console(std::process::Command::new(&rscript));
    cmd.args(["-e", check_code]);

    if let Some(root) = project_root {
        cmd.current_dir(root);
        let r_lib_path = root.join(".pixi/envs/default/lib/R/library");
        if r_lib_path.exists() {
            cmd.env("R_LIBS", r_lib_path.to_string_lossy().as_ref());
        }
    }

    cmd.output()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .trim()
                .eq_ignore_ascii_case("true")
        })
        .unwrap_or(false)
}

fn check_docker_daemon() -> bool {
    // On Windows, verify docker.exe is a real installation.
    // Windows App Execution Aliases (in WindowsApps) are stubs that
    // show an OS error dialog when Docker Desktop is not installed.
    #[cfg(windows)]
    {
        match find_executable("docker") {
            Some(path) if path.contains("WindowsApps") => return false,
            None => return false,
            _ => {}
        }
    }

    hide_console(std::process::Command::new(&find_docker()))
        .args(["info"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn check_docker_image(image: &str) -> bool {
    hide_console(std::process::Command::new(&find_docker()))
        .args(["image", "inspect", image])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Stream stdout and stderr from a child process to Tauri events
fn stream_output(app: &tauri::AppHandle, child: &mut std::process::Child, event_name: &str) {
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    let app_clone = app.clone();
    let event = event_name.to_string();

    if let Some(stderr) = stderr {
        let app_err = app_clone.clone();
        let event_err = event.clone();
        std::thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().map_while(Result::ok) {
                let _ = app_err.emit(&event_err, &line);
            }
        });
    }

    if let Some(stdout) = stdout {
        let reader = BufReader::new(stdout);
        for line in reader.lines().map_while(Result::ok) {
            let _ = app_clone.emit(&event, &line);
        }
    }
}
