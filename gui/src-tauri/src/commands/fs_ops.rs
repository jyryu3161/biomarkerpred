use crate::models::config::DataFileInfo;
use crate::models::error::AppError;
use std::collections::HashMap;
use std::fs;

use tauri_plugin_dialog::DialogExt;

#[tauri::command]
pub async fn fs_pick_file(app: tauri::AppHandle) -> Result<Option<String>, String> {
    let file = app
        .dialog()
        .file()
        .add_filter(
            "Supported files",
            &["csv", "bmpmodel", "yaml", "yml", "json", "gmt", "tsv"],
        )
        .add_filter("All files", &["*"])
        .blocking_pick_file();

    Ok(file
        .and_then(|f| f.into_path().ok())
        .map(|p| p.to_string_lossy().to_string()))
}

#[tauri::command]
pub async fn fs_pick_directory(app: tauri::AppHandle) -> Result<Option<String>, String> {
    let dir = app.dialog().file().blocking_pick_folder();
    Ok(dir
        .and_then(|d| d.into_path().ok())
        .map(|p| p.to_string_lossy().to_string()))
}

#[tauri::command]
pub async fn fs_read_csv_header(path: String) -> Result<DataFileInfo, String> {
    tauri::async_runtime::spawn_blocking(move || csv_header(&path))
        .await
        .map_err(|e| e.to_string())?
}
fn csv_header(path: &str) -> Result<DataFileInfo, String> {
    let table = read_csv(std::path::Path::new(&path), Some(5))?;
    let columns: Vec<String> = table["headers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect();
    let mut preview: HashMap<String, Vec<String>> = HashMap::new();
    for column in &columns {
        preview.insert(
            column.clone(),
            table["rows"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r[column].as_str().unwrap_or("").to_owned())
                .collect(),
        );
    }
    Ok(DataFileInfo {
        path: path.to_owned(),
        row_count: table["count"].as_u64().unwrap() as usize,
        columns,
        preview,
    })
}

pub fn read_csv(path: &std::path::Path, limit: Option<usize>) -> Result<serde_json::Value, String> {
    let mut reader = csv::ReaderBuilder::new()
        .from_path(path)
        .map_err(|e| e.to_string())?;
    let headers: Vec<String> = reader
        .headers()
        .map_err(|e| e.to_string())?
        .iter()
        .map(str::to_owned)
        .collect();
    if headers.is_empty()
        || headers.iter().any(|h| h.is_empty())
        || headers
            .iter()
            .collect::<std::collections::HashSet<_>>()
            .len()
            != headers.len()
    {
        return Err("CSV headers must be nonempty and unique".into());
    }
    let mut rows = Vec::new();
    let mut count = 0usize;
    for record in reader.records() {
        let record = record.map_err(|e| e.to_string())?;
        count += 1;
        if limit.is_none_or(|n| rows.len() < n) {
            let row: serde_json::Map<String, serde_json::Value> = headers
                .iter()
                .zip(record.iter())
                .map(|(h, v)| (h.clone(), serde_json::json!(v)))
                .collect();
            rows.push(serde_json::Value::Object(row));
        }
    }
    Ok(serde_json::json!({"headers":headers,"rows":rows,"count":count}))
}
#[tauri::command]
pub async fn fs_read_csv(path: String, limit: Option<usize>) -> Result<serde_json::Value, String> {
    tauri::async_runtime::spawn_blocking(move || read_csv(std::path::Path::new(&path), limit))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
pub async fn fs_read_image(path: String) -> Result<String, String> {
    let bytes = fs::read(&path)
        .map_err(|e| String::from(AppError::file_not_found(&format!("{}: {}", path, e))))?;
    use base64::Engine;
    Ok(base64::engine::general_purpose::STANDARD.encode(&bytes))
}

/// Save a file to user-chosen location via save dialog
#[tauri::command]
pub async fn fs_save_file(
    app: tauri::AppHandle,
    source_path: String,
    default_name: String,
) -> Result<Option<String>, String> {
    let ext = std::path::Path::new(&default_name)
        .extension()
        .map(|e| e.to_string_lossy().to_string())
        .unwrap_or_default();

    let filter_name = match ext.as_str() {
        "svg" => "SVG Image",
        "tiff" => "TIFF Image",
        "png" => "PNG Image",
        "pdf" => "PDF Document",
        "csv" => "CSV File",
        "bmpmodel" => "BioMarkerPred Model",
        "yaml" | "yml" => "YAML Config",
        _ => "All Files",
    };

    let dest = app
        .dialog()
        .file()
        .set_file_name(&default_name)
        .add_filter(filter_name, &[&ext])
        .blocking_save_file();

    match dest.and_then(|fp| fp.into_path().ok()) {
        Some(dest_path) => {
            let dest_str = dest_path.to_string_lossy().to_string();
            super::artifacts::copy_preserving_source(
                std::path::Path::new(&source_path),
                &dest_path,
            )
            .map_err(|e| format!("Failed to save file: {}", e))?;
            Ok(Some(dest_str))
        }
        None => Ok(None), // User cancelled
    }
}

/// Open a directory in the system file manager (Finder on macOS)
#[tauri::command]
pub async fn fs_open_directory(path: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("Failed to open directory: {}", e))?;
    }
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("Failed to open directory: {}", e))?;
    }
    #[cfg(target_os = "linux")]
    {
        std::process::Command::new("xdg-open")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("Failed to open directory: {}", e))?;
    }
    Ok(())
}

