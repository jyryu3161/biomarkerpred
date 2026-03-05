use super::{find_docker, hide_console};
use crate::models::error::AppError;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::{Emitter, Manager, State};

pub struct OraProcess {
    pub child: Mutex<Option<u32>>,
}

/// Parse ORA progress output lines.
/// Supports:
///   - `ORA_LOG:Step X of Y - message`
///   - `ORA_LOG:Total steps: N`
///   - `ORA_LOG:DONE`
fn parse_ora_progress(line: &str) -> Option<serde_json::Value> {
    // ORA_LOG:Step X of Y - message
    if let Some(rest) = line.strip_prefix("ORA_LOG:Step ") {
        let parts: Vec<&str> = rest.splitn(4, ' ').collect();
        if parts.len() >= 3 && parts[1] == "of" {
            if let (Ok(current), Ok(total)) =
                (parts[0].parse::<u32>(), parts[2].parse::<u32>())
            {
                let message = if parts.len() > 3 {
                    parts[3].trim_start_matches("- ").to_string()
                } else {
                    String::new()
                };
                return Some(serde_json::json!({
                    "type": "step",
                    "current": current,
                    "total": total,
                    "message": message,
                }));
            }
        }
    }

    // ORA_LOG:Total steps: N
    if let Some(rest) = line.strip_prefix("ORA_LOG:Total steps:") {
        if let Ok(total) = rest.trim().parse::<u32>() {
            return Some(serde_json::json!({
                "type": "total",
                "current": 0,
                "total": total,
                "message": format!("Starting {} steps", total),
            }));
        }
    }

    // ORA_LOG:DONE
    if line.starts_with("ORA_LOG:DONE") {
        return Some(serde_json::json!({
            "type": "done",
            "current": 0,
            "total": 0,
            "message": "Pathway analysis complete",
        }));
    }

    None
}

