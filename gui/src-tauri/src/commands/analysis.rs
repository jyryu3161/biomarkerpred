use super::{find_docker, hide_console};
use crate::models::error::AppError;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::{Emitter, Manager, State};

pub struct AnalysisProcess {
    pub child: Mutex<Option<u32>>, // Store PID for cancellation
}

/// Detect project root by walking up from the executable/resource dir
/// looking for Main_Binary.R (the marker file).
pub(crate) fn find_project_root() -> Option<PathBuf> {
    // Try common locations
    let candidates = [
        // Development: cwd might already be project root
        std::env::current_dir().ok(),
        // Tauri dev: gui/src-tauri is cwd, project root is 2 levels up
        std::env::current_dir().ok().map(|p| p.join("../../").canonicalize().ok()).flatten(),
        // Executable's directory (bundled app)
        std::env::current_exe().ok().and_then(|p| p.parent().map(|p| p.to_path_buf())),
        // Executable parent's parent (macOS .app bundle)
        std::env::current_exe().ok().and_then(|p| {
            p.parent()
                .and_then(|p| p.parent())
                .and_then(|p| p.parent())
                .map(|p| p.to_path_buf())
        }),
    ];

    for candidate in candidates.into_iter().flatten() {
        if candidate.join("Main_Binary.R").exists() {
            return Some(candidate);
        }
    }
    None
}

/// Transform GUI's flat camelCase config into R's nested snake_case YAML structure.
///
/// GUI sends: `{ type, dataFile, sampleId, splitProp, outcome, evidence: { geneFile, ... }, ... }`
/// R expects: `{ workdir, binary: { data_file, sample_id, split_prop, outcome, ... }, evidence: { gene_file, ... } }`
fn transform_config_for_r(config: &serde_json::Value) -> serde_json::Value {
    let analysis_type = config
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("binary");

    let mut r_config = serde_json::Map::new();

    // workdir — use absolute project root path (R's yaml parser treats "." as NA)
    let workdir = find_project_root()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| ".".to_string());
    r_config.insert("workdir".into(), serde_json::json!(workdir));

    // Build the nested analysis section (binary or survival)
    let mut section = serde_json::Map::new();

    // Map flat camelCase keys → nested snake_case keys
    if let Some(v) = config.get("dataFile") {
        section.insert("data_file".into(), v.clone());
    }
    if let Some(v) = config.get("sampleId") {
        section.insert("sample_id".into(), v.clone());
    }
    if let Some(v) = config.get("splitProp") {
        section.insert("split_prop".into(), v.clone());
    }
    if let Some(v) = config.get("numSeed") {
        section.insert("num_seed".into(), v.clone());
    }
    if let Some(v) = config.get("outputDir") {
        section.insert("output_dir".into(), v.clone());
    }
    if let Some(v) = config.get("freq") {
        section.insert("freq".into(), v.clone());
    }
    if let Some(v) = config.get("exclude") {
        section.insert("exclude".into(), v.clone());
    }
    if let Some(v) = config.get("include") {
        section.insert("include".into(), v.clone());
    }
    if let Some(v) = config.get("maxCandidatesPerStep") {
        if !v.is_null() {
            section.insert("max_candidates_per_step".into(), v.clone());
        }
    }
    if let Some(v) = config.get("prescreenSeeds") {
        if !v.is_null() {
            section.insert("prescreen_seeds".into(), v.clone());
        }
    }
    if let Some(v) = config.get("topK") {
        if !v.is_null() {
            section.insert("top_k".into(), v.clone());
        }
    }
    if let Some(v) = config.get("pAdjustMethod") {
        section.insert("p_adjust_method".into(), v.clone());
    }
    if let Some(v) = config.get("pThreshold") {
        section.insert("p_threshold".into(), v.clone());
    }
    // Type-specific keys
    match analysis_type {
        "survival" => {
            // timeVariable only for survival mode
            if let Some(v) = config.get("timeVariable") {
                if !v.is_null() {
                    section.insert("time_variable".into(), v.clone());
                }
            }
            if let Some(v) = config.get("event") {
                section.insert("event".into(), v.clone());
            }
            if let Some(v) = config.get("horizon") {
                section.insert("horizon".into(), v.clone());
            }
            r_config.insert("survival".into(), serde_json::Value::Object(section));
        }
        _ => {
            if let Some(v) = config.get("outcome") {
                section.insert("outcome".into(), v.clone());
            }
            r_config.insert("binary".into(), serde_json::Value::Object(section));
        }
    }

    // Evidence section: transform camelCase → snake_case
    if let Some(evidence) = config.get("evidence") {
        if !evidence.is_null() {
            let mut ev = serde_json::Map::new();
            if let Some(v) = evidence.get("geneFile") {
                ev.insert("gene_file".into(), v.clone());
            }
            if let Some(v) = evidence.get("scoreThreshold") {
                ev.insert("score_threshold".into(), v.clone());
            }
            if let Some(v) = evidence.get("source") {
                ev.insert("source".into(), v.clone());
            }
            if let Some(v) = evidence.get("diseaseName") {
                ev.insert("disease_name".into(), v.clone());
            }
            if let Some(v) = evidence.get("efoId") {
                ev.insert("efo_id".into(), v.clone());
            }
            r_config.insert("evidence".into(), serde_json::Value::Object(ev));
        }
    }

    serde_json::Value::Object(r_config)
}

