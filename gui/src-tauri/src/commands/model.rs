use super::{find_docker, hide_console};
use crate::commands::analysis::find_project_root;
use crate::models::error::AppError;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{Emitter, Manager, State};

pub struct PredictionProcess {
    pub child: Mutex<Option<u32>>,
}

/// Model metadata returned to the frontend after loading a .bmpmodel file.
#[derive(serde::Serialize)]
pub struct ModelInfo {
    pub version: String,
    pub created_at: String,
    pub analysis_type: String,
    pub variable_count: usize,
    pub variables: Vec<String>,
    pub formula: String,
    pub train_auc: f64,
    pub test_auc: f64,
    pub optimal_threshold: Option<f64>,
    pub training_data_file: String,
    pub training_sample_count: u32,
    /// Embedded analysis config (for restoring setup state on load)
    pub config: Option<serde_json::Value>,
}

/// Load and validate a .bmpmodel file, returning its metadata.
#[tauri::command]
pub async fn model_load(path: String) -> Result<ModelInfo, String> {
    let content = std::fs::read_to_string(&path)
        .map_err(|e| format!("Cannot read model file: {}", e))?;

    let model: serde_json::Value = serde_json::from_str(&content)
        .map_err(|e| format!("Invalid model file format: {}", e))?;

    // Validate required fields
    let version = model
        .get("version")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown")
        .to_string();

    let analysis_type = model
        .get("analysis_type")
        .and_then(|v| v.as_str())
        .ok_or("Missing analysis_type field")?
        .to_string();

    let model_section = model
        .get("model")
        .ok_or("Missing model section")?;

    let variables: Vec<String> = model_section
        .get("variables")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    let formula = model_section
        .get("formula")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let optimal_threshold = model_section
        .get("optimal_threshold")
        .and_then(|v| v.as_f64());

    let performance = model.get("performance");
    let train_auc = performance
        .and_then(|p| p.get("train_auc"))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let test_auc = performance
        .and_then(|p| p.get("test_auc"))
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);

    let training_config = model.get("training_config");
    let training_data_file = training_config
        .and_then(|c| c.get("data_file"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let training_sample_count = training_config
        .and_then(|c| c.get("sample_count"))
        .and_then(|v| v.as_u64())
        .unwrap_or(0) as u32;

    // Validate we have at least variables and coefficients
    if variables.is_empty() {
        return Err("Model has no variables".into());
    }
    let coefficients = model_section.get("coefficients");
    if coefficients.is_none() || !coefficients.unwrap().is_object() {
        return Err("Model has no coefficients".into());
    }

    // Extract embedded config if present
    let config = model.get("config").cloned();

    Ok(ModelInfo {
        version,
        created_at: model
            .get("created_at")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        analysis_type,
        variable_count: variables.len(),
        variables,
        formula,
        train_auc,
        test_auc,
        optimal_threshold,
        training_data_file,
        training_sample_count,
        config,
    })
}

/// Copy a model.bmpmodel from the output directory to a user-chosen location.
#[tauri::command]
pub async fn model_save(source_path: String, dest_path: String) -> Result<String, String> {
    if !std::path::Path::new(&source_path).exists() {
        return Err(String::from(AppError::file_not_found(&format!(
            "Model file not found: {}",
            source_path
        ))));
    }

    std::fs::copy(&source_path, &dest_path)
        .map_err(|e| format!("Failed to save model: {}", e))?;

    Ok(dest_path)
}

/// Check if a model.bmpmodel exists in the given output directory.
#[tauri::command]
pub async fn model_check_exists(output_dir: String) -> Result<Option<String>, String> {
    let model_path = PathBuf::from(&output_dir).join("model.bmpmodel");
    if model_path.exists() {
        Ok(Some(model_path.to_string_lossy().to_string()))
    } else {
        Ok(None)
    }
}

/// Run prediction using a saved model and new data.
#[tauri::command]
pub async fn prediction_run(
    model_path: String,
    data_path: String,
    output_dir: String,
    backend: String,
    app: tauri::AppHandle,
    state: State<'_, PredictionProcess>,
) -> Result<(), String> {
    let output_path = PathBuf::from(&output_dir);
    let _ = std::fs::create_dir_all(&output_path);

    if backend == "docker" {
        return run_prediction_docker(model_path, data_path, output_dir, app, state).await;
    }

    // Local mode
    let project_root = find_project_root().ok_or_else(|| {
        String::from(AppError::analysis_failed(
            "Cannot find project root (Predict_New.R not found).",
        ))
    })?;

    let predict_script = project_root.join("Predict_New.R");
    if !predict_script.exists() {
        return Err("Predict_New.R not found in project root".into());
    }

    let pixi_path = project_root.join(".pixi/envs/default/bin/Rscript");
    let (cmd_program, cmd_args) = if pixi_path.exists() {
        (
            pixi_path.to_string_lossy().to_string(),
            vec![
                "Predict_New.R".to_string(),
                format!("--model={}", model_path),
                format!("--data={}", data_path),
                format!("--output={}", output_dir),
            ],
        )
    } else {
        (
            "Rscript".to_string(),
            vec![
                "Predict_New.R".to_string(),
                format!("--model={}", model_path),
                format!("--data={}", data_path),
                format!("--output={}", output_dir),
            ],
        )
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
            "Failed to start R for prediction: {}",
            e
        )))
    })?;

    let _ = app.emit(
        "prediction://log",
        format!("[BioMarkerPred] Prediction using: {}", cmd_program),
    );

    let pid = child.id();
    {
        let mut guard = state.child.lock().map_err(|e| e.to_string())?;
        *guard = Some(pid);
    }

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let app_handle = app.clone();

    std::thread::spawn(move || {
        let app_for_stderr = app_handle.clone();
        let stderr_thread = stderr.map(|stderr| {
            std::thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines() {
                    if let Ok(line) = line {
                        let _ = app_for_stderr.emit("prediction://log", &line);
                    }
                }
            })
        });

        if let Some(stdout) = stdout {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                if let Ok(line) = line {
                    let _ = app_handle.emit("prediction://log", &line);
                }
            }
        }

        if let Some(handle) = stderr_thread {
            let _ = handle.join();
        }

        match child.wait() {
            Ok(status) => {
                let _ = app_handle.emit(
                    "prediction://complete",
                    serde_json::json!({
                        "success": status.success(),
                        "code": status.code()
                    }),
                );
            }
            Err(e) => {
                let _ = app_handle.emit(
                    "prediction://error",
                    serde_json::json!({ "message": e.to_string() }),
                );
            }
        }

        let process_state = app_handle.state::<PredictionProcess>();
        let _ = process_state
            .child
            .lock()
            .map(|mut guard| *guard = None);
    });

    Ok(())
}