#[tauri::command]
pub async fn ora_run(
    genes: Vec<String>,
    output_dir: String,
    ppi_confidence: f64,
    organism: u32,
    backend: Option<String>,
    ppi_evidence_types: Option<Vec<String>>,
    app: tauri::AppHandle,
    state: State<'_, OraProcess>,
) -> Result<(), String> {
    if genes.is_empty() {
        return Err(String::from(AppError::analysis_failed(
            "No genes provided for pathway analysis.",
        )));
    }

    let genes_str = genes.join(";");

    // Use the same backend as main analysis (from config store)
    let backend = backend.as_deref().unwrap_or("docker");

    let evidence_types_ref = ppi_evidence_types.clone();
    if backend == "docker" {
        return run_ora_docker(&genes_str, &output_dir, ppi_confidence, organism, evidence_types_ref, app, state)
            .await;
    }

    let project_root = super::analysis::find_project_root().ok_or_else(|| {
        String::from(AppError::analysis_failed(
            "Cannot find project root (ORA_PPI_Analysis.R not found).",
        ))
    })?;

    // Build R command
    let pixi_path = project_root.join(".pixi/envs/default/bin/Rscript");
    let script = "ORA_PPI_Analysis.R";
    let evidence_str = ppi_evidence_types
        .as_ref()
        .map(|types| types.join(","))
        .unwrap_or_default();
    let mut script_args = vec![
        script.to_string(),
        format!("--genes={}", genes_str),
        format!("--output-dir={}", output_dir),
        format!("--ppi-confidence={}", ppi_confidence),
        format!("--organism={}", organism),
    ];
    if !evidence_str.is_empty() {
        script_args.push(format!("--evidence-types={}", evidence_str));
    }

    let (cmd_program, cmd_args) = if pixi_path.exists() {
        (pixi_path.to_string_lossy().to_string(), script_args)
    } else {
        let pixi_available = hide_console(std::process::Command::new("pixi"))
            .arg("--version")
            .current_dir(&project_root)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

        if pixi_available {
            let mut args = vec!["run".to_string(), "Rscript".to_string()];
            args.extend(script_args);
            ("pixi".to_string(), args)
        } else {
            ("Rscript".to_string(), script_args)
        }
    };

    let mut cmd = hide_console(std::process::Command::new(&cmd_program));
    cmd.args(&cmd_args)
        .current_dir(&project_root)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());

    if pixi_path.exists() {
        let r_lib_path = project_root.join(".pixi/envs/default/lib/R/library");
        if r_lib_path.exists() {
            cmd.env("R_LIBS", r_lib_path.to_string_lossy().as_ref());
        }
    }

    let mut child = cmd.spawn().map_err(|e| {
        String::from(AppError::runtime_not_found(&format!(
            "Failed to start R for ORA: {} (tried: {})",
            e, cmd_program
        )))
    })?;

    let _ = app.emit("ora://log", format!("[ORA] Using R: {}", cmd_program));
    let _ = app.emit(
        "ora://log",
        format!("[ORA] Analyzing {} genes", genes.len()),
    );

    let pid = child.id();
    {
        let mut guard = state.child.lock().map_err(|e| e.to_string())?;
        *guard = Some(pid);
    }

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    // Create log file
    let log_file: Arc<Mutex<Option<std::fs::File>>> = {
        let log_dir = PathBuf::from(&output_dir);
        let _ = std::fs::create_dir_all(&log_dir);
        let log_path = log_dir.join("ora_analysis.log");
        match std::fs::File::create(&log_path) {
            Ok(f) => Arc::new(Mutex::new(Some(f))),
            Err(_) => Arc::new(Mutex::new(None)),
        }
    };

    let app_handle = app.clone();

    std::thread::spawn(move || {
        let app_for_stderr = app_handle.clone();
        let log_for_stderr = Arc::clone(&log_file);
        let stderr_thread = stderr.map(|stderr| {
            std::thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines() {
                    if let Ok(line) = line {
                        if let Ok(mut guard) = log_for_stderr.lock() {
                            if let Some(ref mut f) = *guard {
                                let _ = writeln!(f, "[stderr] {}", line);
                            }
                        }
                        if let Some(progress) = parse_ora_progress(&line) {
                            let _ =
                                app_for_stderr.emit("ora://progress", serde_json::json!(progress));
                        }
                        let _ = app_for_stderr.emit("ora://log", &line);
                    }
                }
            })
        });

        if let Some(stdout) = stdout {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                if let Ok(line) = line {
                    if let Ok(mut guard) = log_file.lock() {
                        if let Some(ref mut f) = *guard {
                            let _ = writeln!(f, "[stdout] {}", line);
                        }
                    }
                    let _ = app_handle.emit("ora://log", &line);
                }
            }
        }

        if let Some(handle) = stderr_thread {
            let _ = handle.join();
        }

        match child.wait() {
            Ok(status) => {
                let _ = app_handle.emit(
                    "ora://complete",
                    serde_json::json!({
                        "success": status.success(),
                        "code": status.code()
                    }),
                );
            }
            Err(e) => {
                let _ = app_handle.emit(
                    "ora://error",
                    serde_json::json!({ "message": e.to_string() }),
                );
            }
        }

        let process_state = app_handle.state::<OraProcess>();
        let _ = process_state.child.lock().map(|mut guard| *guard = None);
    });

    Ok(())
}

#[tauri::command]
pub async fn ora_cancel(state: State<'_, OraProcess>) -> Result<(), String> {
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
        Ok(())
    } else {
        Ok(())
    }
}