#[tauri::command]
pub async fn analysis_run(
    config: serde_json::Value,
    app: tauri::AppHandle,
    state: State<'_, AnalysisProcess>,
) -> Result<(), String> {
    // 1. Transform GUI config to R-compatible nested snake_case structure
    let r_config = transform_config_for_r(&config);
    let yaml_str =
        serde_yaml::to_string(&r_config).map_err(|e| String::from(AppError::config_parse_error(&format!("YAML serialization: {}", e))))?;

    let tmp_dir = std::env::temp_dir();
    let config_path = tmp_dir.join(format!(
        "biomarkerpred_{}.yaml",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis()
    ));
    std::fs::write(&config_path, &yaml_str)
        .map_err(|e| String::from(AppError::analysis_failed(&format!("Cannot write temp config: {}", e))))?;

    // 2. Determine analysis type and backend
    let analysis_type = config
        .get("type")
        .and_then(|v| v.as_str())
        .unwrap_or("binary");

    let backend = config
        .get("backend")
        .and_then(|v| v.as_str())
        .unwrap_or("local");

    // Docker execution mode
    if backend == "docker" {
        let at = analysis_type.to_string();
        return run_via_docker(config, &at, &config_path, &yaml_str, app, state).await;
    }

    let script = match analysis_type {
        "survival" => "Main_Survival.R",
        _ => "Main_Binary.R",
    };

    let project_root = find_project_root().ok_or_else(|| {
        String::from(AppError::analysis_failed(
            "Cannot find project root (Main_Binary.R not found). Ensure the app is run from the project directory.",
        ))
    })?;

    // 3. Spawn R process via pixi (for correct R environment) or fall back to system Rscript
    let pixi_path = project_root.join(".pixi/envs/default/bin/Rscript");
    let (cmd_program, cmd_args) = if pixi_path.exists() {
        // Use pixi-managed Rscript directly
        (
            pixi_path.to_string_lossy().to_string(),
            vec![
                script.to_string(),
                format!("--config={}", config_path.to_string_lossy()),
            ],
        )
    } else {
        // Try pixi run (if pixi is installed but env path differs)
        let pixi_available = hide_console(std::process::Command::new("pixi"))
            .arg("--version")
            .current_dir(&project_root)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

        if pixi_available {
            (
                "pixi".to_string(),
                vec![
                    "run".to_string(),
                    "Rscript".to_string(),
                    script.to_string(),
                    format!("--config={}", config_path.to_string_lossy()),
                ],
            )
        } else {
            // Fall back to system Rscript
            (
                "Rscript".to_string(),
                vec![
                    script.to_string(),
                    format!("--config={}", config_path.to_string_lossy()),
                ],
            )
        }
    };

    // Set R library path explicitly to ensure pixi-installed packages are found
    let mut cmd = hide_console(std::process::Command::new(&cmd_program));
    cmd.args(&cmd_args)
        .current_dir(&project_root)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());

    // When using pixi Rscript directly, set R_LIBS to include the pixi library path
    if pixi_path.exists() {
        let r_lib_path = project_root
            .join(".pixi/envs/default/lib/R/library");
        if r_lib_path.exists() {
            cmd.env("R_LIBS", r_lib_path.to_string_lossy().as_ref());
        }
    }

    let mut child = cmd
        .spawn()
        .map_err(|e| String::from(AppError::runtime_not_found(&format!("Failed to start R: {} (tried: {})", e, cmd_program))))?;

    // Emit log showing which R runtime is being used
    let _ = app.emit("analysis://log", format!("[BioMarkerPred] Using R: {}", cmd_program));
    let _ = app.emit("analysis://log", format!("[BioMarkerPred] Working dir: {}", project_root.display()));

    // Store PID for cancellation
    let pid = child.id();
    {
        let mut guard = state.child.lock().map_err(|e| e.to_string())?;
        *guard = Some(pid);
    }

    // 4. Take ownership of stdout and stderr before moving child
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    // 5. Create log file in output directory
    let output_dir = config
        .get("outputDir")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let log_file: Arc<Mutex<Option<std::fs::File>>> = if !output_dir.is_empty() {
        let log_dir = PathBuf::from(output_dir);
        let _ = std::fs::create_dir_all(&log_dir);
        let log_path = log_dir.join("analysis.log");
        match std::fs::File::create(&log_path) {
            Ok(f) => Arc::new(Mutex::new(Some(f))),
            Err(_) => Arc::new(Mutex::new(None)),
        }
    } else {
        Arc::new(Mutex::new(None))
    };

    // 6. Stream output in background threads
    let app_handle = app.clone();

    std::thread::spawn(move || {
        // Spawn stderr reader thread (R prints progress to stderr)
        let app_for_stderr = app_handle.clone();
        let log_for_stderr = Arc::clone(&log_file);
        let stderr_thread = stderr.map(|stderr| {
            std::thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines() {
                    if let Ok(line) = line {
                        // Write to log file
                        if let Ok(mut guard) = log_for_stderr.lock() {
                            if let Some(ref mut f) = *guard {
                                let _ = writeln!(f, "[stderr] {}", line);
                            }
                        }
                        // Parse progress lines
                        if let Some(progress) = parse_progress_line(&line) {
                            let _ = app_for_stderr.emit(
                                "analysis://progress",
                                serde_json::json!(progress),
                            );
                        }
                        let _ = app_for_stderr.emit("analysis://log", &line);
                    }
                }
            })
        });

        // Stream stdout in this thread
        if let Some(stdout) = stdout {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                if let Ok(line) = line {
                    // Write to log file
                    if let Ok(mut guard) = log_file.lock() {
                        if let Some(ref mut f) = *guard {
                            let _ = writeln!(f, "[stdout] {}", line);
                        }
                    }
                    let _ = app_handle.emit("analysis://log", &line);
                }
            }
        }

        // Wait for stderr thread to finish
        if let Some(handle) = stderr_thread {
            let _ = handle.join();
        }

        // Wait for the process to complete
        match child.wait() {
            Ok(status) => {
                let _ = app_handle.emit(
                    "analysis://complete",
                    serde_json::json!({
                        "success": status.success(),
                        "code": status.code()
                    }),
                );
            }
            Err(e) => {
                let _ = app_handle.emit(
                    "analysis://error",
                    serde_json::json!({
                        "message": e.to_string()
                    }),
                );
            }
        }

        // Clear PID
        let process_state = app_handle.state::<AnalysisProcess>();
        let _ = process_state.child.lock().map(|mut guard| *guard = None);
    });

    Ok(())
}