/// Sort key for plot files: (type_order, name_order, extension_order, filename)
/// type_order:  0=Binary, 1=Survival, 2=Other
/// name_order:  predefined plot sequence within each type
/// extension_order: 0=svg, 1=png, 2=tiff, 3=pdf (SVG preferred for display)
fn plot_sort_key(path: &str) -> (u8, u8, u8, String) {
    let normalized = path.replace('\\', "/");
    let basename = normalized
        .split('/')
        .last()
        .unwrap_or(&normalized)
        .to_lowercase();
    let stem = basename
        .trim_end_matches(".svg")
        .trim_end_matches(".png")
        .trim_end_matches(".tiff")
        .trim_end_matches(".tif")
        .trim_end_matches(".pdf");

    let type_order: u8 = if stem.starts_with("binary") {
        0
    } else if stem.starts_with("survival") || stem.starts_with("surv") {
        1
    } else {
        2
    };

    let name_order: u8 = if stem.contains("roc") {
        0
    } else if stem.contains("kaplan") || stem.contains("_km") {
        1
    } else if stem.contains("importance") || stem.contains("varimp") || stem.contains("var_imp") {
        2
    } else if stem.contains("time") && stem.contains("auc") {
        3
    } else if stem.contains("auc") {
        4
    } else if stem.contains("dca") {
        5
    } else if stem.contains("prob") {
        6
    } else if stem.contains("confusion") {
        7
    } else if stem.contains("stepwise") || stem.contains("process") {
        8
    } else {
        9
    };

    let ext_order: u8 = if basename.ends_with(".svg") {
        0
    } else if basename.ends_with(".png") {
        1
    } else if basename.ends_with(".tiff") || basename.ends_with(".tif") {
        2
    } else {
        3
    };

    (type_order, name_order, ext_order, basename)
}

#[tauri::command]
pub async fn fs_read_text_file(path: String) -> Result<String, String> {
    fs::read_to_string(&path)
        .map_err(|e| String::from(AppError::file_not_found(&format!("{}: {}", path, e))))
}

#[tauri::command]
pub async fn fs_list_output_plots(output_dir: String) -> Result<Vec<String>, String> {
    let base = std::path::Path::new(&output_dir);
    if !base.exists() {
        return Ok(Vec::new());
    }

    let image_extensions = ["png", "tiff", "svg", "pdf"];
    let mut plots = Vec::new();

    // Search in output_dir root and common subdirectories (figures/, plots/)
    let search_dirs: Vec<std::path::PathBuf> =
        vec![base.to_path_buf(), base.join("figures"), base.join("plots")];

    for dir in &search_dirs {
        if !dir.exists() {
            continue;
        }
        let entries = match fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if let Some(ext) = path.extension() {
                let ext_str = ext.to_string_lossy().to_lowercase();
                if image_extensions.contains(&ext_str.as_str()) {
                    // Return path relative to output_dir
                    if let Ok(rel) = path.strip_prefix(base) {
                        plots.push(rel.to_string_lossy().to_string());
                    }
                }
            }
        }
    }

    // Normalize path separators to forward slash (Windows uses backslash)
    let plots: Vec<String> = plots.into_iter().map(|p| p.replace('\\', "/")).collect();

    // Sort: Binary first, then Survival, then others.
    // Within each group, use predefined plot order.
    let mut plots = plots;
    plots.sort_by_key(|p| plot_sort_key(p));

    Ok(plots)
}
