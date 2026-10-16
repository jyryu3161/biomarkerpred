use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    path::{Component, Path, PathBuf},
};

pub fn read_json(path: &Path) -> Result<Value, String> {
    serde_json::from_slice(&fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?)
        .map_err(|e| format!("Invalid JSON {}: {e}", path.display()))
}
pub fn atomic_json(path: &Path, value: &Value) -> Result<(), String> {
    let parent = path.parent().ok_or("Missing parent directory")?;
    fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    serde_json::to_writer_pretty(&mut temp, value).map_err(|e| e.to_string())?;
    temp.flush().map_err(|e| e.to_string())?;
    temp.as_file().sync_all().map_err(|e| e.to_string())?;
    temp.persist(path).map_err(|e| e.to_string())?;
    Ok(())
}
pub fn sha256(path: &Path) -> Result<String, String> {
    let mut f = fs::File::open(path).map_err(|e| e.to_string())?;
    let mut hash = Sha256::new();
    let mut bytes = [0; 65536];
    loop {
        let n = f.read(&mut bytes).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hash.update(&bytes[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
pub fn artifact_path(root: &Path, relative: &str) -> Result<PathBuf, String> {
    let path = Path::new(relative);
    if path.is_absolute()
        || path
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err(format!("Invalid artifact path: {relative}"));
    }
    let full = root.join(path);
    let canonical = full
        .canonicalize()
        .map_err(|e| format!("Missing artifact {relative}: {e}"))?;
    if !canonical.starts_with(root.canonicalize().map_err(|e| e.to_string())?) {
        return Err(format!("Artifact escapes run directory: {relative}"));
    }
    if !canonical.is_file() || fs::metadata(&canonical).map_err(|e| e.to_string())?.len() == 0 {
        return Err(format!("Empty artifact: {relative}"));
    }
    Ok(canonical)
}
pub fn verify_run(root: &Path, require_completed: bool) -> Result<Value, String> {
    let manifest = read_json(&root.join("manifest.json"))?;
    if require_completed && manifest["status"] != "completed" {
        return Err(format!("Run has not completed: {}", manifest["status"]));
    }
    for field in [
        "engine_artifact_verification",
        "evaluation_artifact_verification",
        "metrics_artifact_verification",
        "report_artifact_verification",
        "artifact_verification",
    ] {
        if field == "artifact_verification"
            && manifest["status"] != "completed"
            && manifest["operation"] != "ora"
        {
            continue;
        }
        if let Some(hashes) = manifest[field]["sha256"].as_object() {
            for (name, expected) in hashes {
                let path = artifact_path(root, name)?;
                if expected.as_str() != Some(sha256(&path)?.as_str()) {
                    return Err(format!("Artifact checksum mismatch: {name}"));
                }
            }
        }
    }
    if manifest["status"] == "completed" {
        let required = manifest["required_artifacts"]
            .as_array()
            .ok_or("Completed manifest has no required artifact list")?;
        let hashes = manifest["artifact_verification"]["sha256"]
            .as_object()
            .ok_or("Completed manifest has no artifact hashes")?;
        if required.is_empty() || hashes.is_empty() {
            return Err("Completed manifest has empty artifact verification".into());
        }
        for name in required {
            let name = name.as_str().ok_or("Invalid artifact name")?;
            artifact_path(root, name)?;
            if !hashes.contains_key(name) {
                return Err(format!("Missing recorded checksum: {name}"));
            }
        }
        if manifest["operation"] != "ora" {
            super::model::validate_model(&read_json(&root.join("model.bmpmodel"))?)?;
        }
    }
    Ok(manifest)
}
pub fn copy_preserving_source(source: &Path, dest: &Path) -> Result<(), String> {
    let original = source.canonicalize().map_err(|e| e.to_string())?;
    if let Ok(target) = dest.canonicalize() {
        if original == target {
            return Ok(());
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let a = fs::metadata(&original).map_err(|e| e.to_string())?;
            let b = fs::metadata(&target).map_err(|e| e.to_string())?;
            if a.dev() == b.dev() && a.ino() == b.ino() {
                return Ok(());
            }
        }
    }
    let parent = dest
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let mut temp = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    let mut input = fs::File::open(original).map_err(|e| e.to_string())?;
    std::io::copy(&mut input, &mut temp).map_err(|e| e.to_string())?;
    temp.as_file().sync_all().map_err(|e| e.to_string())?;
    temp.persist(dest).map_err(|e| e.to_string())?;
    Ok(())
}
#[tauri::command]
pub async fn engine_read_run(run_dir: String) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let root = Path::new(&run_dir);
        let mut manifest = read_json(&root.join("manifest.json"))?;
        let verification_error = verify_run(root, false).err();
        let mut artifacts = serde_json::Map::new();
        let mut errors = serde_json::Map::new();
        for name in [
            "config.json",
            "qc.json",
            "metrics.json",
            "summary.json",
            "universes.json",
            "annotation.json",
            "gsea.json",
            "graph.json",
            "gene_evidence.json",
            "figures/index.json",
        ] {
            if !root.join(name).exists() {
                continue;
            }
            match artifact_path(root, name).and_then(|path| read_json(&path)) {
                Ok(value) => {
                    artifacts.insert(name.into(), value);
                }
                Err(error) => {
                    errors.insert(name.into(), json!(error));
                }
            }
        }
        for name in [
            "stability.csv",
            "panel_comparison.csv",
            "model_comparison.csv",
            "ora_original.csv",
            "ora_expanded.csv",
            "gsea.csv",
        ] {
            if !root.join(name).exists() {
                continue;
            }
            match artifact_path(root, name).and_then(|path| super::fs_ops::read_csv(&path, None)) {
                Ok(value) => {
                    artifacts.insert(name.into(), value);
                }
                Err(error) => {
                    errors.insert(name.into(), json!(error));
                }
            }
        }
        let mut paths = serde_json::Map::new();
        if let Some(required) = manifest["required_artifacts"].as_array() {
            for name in required.iter().filter_map(Value::as_str) {
                match artifact_path(root, name) {
                    Ok(path) => {
                        paths.insert(name.into(), json!(path));
                    }
                    Err(error) => {
                        errors.insert(name.into(), json!(error));
                    }
                }
            }
        }
        if let Ok(context) = read_json(&root.join(".desktop-runtime.json")) {
            if let Ok(map) =
                serde_json::from_value::<super::engine_plan::PathMap>(context["path_map"].clone())
            {
                map.map_result(&mut manifest);
                for value in artifacts.values_mut() {
                    map.map_result(value);
                }
            }
        }
        Ok(json!({
            "paths": paths,
            "run_dir": root.canonicalize().map_err(|e| e.to_string())?,
            "manifest": manifest,
            "artifacts": artifacts,
            "verification_error": verification_error,
            "artifact_errors": errors
        }))
    })
    .await
    .map_err(|e| e.to_string())?
}