#[tauri::command]
pub async fn analysis_cancel(state: State<'_, AnalysisProcess>) -> Result<(), String> {
    let mut guard = state.child.lock().map_err(|e| e.to_string())?;
    if let Some(pid) = *guard {
        // Kill process by PID
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

/// Run analysis via Docker container
async fn run_via_docker(
    config: serde_json::Value,
    analysis_type: &str,
    _config_path: &PathBuf,
    _yaml_str: &str,
    app: tauri::AppHandle,
    state: State<'_, AnalysisProcess>,
) -> Result<(), String> {
    let data_file = config
        .get("dataFile")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let output_dir = config
        .get("outputDir")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    if data_file.is_empty() || output_dir.is_empty() {
        return Err(String::from(AppError::analysis_failed(
            "dataFile and outputDir are required for Docker mode.",
        )));
    }

    let data_path = PathBuf::from(data_file);
    let data_dir = data_path
        .parent()
        .ok_or_else(|| String::from(AppError::analysis_failed("Invalid data file path")))?;
    let data_filename = data_path
        .file_name()
        .ok_or_else(|| String::from(AppError::analysis_failed("Invalid data file name")))?
        .to_string_lossy();

    let output_path = PathBuf::from(output_dir);
    let _ = std::fs::create_dir_all(&output_path);

    // Build docker config with remapped paths
    let mut docker_config = config.clone();
    if let Some(obj) = docker_config.as_object_mut() {
        obj.insert("dataFile".into(), serde_json::json!(format!("/data/{}", data_filename)));
        obj.insert("outputDir".into(), serde_json::json!("/output"));
        obj.remove("backend");

        // Remap evidence gene file path to Docker mount point
        if let Some(evidence) = obj.get_mut("evidence") {
            if let Some(ev_obj) = evidence.as_object_mut() {
                if let Some(gene_file) = ev_obj.get("geneFile").and_then(|v| v.as_str()).map(String::from) {
                    if let Some(filename) = PathBuf::from(&gene_file).file_name() {
                        ev_obj.insert("geneFile".into(),
                            serde_json::json!(format!("/evidence/{}", filename.to_string_lossy())));
                    }
                }
            }
        }
    }

    // Transform for R and write to temp — override workdir to Docker's /app
    let mut r_config = transform_config_for_r(&docker_config);
    if let Some(obj) = r_config.as_object_mut() {
        obj.insert("workdir".into(), serde_json::json!("/app"));
    }
    let docker_yaml = serde_yaml::to_string(&r_config)
        .map_err(|e| String::from(AppError::config_parse_error(&format!("YAML serialization: {}", e))))?;

    let tmp_dir = std::env::temp_dir();
    let docker_config_path = tmp_dir.join(format!(
        "biomarkerpred_docker_{}.yaml",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis()
    ));
    std::fs::write(&docker_config_path, &docker_yaml)
        .map_err(|e| String::from(AppError::analysis_failed(&format!("Cannot write docker config: {}", e))))?;

    // Normalize path for Docker volume mounts (Windows backslashes → forward slashes)
    fn docker_path(p: &std::path::Path) -> String {
        p.to_string_lossy().replace('\\', "/")
    }

    // Build docker command
    let mut docker_args = vec![
        "run".to_string(),
        "--rm".to_string(),
        "-v".to_string(),
        format!("{}:/data:ro", docker_path(data_dir)),
        "-v".to_string(),
        format!("{}:/output", docker_path(&output_path)),
        "-v".to_string(),
        format!("{}:/config.yaml:ro", docker_path(&docker_config_path)),
    ];

    // Mount evidence file directory if present
    if let Some(evidence) = config.get("evidence") {
        if !evidence.is_null() {
            if let Some(gene_file) = evidence.get("geneFile").and_then(|v| v.as_str()) {
                if let Some(ev_dir) = PathBuf::from(gene_file).parent() {
                    docker_args.push("-v".to_string());
                    docker_args.push(format!("{}:/evidence:ro", docker_path(ev_dir)));
                }
            }
        }
    }

    // Mount local R scripts into the container to override the image versions.
    // This ensures Save_Model.R, Predict_New.R, and updated Main scripts are used
    // without requiring a Docker image rebuild.
    if let Some(project_root) = find_project_root() {
        let r_scripts = [
            "Main_Binary.R",
            "Main_Survival.R",
            "Binary_TrainAUC_StepwiseSelection.R",
            "Survival_TrainAUC_StepwiseSelection.R",
            "Save_Model.R",
            "Predict_New.R",
        ];
        for script in &r_scripts {
            let script_path = project_root.join(script);
            if script_path.exists() {
                docker_args.push("-v".to_string());
                docker_args.push(format!("{}:/app/{}:ro", docker_path(&script_path), script));
            }
        }
    }

    docker_args.push("jyryu3161/biomarkerpred".to_string());
    docker_args.push(analysis_type.to_string());
    docker_args.push("--config=/config.yaml".to_string());

    let _ = app.emit("analysis://log", format!("[BioMarkerPred] Docker mode: docker {}", docker_args.join(" ")));

    let mut child = hide_console(std::process::Command::new(&find_docker()))
        .args(&docker_args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| String::from(AppError::analysis_failed(&format!("Failed to start Docker: {}", e))))?;

    let pid = child.id();
    {
        let mut guard = state.child.lock().map_err(|e| e.to_string())?;
        *guard = Some(pid);
    }

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    // Create log file in output directory
    let log_file: Arc<Mutex<Option<std::fs::File>>> = {
        let log_path = output_path.join("analysis.log");
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
                        if let Some(progress) = parse_progress_line(&line) {
                            let _ = app_for_stderr.emit("analysis://progress", serde_json::json!(progress));
                        }
                        let _ = app_for_stderr.emit("analysis://log", &line);
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
                    let _ = app_handle.emit("analysis://log", &line);
                }
            }
        }

        if let Some(handle) = stderr_thread {
            let _ = handle.join();
        }

        match child.wait() {
            Ok(status) => {
                let _ = app_handle.emit(
                    "analysis://complete",
                    serde_json::json!({
                        "success": status.success(),
                        "code": status.code()
                    }),
                );
            }
            Err(e) => {
                let _ = app_handle.emit(
                    "analysis://error",
                    serde_json::json!({ "message": e.to_string() }),
                );
            }
        }

        let process_state = app_handle.state::<AnalysisProcess>();
        let _ = process_state.child.lock().map(|mut guard| *guard = None);
    });

    Ok(())
}