/// Cancel a running prediction process.
#[tauri::command]
pub async fn prediction_cancel(state: State<'_, PredictionProcess>) -> Result<(), String> {
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

/// Read prediction results CSV and return as JSON array.
#[tauri::command]
pub async fn prediction_read_results(output_dir: String) -> Result<serde_json::Value, String> {
    let results_path = PathBuf::from(&output_dir).join("prediction_results.csv");
    if !results_path.exists() {
        return Err("Prediction results file not found".into());
    }

    let mut reader = csv::Reader::from_path(&results_path)
        .map_err(|e| format!("Cannot read results CSV: {}", e))?;

    let headers: Vec<String> = reader
        .headers()
        .map_err(|e| format!("Cannot read CSV headers: {}", e))?
        .iter()
        .map(String::from)
        .collect();

    let mut rows: Vec<serde_json::Value> = Vec::new();
    for result in reader.records() {
        let record = result.map_err(|e| format!("CSV parse error: {}", e))?;
        let mut row = serde_json::Map::new();
        for (i, field) in record.iter().enumerate() {
            if let Some(header) = headers.get(i) {
                // Try to parse as number, fall back to string
                if let Ok(n) = field.parse::<f64>() {
                    row.insert(header.clone(), serde_json::json!(n));
                } else if let Ok(n) = field.parse::<i64>() {
                    row.insert(header.clone(), serde_json::json!(n));
                } else {
                    row.insert(header.clone(), serde_json::json!(field));
                }
            }
        }
        rows.push(serde_json::Value::Object(row));
    }

    Ok(serde_json::json!({
        "headers": headers,
        "rows": rows,
        "count": rows.len()
    }))
}

/// Run prediction via Docker container.
async fn run_prediction_docker(
    model_path: String,
    data_path: String,
    output_dir: String,
    app: tauri::AppHandle,
    state: State<'_, PredictionProcess>,
) -> Result<(), String> {
    let model_pb = PathBuf::from(&model_path);
    let data_pb = PathBuf::from(&data_path);
    let output_pb = PathBuf::from(&output_dir);

    let model_dir = model_pb
        .parent()
        .ok_or("Invalid model file path")?;
    let model_filename = model_pb
        .file_name()
        .ok_or("Invalid model file name")?
        .to_string_lossy();

    let data_dir = data_pb
        .parent()
        .ok_or("Invalid data file path")?;
    let data_filename = data_pb
        .file_name()
        .ok_or("Invalid data file name")?
        .to_string_lossy();

    let _ = std::fs::create_dir_all(&output_pb);

    fn docker_path(p: &std::path::Path) -> String {
        p.to_string_lossy().replace('\\', "/")
    }

    let mut docker_args = vec![
        "run".to_string(),
        "--rm".to_string(),
        "-v".to_string(),
        format!("{}:/model:ro", docker_path(model_dir)),
        "-v".to_string(),
        format!("{}:/data:ro", docker_path(data_dir)),
        "-v".to_string(),
        format!("{}:/output", docker_path(&output_pb)),
    ];

    // Mount Predict_New.R and updated entrypoint from project root
    // (needed until Docker image is rebuilt to include these files)
    if let Some(project_root) = find_project_root() {
        let predict_new = project_root.join("Predict_New.R");
        if predict_new.exists() {
            docker_args.push("-v".to_string());
            docker_args.push(format!("{}:/app/Predict_New.R:ro", docker_path(&predict_new)));
        }
        let entrypoint = project_root.join("docker-entrypoint.sh");
        if entrypoint.exists() {
            docker_args.push("-v".to_string());
            docker_args.push(format!("{}:/usr/local/bin/docker-entrypoint.sh:ro", docker_path(&entrypoint)));
        }
    }

    docker_args.push("jyryu3161/biomarkerpred".to_string());
    docker_args.push("predict".to_string());
    docker_args.push(format!("--model=/model/{}", model_filename));
    docker_args.push(format!("--data=/data/{}", data_filename));
    docker_args.push("--output=/output".to_string());

    let _ = app.emit(
        "prediction://log",
        format!(
            "[BioMarkerPred] Docker prediction: docker {}",
            docker_args.join(" ")
        ),
    );

    let mut child = hide_console(std::process::Command::new(&find_docker()))
        .args(&docker_args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| {
            String::from(AppError::analysis_failed(&format!(
                "Failed to start Docker for prediction: {}",
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
    let app_handle = app.clone();

    std::thread::spawn(move || {
        let app_for_stderr = app_handle.clone();
        let stderr_thread = stderr.map(|stderr| {
            std::thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines() {
                    if let Ok(line) = line {
                        let _ = app_for_stderr.emit("prediction://log", &line);
                    }
                }
            })
        });

        if let Some(stdout) = stdout {
            let reader = BufReader::new(stdout);
            for line in reader.lines() {
                if let Ok(line) = line {
                    let _ = app_handle.emit("prediction://log", &line);
                }
            }
        }

        if let Some(handle) = stderr_thread {
            let _ = handle.join();
        }

        match child.wait() {
            Ok(status) => {
                let _ = app_handle.emit(
                    "prediction://complete",
                    serde_json::json!({
                        "success": status.success(),
                        "code": status.code()
                    }),
                );
            }
            Err(e) => {
                let _ = app_handle.emit(
                    "prediction://error",
                    serde_json::json!({ "message": e.to_string() }),
                );
            }
        }

        let process_state = app_handle.state::<PredictionProcess>();
        let _ = process_state
            .child
            .lock()
            .map(|mut guard| *guard = None);
    });

    Ok(())
}