/// Run ORA via Docker container
async fn run_ora_docker(
    genes_str: &str,
    output_dir: &str,
    ppi_confidence: f64,
    organism: u32,
    ppi_evidence_types: Option<Vec<String>>,
    app: tauri::AppHandle,
    state: State<'_, OraProcess>,
) -> Result<(), String> {
    let output_path = PathBuf::from(output_dir);
    let _ = std::fs::create_dir_all(&output_path);

    fn docker_path(p: &std::path::Path) -> String {
        p.to_string_lossy().replace('\\', "/")
    }

    let mut docker_args = vec![
        "run".to_string(),
        "--rm".to_string(),
        "-v".to_string(),
        format!("{}:/output", docker_path(&output_path)),
        "jyryu3161/biomarkerpred".to_string(),
        "ora".to_string(),
        format!("--genes={}", genes_str),
        "--output-dir=/output".to_string(),
        format!("--ppi-confidence={}", ppi_confidence),
        format!("--organism={}", organism),
    ];
    if let Some(types) = &ppi_evidence_types {
        if !types.is_empty() {
            docker_args.push(format!("--evidence-types={}", types.join(",")));
        }
    }

    let _ = app.emit(
        "ora://log",
        format!("[ORA] Docker mode: docker {}", docker_args.join(" ")),
    );

    let mut child = hide_console(std::process::Command::new(&find_docker()))
        .args(&docker_args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| {
            String::from(AppError::analysis_failed(&format!(
                "Failed to start Docker for ORA: {}",
                e
            )))
        })?;

    let pid = child.id();
    {
        let mut guard = state.child.lock().map_err(|e| e.to_string())?;
        *guard = Some(pid);
    }

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    let log_file: Arc<Mutex<Option<std::fs::File>>> = {
        let log_path = output_path.join("ora_analysis.log");
        match std::fs::File::create(&log_path) {
            Ok(f) => Arc::new(Mutex::new(Some(f))),
            Err(_) => Arc::new(Mutex::new(None)),
        }
    };

    let app_handle = app.clone();

    std::thread::spawn(move || {
        let app_for_stderr = app_handle.clone();
        let log_for_stderr = Arc::clone(&log_file);
        let stderr_thread = stderr.map(|stderr| {
            std::thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines() {
                    if let Ok(line) = line {
                        if let Ok(mut guard) = log_for_stderr.lock() {
                            if let Some(ref mut f) = *guard {
                                let _ = writeln!(f, "[stderr] {}", line);
                            }
                        }
                        if let Some(progress) = parse_ora_progress(&line) {
                            let _ =
                                app_for_stderr.emit("ora://progress", serde_json::json!(progress));
                        }
                        let _ = app_for_stderr.emit("ora://log", &line);
                    }
                }
            })
        });

        if let Some(stdout) = stdout {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                if let Ok(line) = line {
                    if let Ok(mut guard) = log_file.lock() {
                        if let Some(ref mut f) = *guard {
                            let _ = writeln!(f, "[stdout] {}", line);
                        }
                    }
                    let _ = app_handle.emit("ora://log", &line);
                }
            }
        }

        if let Some(handle) = stderr_thread {
            let _ = handle.join();
        }

        match child.wait() {
            Ok(status) => {
                let _ = app_handle.emit(
                    "ora://complete",
                    serde_json::json!({
                        "success": status.success(),
                        "code": status.code()
                    }),
                );
            }
            Err(e) => {
                let _ = app_handle.emit(
                    "ora://error",
                    serde_json::json!({ "message": e.to_string() }),
                );
            }
        }

        let process_state = app_handle.state::<OraProcess>();
        let _ = process_state.child.lock().map(|mut guard| *guard = None);
    });

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_ora_step() {
        let result = parse_ora_progress("ORA_LOG:Step 3 of 8 - GO enrichment analysis");
        assert!(result.is_some());
        let val = result.unwrap();
        assert_eq!(val["current"], 3);
        assert_eq!(val["total"], 8);
        assert_eq!(val["type"], "step");
        assert_eq!(val["message"], "GO enrichment analysis");
    }

    #[test]
    fn test_parse_ora_total() {
        let result = parse_ora_progress("ORA_LOG:Total steps: 8");
        assert!(result.is_some());
        let val = result.unwrap();
        assert_eq!(val["total"], 8);
        assert_eq!(val["type"], "total");
    }

    #[test]
    fn test_parse_ora_done() {
        let result = parse_ora_progress("ORA_LOG:DONE");
        assert!(result.is_some());
        let val = result.unwrap();
        assert_eq!(val["type"], "done");
    }

    #[test]
    fn test_parse_ora_non_matching() {
        let result = parse_ora_progress("[INFO] Some random log line");
        assert!(result.is_none());
    }
}