/// Parse R progress output lines.
/// Supports:
///   - `STEPWISE_LOG:Iteration 99 of 100 ( 99 %)`
///   - `STEPWISE_LOG:Iteration 99 completed - N significant variables ...`
///   - `STEPWISE_LOG:Total iterations: 100 , Variables: 293`
///   - `[1/100] Iteration 1`
fn parse_progress_line(line: &str) -> Option<serde_json::Value> {
    // Pattern 1a: STEPWISE_LOG:Iteration X of Y (explicit progress)
    if let Some(rest) = line.strip_prefix("STEPWISE_LOG:Iteration ") {
        let parts: Vec<&str> = rest.splitn(3, ' ').collect();

        // "X of Y (...)"
        if parts.len() >= 3 && parts[1] == "of" {
            if let Ok(current) = parts[0].trim().parse::<u32>() {
                let total_str = parts[2].split_whitespace().next().unwrap_or("0");
                if let Ok(total) = total_str.parse::<u32>() {
                    return Some(serde_json::json!({
                        "type": "iteration",
                        "current": current,
                        "total": total,
                        "message": format!("Iteration {}/{}", current, total),
                    }));
                }
            }
        }

        // "X completed - ..." (use iteration number as progress)
        if parts.len() >= 2 && parts[1] == "completed" {
            if let Ok(current) = parts[0].trim().parse::<u32>() {
                return Some(serde_json::json!({
                    "type": "iteration_complete",
                    "current": current,
                    "total": 0,
                    "message": rest.to_string(),
                }));
            }
        }

        return None;
    }

    // Pattern 1b: STEPWISE_LOG:Total iterations: X , Variables: Y
    // Use this to set total
    if let Some(rest) = line.strip_prefix("STEPWISE_LOG:Total iterations:") {
        // " 100 , Variables: 293"
        let total_str = rest.split(',').next().unwrap_or("").trim();
        if let Ok(total) = total_str.parse::<u32>() {
            return Some(serde_json::json!({
                "type": "total",
                "current": 0,
                "total": total,
                "message": format!("Starting {} iterations", total),
            }));
        }
    }

    // Pattern 2: [current/total] message
    if line.starts_with('[') {
        if let Some(bracket_end) = line.find(']') {
            let inner = &line[1..bracket_end];
            if let Some((current_str, total_str)) = inner.split_once('/') {
                if let (Ok(current), Ok(total)) =
                    (current_str.trim().parse::<u32>(), total_str.trim().parse::<u32>())
                {
                    let message = line[bracket_end + 1..].trim().to_string();
                    return Some(serde_json::json!({
                        "type": "iteration",
                        "current": current,
                        "total": total,
                        "message": message,
                    }));
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_progress_standard() {
        let result = parse_progress_line("[1/100] Iteration 1 completed");
        assert!(result.is_some());
        let val = result.unwrap();
        assert_eq!(val["current"], 1);
        assert_eq!(val["total"], 100);
        assert_eq!(val["type"], "iteration");
        assert_eq!(val["message"], "Iteration 1 completed");
    }

    #[test]
    fn test_parse_progress_with_spaces() {
        let result = parse_progress_line("[ 5 / 20 ] Step 5 running");
        assert!(result.is_some());
        let val = result.unwrap();
        assert_eq!(val["current"], 5);
        assert_eq!(val["total"], 20);
    }

    #[test]
    fn test_parse_progress_no_bracket() {
        let result = parse_progress_line("Some regular log line");
        assert!(result.is_none());
    }

    #[test]
    fn test_parse_progress_invalid_numbers() {
        let result = parse_progress_line("[abc/def] bad data");
        assert!(result.is_none());
    }

    #[test]
    fn test_parse_progress_empty_message() {
        let result = parse_progress_line("[3/10]");
        assert!(result.is_some());
        let val = result.unwrap();
        assert_eq!(val["current"], 3);
        assert_eq!(val["total"], 10);
        assert_eq!(val["message"], "");
    }

    #[test]
    fn test_parse_stepwise_log_iteration() {
        let result = parse_progress_line("STEPWISE_LOG:Iteration 50 of 100 ( 50 %)");
        assert!(result.is_some());
        let val = result.unwrap();
        assert_eq!(val["current"], 50);
        assert_eq!(val["total"], 100);
        assert_eq!(val["message"], "Iteration 50/100");
    }

    #[test]
    fn test_parse_stepwise_log_complete() {
        let result = parse_progress_line("STEPWISE_LOG:Iteration 100 of 100 ( 100 %)");
        assert!(result.is_some());
        let val = result.unwrap();
        assert_eq!(val["current"], 100);
        assert_eq!(val["total"], 100);
    }

    #[test]
    fn test_parse_stepwise_log_completed_line() {
        let result = parse_progress_line("STEPWISE_LOG:Iteration 5 completed - 3 significant variables (adjusted p < 0.05 )");
        assert!(result.is_some());
        let val = result.unwrap();
        assert_eq!(val["current"], 5);
        assert_eq!(val["type"], "iteration_complete");
    }

    #[test]
    fn test_parse_stepwise_log_total_iterations() {
        let result = parse_progress_line("STEPWISE_LOG:Total iterations: 100 , Variables: 293 ");
        assert!(result.is_some());
        let val = result.unwrap();
        assert_eq!(val["total"], 100);
        assert_eq!(val["type"], "total");
    }

    #[test]
    fn test_parse_stepwise_log_subprogress_ignored() {
        let result = parse_progress_line("STEPWISE_LOG:Iteration 99 - Processing variable 250 of 293");
        assert!(result.is_none());
    }

    #[test]
    fn test_transform_binary_config() {
        let gui_config = serde_json::json!({
            "type": "binary",
            "dataFile": "/data/test.csv",
            "sampleId": "sample",
            "outcome": "OS",
            "splitProp": 0.7,
            "numSeed": 100,
            "outputDir": "results/binary",
            "freq": 50,
            "exclude": [],
            "include": [],
            "maxCandidatesPerStep": null,
            "prescreenSeeds": null,
            "topK": null,
            "pAdjustMethod": "fdr",
            "pThreshold": 0.05,
            "evidence": null
        });

        let r_config = transform_config_for_r(&gui_config);

        // workdir should be a non-empty string (absolute path or ".")
        assert!(r_config["workdir"].is_string());
        assert!(!r_config["workdir"].as_str().unwrap().is_empty());
        assert!(r_config.get("binary").is_some());
        assert!(r_config.get("survival").is_none());

        let binary = &r_config["binary"];
        assert_eq!(binary["data_file"], "/data/test.csv");
        assert_eq!(binary["sample_id"], "sample");
        assert_eq!(binary["outcome"], "OS");
        assert_eq!(binary["split_prop"], 0.7);
        assert_eq!(binary["num_seed"], 100);
        assert_eq!(binary["output_dir"], "results/binary");
        assert_eq!(binary["freq"], 50);
        assert_eq!(binary["p_adjust_method"], "fdr");
        assert_eq!(binary["p_threshold"], 0.05);
        // Null optional fields should not be present
        assert!(binary.get("max_candidates_per_step").is_none());
        assert!(binary.get("top_k").is_none());
    }

    #[test]
    fn test_transform_survival_config() {
        let gui_config = serde_json::json!({
            "type": "survival",
            "dataFile": "/data/test.csv",
            "sampleId": "sample",
            "event": "OS",
            "timeVariable": "OS.year",
            "horizon": 5,
            "splitProp": 0.7,
            "numSeed": 100,
            "outputDir": "results/survival",
            "freq": 50,
            "exclude": [],
            "include": [],
            "pAdjustMethod": "fdr",
            "pThreshold": 0.05,
            "evidence": null
        });

        let r_config = transform_config_for_r(&gui_config);

        assert!(r_config.get("survival").is_some());
        assert!(r_config.get("binary").is_none());

        let survival = &r_config["survival"];
        assert_eq!(survival["event"], "OS");
        assert_eq!(survival["time_variable"], "OS.year");
        assert_eq!(survival["horizon"], 5);
    }

    #[test]
    fn test_transform_config_with_evidence() {
        let gui_config = serde_json::json!({
            "type": "binary",
            "dataFile": "/data/test.csv",
            "sampleId": "sample",
            "outcome": "OS",
            "splitProp": 0.7,
            "numSeed": 100,
            "outputDir": "results",
            "freq": 50,
            "exclude": [],
            "include": [],
            "pAdjustMethod": "fdr",
            "pThreshold": 0.05,
            "evidence": {
                "geneFile": "/evidence/genes.csv",
                "scoreThreshold": 0.1,
                "source": "Open Targets Platform",
                "diseaseName": "breast carcinoma",
                "efoId": "EFO_0000305"
            }
        });

        let r_config = transform_config_for_r(&gui_config);

        let evidence = &r_config["evidence"];
        assert_eq!(evidence["gene_file"], "/evidence/genes.csv");
        assert_eq!(evidence["score_threshold"], 0.1);
        assert_eq!(evidence["disease_name"], "breast carcinoma");
        assert_eq!(evidence["efo_id"], "EFO_0000305");
    }

    #[test]
    fn test_transform_binary_excludes_time_variable() {
        let gui_config = serde_json::json!({
            "type": "binary",
            "dataFile": "/data/test.csv",
            "sampleId": "sample",
            "outcome": "OS",
            "timeVariable": "OS.year",
            "splitProp": 0.7,
            "numSeed": 100,
            "outputDir": "results/binary",
            "freq": 50,
            "exclude": [],
            "include": [],
            "pAdjustMethod": "fdr",
            "pThreshold": 0.05,
            "evidence": null
        });

        let r_config = transform_config_for_r(&gui_config);

        let binary = &r_config["binary"];
        // time_variable must NOT be present in binary mode
        assert!(binary.get("time_variable").is_none());
    }
}
