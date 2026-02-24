use crate::models::config::TcgaPreset;
use crate::models::error::AppError;
use std::fs;
use tauri::Manager;

#[tauri::command]
pub async fn config_load_yaml(path: String) -> Result<serde_json::Value, String> {
    let content = fs::read_to_string(&path)
        .map_err(|e| String::from(AppError::file_not_found(&format!("{}: {}", path, e))))?;
    let yaml_value: serde_yaml::Value = serde_yaml::from_str(&content)
        .map_err(|e| String::from(AppError::config_parse_error(&format!("YAML: {}", e))))?;
    let json_value = serde_json::to_value(yaml_value)
        .map_err(|e| String::from(AppError::config_parse_error(&format!("JSON conversion: {}", e))))?;
    Ok(json_value)
}

#[tauri::command]
pub async fn config_save_yaml(
    config: serde_json::Value,
    path: String,
) -> Result<String, String> {
    let yaml_string = serde_yaml::to_string(&config)
        .map_err(|e| String::from(AppError::config_parse_error(&format!("YAML serialize: {}", e))))?;
    fs::write(&path, &yaml_string)
        .map_err(|e| String::from(AppError::file_not_found(&format!("{}: {}", path, e))))?;
    Ok(path)
}

#[tauri::command]
pub async fn config_list_presets(app: tauri::AppHandle) -> Result<Vec<TcgaPreset>, String> {
    // Look for config/*.yaml files in the app resource directory or project root
    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|e| format!("Cannot get resource dir: {}", e))?;

    let config_dir = resource_dir.join("config");
    if !config_dir.exists() {
        return Ok(Vec::new());
    }

    let mut presets = Vec::new();
    let entries = fs::read_dir(&config_dir)
        .map_err(|e| format!("Cannot read config dir: {}", e))?;

    for entry in entries.flatten() {
        let path = entry.path();
        if let Some(ext) = path.extension() {
            if ext == "yaml" || ext == "yml" {
                let filename = path.file_stem().unwrap_or_default().to_string_lossy();
                if filename.starts_with("TCGA_") && filename.ends_with("_analysis") {
                    let id = filename
                        .replace("_analysis", "")
                        .replace("_opentargets", "");
                    let has_evidence = filename.contains("opentargets");
                    let label = id.replace("TCGA_", "").replace('_', " ");

                    presets.push(TcgaPreset {
                        id: id.to_string(),
                        label,
                        config_path: path.to_string_lossy().to_string(),
                        has_evidence,
                    });
                }
            }
        }
    }

    presets.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(presets)
}

#[tauri::command]
pub async fn config_load_preset(preset_id: String, app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|e| format!("Cannot get resource dir: {}", e))?;

    let config_path = resource_dir
        .join("config")
        .join(format!("{}_analysis.yaml", preset_id));

    if !config_path.exists() {
        return Err(String::from(AppError::file_not_found(&format!("Preset not found: {}", preset_id))));
    }

    config_load_yaml(config_path.to_string_lossy().to_string()).await
}

