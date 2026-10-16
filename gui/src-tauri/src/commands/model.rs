use super::artifacts::{copy_preserving_source, read_json};
use serde_json::{json, Value};
use std::{collections::HashSet, path::Path};
const MIGRATION:&str="Retrain legacy or incomplete models with analyze. Frozen version-1 encoders, thresholds and survival baselines cannot be reconstructed.";
fn text(v: &Value) -> bool {
    v.as_str().is_some_and(|s| !s.is_empty())
}
fn number(v: &Value) -> bool {
    v.as_f64().is_some_and(f64::is_finite)
}
fn strings(v: &Value) -> Result<Vec<&str>, String> {
    v.as_array()
        .ok_or("Expected an array")?
        .iter()
        .map(|x| x.as_str().ok_or("Expected string array".into()))
        .collect()
}
pub fn validate_model(m: &Value) -> Result<(), String> {
    validate_inner(m).map_err(|e| format!("Invalid .bmpmodel: {e}. {MIGRATION}"))
}
fn validate_inner(m: &Value) -> Result<(), String> {
    if m["format"] != "BioMarkerPred" || m["model_version"] != 1 {
        return Err("unsupported format/version".into());
    }
    let kind = m["analysis_type"].as_str().ok_or("analysis_type missing")?;
    if !["binary", "survival"].contains(&kind)
        || !text(&m["sample_id"])
        || (!m["group_column"].is_null() && !text(&m["group_column"]))
    {
        return Err("invalid analysis/identifier roles".into());
    }
    if m["recipe"]["recipe_version"] != 1 {
        return Err("missing recipe version".into());
    }
    let features = strings(&m["features"])?;
    let columns = strings(&m["design_columns"])?;
    strings(&m["selected_genes"])?;
    strings(&m["clinical_columns"])?;
    let coefficients = m["coefficients"]
        .as_object()
        .ok_or("coefficients must be an object, including a null model")?;
    if features.iter().collect::<HashSet<_>>().len() != features.len()
        || columns.iter().collect::<HashSet<_>>().len() != columns.len()
        || coefficients.len() != columns.len()
        || columns.iter().any(|c| !number(&m["coefficients"][*c]))
        || !number(&m["intercept"])
    {
        return Err("design/coefficients mismatch".into());
    }
    let mut encoded = HashSet::new();
    for feature in features {
        let spec = &m["recipe"]["predictors"][feature];
        let cols = strings(&spec["columns"])?;
        if cols.iter().collect::<HashSet<_>>().len() != cols.len() {
            return Err("duplicate encoder columns".into());
        }
        match spec["type"].as_str() {
            Some("numeric") => {
                if cols.len() != 1
                    || ["median", "center", "scale"]
                        .iter()
                        .any(|k| !number(&spec[*k]))
                    || spec["scale"].as_f64().unwrap_or(0.) <= 0.
                {
                    return Err("numeric encoder missing/invalid".into());
                }
            }
            Some("categorical") => {
                let levels = strings(&spec["levels"])?;
                if levels.is_empty()
                    || levels.iter().collect::<HashSet<_>>().len() != levels.len()
                    || cols.len() + 1 != levels.len()
                    || !levels.contains(&spec["mode"].as_str().unwrap_or(""))
                {
                    return Err("categorical encoder missing/invalid".into());
                }
            }
            _ => return Err("missing predictor encoder".into()),
        }
        encoded.extend(cols);
    }
    if encoded != columns.iter().copied().collect() {
        return Err("recipe design mismatch".into());
    }
    if !number(&m["threshold"]) {
        return Err("frozen threshold missing".into());
    }
    if kind == "binary" {
        if !(0. ..=1.).contains(&m["threshold"].as_f64().unwrap())
            || [
                "positive_class",
                "negative_class",
                "positive_label",
                "negative_label",
            ]
            .iter()
            .any(|k| !text(&m["outcome"][*k]))
            || m["outcome"]["positive_class"] == m["outcome"]["negative_class"]
        {
            return Err("binary coding/labels/threshold invalid".into());
        }
    } else {
        let nums = |v: &Value| -> Result<Vec<f64>, String> {
            v.as_array()
                .ok_or("Missing survival array")?
                .iter()
                .map(|x| {
                    x.as_f64()
                        .filter(|n| n.is_finite())
                        .ok_or("Nonfinite survival value".into())
                })
                .collect()
        };
        let times = nums(&m["baseline"]["time"])?;
        let hazards = nums(&m["baseline"]["cumulative_hazard"])?;
        if times.is_empty()
            || times.len() != hazards.len()
            || times.iter().any(|t| *t <= 0.)
            || times.windows(2).any(|w| w[1] <= w[0])
            || hazards.iter().any(|h| *h < 0.)
            || hazards.windows(2).any(|w| w[1] < w[0])
            || !number(&m["baseline"]["reference_lp"])
        {
            return Err("survival baseline invalid".into());
        }
        if !["days", "months", "years"].contains(&m["time_unit"].as_str().unwrap_or(""))
            || m["horizon"].as_f64().unwrap_or(0.) <= 0.
            || !["event", "time_variable"]
                .iter()
                .all(|k| text(&m["outcome"][*k]))
        {
            return Err("survival roles/units/horizon invalid".into());
        }
        let support = nums(&m["training"]["time_range"])?;
        let censor_times = nums(&m["training"]["censor_curve"]["time"])?;
        let censor = nums(&m["training"]["censor_curve"]["survival"])?;
        if support.len() != 2
            || support[0] <= 0.
            || support[1] < support[0]
            || m["training"]["events"].as_f64().unwrap_or(0.) <= 0.
            || censor_times.is_empty()
            || censor_times.len() != censor.len()
            || censor_times.windows(2).any(|w| w[1] <= w[0])
            || censor.windows(2).any(|w| w[1] > w[0])
            || censor.iter().any(|n| !(0. ..=1.).contains(n))
        {
            return Err("survival support/censor curve invalid".into());
        }
    }
    Ok(())
}
#[tauri::command]
pub async fn model_load(path: String) -> Result<Value, String> {
    let model = read_json(Path::new(&path))?;
    validate_model(&model)?;
    Ok(
        json!({"path":path,"sha256":super::artifacts::sha256(Path::new(&path))?,"model":model,"metrics":null,"metrics_reason":"Performance belongs to a verified development or external evaluation run; a portable model does not imply validation performance."}),
    )
}
#[tauri::command]
pub async fn model_save(source_path: String, dest_path: String) -> Result<String, String> {
    copy_preserving_source(Path::new(&source_path), Path::new(&dest_path))?;
    Ok(dest_path)
}
#[tauri::command]
pub async fn model_check_exists(output_dir: String) -> Result<Option<String>, String> {
    let path = Path::new(&output_dir).join("model.bmpmodel");
    Ok(path.is_file().then(|| path.to_string_lossy().into_owned()))
}
#[tauri::command]
pub async fn prediction_read_results(output_dir: String) -> Result<Value, String> {
    let path = Path::new(&output_dir);
    super::fs_ops::read_csv(
        &if path.is_file() {
            path.to_path_buf()
        } else {
            path.join("predictions.csv")
        },
        None,
    )
}
