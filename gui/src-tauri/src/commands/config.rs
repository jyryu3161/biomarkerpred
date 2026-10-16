use crate::models::config::TcgaPreset;
use crate::models::error::AppError;
use std::fs;

#[tauri::command]
pub async fn config_load_yaml(path: String) -> Result<serde_json::Value, String> {
    let content = fs::read_to_string(&path)
        .map_err(|e| String::from(AppError::file_not_found(&format!("{}: {}", path, e))))?;
    let yaml_value: serde_yaml::Value = serde_yaml::from_str(&content)
        .map_err(|e| String::from(AppError::config_parse_error(&format!("YAML: {}", e))))?;
    let json_value = serde_json::to_value(yaml_value).map_err(|e| {
        String::from(AppError::config_parse_error(&format!(
            "JSON conversion: {}",
            e
        )))
    })?;
    Ok(json_value)
}

#[tauri::command]
pub async fn config_save_yaml(config: serde_json::Value, path: String) -> Result<String, String> {
    let yaml_string = serde_yaml::to_string(&config).map_err(|e| {
        String::from(AppError::config_parse_error(&format!(
            "YAML serialize: {}",
            e
        )))
    })?;
    fs::write(&path, &yaml_string)
        .map_err(|e| String::from(AppError::file_not_found(&format!("{}: {}", path, e))))?;
    Ok(path)
}

#[tauri::command]
pub async fn config_list_presets(app: tauri::AppHandle) -> Result<Vec<TcgaPreset>, String> {
    // Look for config/*.yaml files in the app resource directory or project root
    let resource_dir = super::runtime::app_engine(&app)?;

    let config_dir = resource_dir.join("config");
    if !config_dir.exists() {
        return Ok(Vec::new());
    }

    let mut presets = Vec::new();
    let entries =
        fs::read_dir(&config_dir).map_err(|e| format!("Cannot read config dir: {}", e))?;

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
pub async fn config_load_preset(
    preset_id: String,
    app: tauri::AppHandle,
) -> Result<serde_json::Value, String> {
    let resource_dir = super::runtime::app_engine(&app)?;

    let config_path = resource_dir
        .join("config")
        .join(format!("{}_analysis.yaml", preset_id));

    if !config_path.exists() {
        return Err(String::from(AppError::file_not_found(&format!(
            "Preset not found: {}",
            preset_id
        ))));
    }

    config_load_yaml(config_path.to_string_lossy().to_string()).await
}