#[tauri::command]
pub async fn config_validate(config: serde_json::Value) -> Result<Vec<String>, String> {
    let mut errors = Vec::new();

    // Check required fields
    if config.get("dataFile").and_then(|v| v.as_str()).unwrap_or("").is_empty() {
        errors.push("Data file is required".to_string());
    }
    if config.get("sampleId").and_then(|v| v.as_str()).unwrap_or("").is_empty() {
        errors.push("Sample ID column is required".to_string());
    }
    if config.get("outputDir").and_then(|v| v.as_str()).unwrap_or("").is_empty() {
        errors.push("Output directory is required".to_string());
    }

    // Check type-specific fields
    let analysis_type = config.get("type").and_then(|v| v.as_str()).unwrap_or("");
    match analysis_type {
        "binary" => {
            if config.get("outcome").and_then(|v| v.as_str()).unwrap_or("").is_empty() {
                errors.push("Outcome column is required for binary analysis".to_string());
            }
        }
        "survival" => {
            if config.get("event").and_then(|v| v.as_str()).unwrap_or("").is_empty() {
                errors.push("Event column is required for survival analysis".to_string());
            }
            if config.get("horizon").and_then(|v| v.as_f64()).unwrap_or(0.0) <= 0.0 {
                errors.push("Horizon must be positive for survival analysis".to_string());
            }
        }
        _ => {
            errors.push(format!("Unknown analysis type: '{}'", analysis_type));
        }
    }

    // Validate numeric ranges
    if let Some(split_prop) = config.get("splitProp").and_then(|v| v.as_f64()) {
        if !(0.5..=0.9).contains(&split_prop) {
            errors.push("Split proportion must be between 0.5 and 0.9".to_string());
        }
    }
    if let Some(num_seed) = config.get("numSeed").and_then(|v| v.as_i64()) {
        if num_seed < 1 {
            errors.push("Number of seeds must be at least 1".to_string());
        }
    }

    // Validate data file exists
    if let Some(data_file) = config.get("dataFile").and_then(|v| v.as_str()) {
        if !data_file.is_empty() && !std::path::Path::new(data_file).exists() {
            errors.push(format!("Data file not found: {}", data_file));
        }
    }

    Ok(errors)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_config(overrides: serde_json::Value) -> serde_json::Value {
        let mut base = serde_json::json!({
            "type": "binary",
            "dataFile": "/tmp/test.csv",
            "sampleId": "sample_id",
            "outputDir": "/tmp/output",
            "outcome": "status",
            "splitProp": 0.7,
            "numSeed": 100
        });
        if let (Some(base_map), Some(overrides_map)) = (base.as_object_mut(), overrides.as_object()) {
            for (k, v) in overrides_map {
                base_map.insert(k.clone(), v.clone());
            }
        }
        base
    }

    #[tokio::test]
    async fn test_validate_valid_binary_config() {
        let config = make_config(serde_json::json!({}));
        let errors = config_validate(config).await.unwrap();
        // dataFile won't exist in test env, so expect only that error
        let non_file_errors: Vec<_> = errors.iter().filter(|e| !e.contains("not found")).collect();
        assert!(non_file_errors.is_empty(), "Got unexpected errors: {:?}", non_file_errors);
    }

    #[tokio::test]
    async fn test_validate_missing_required_fields() {
        let config = serde_json::json!({
            "type": "binary",
            "dataFile": "",
            "sampleId": "",
            "outputDir": "",
            "outcome": ""
        });
        let errors = config_validate(config).await.unwrap();
        assert!(errors.iter().any(|e| e.contains("Data file")));
        assert!(errors.iter().any(|e| e.contains("Sample ID")));
        assert!(errors.iter().any(|e| e.contains("Output directory")));
        assert!(errors.iter().any(|e| e.contains("Outcome column")));
    }

    #[tokio::test]
    async fn test_validate_survival_missing_fields() {
        let config = serde_json::json!({
            "type": "survival",
            "dataFile": "/tmp/test.csv",
            "sampleId": "id",
            "outputDir": "/tmp/out",
            "event": "",
            "horizon": 0.0
        });
        let errors = config_validate(config).await.unwrap();
        assert!(errors.iter().any(|e| e.contains("Event column")));
        assert!(errors.iter().any(|e| e.contains("Horizon")));
    }

    #[tokio::test]
    async fn test_validate_split_prop_range() {
        let config = make_config(serde_json::json!({"splitProp": 0.3}));
        let errors = config_validate(config).await.unwrap();
        assert!(errors.iter().any(|e| e.contains("Split proportion")));
    }

    #[tokio::test]
    async fn test_validate_num_seed_range() {
        let config = make_config(serde_json::json!({"numSeed": 0}));
        let errors = config_validate(config).await.unwrap();
        assert!(errors.iter().any(|e| e.contains("Number of seeds")));
    }
}
