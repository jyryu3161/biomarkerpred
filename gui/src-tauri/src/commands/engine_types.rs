use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum Backend {
    #[default]
    Local,
    Docker,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeSettings {
    pub backend: Backend,
    pub r_path: Option<String>,
    pub docker_path: Option<String>,
    pub docker_image: String,
    pub output_root: Option<String>,
}
impl Default for RuntimeSettings {
    fn default() -> Self {
        Self {
            backend: Backend::Local,
            r_path: None,
            docker_path: None,
            docker_image: "jyryu3161/biomarkerpred:v0.5.1".into(),
            output_root: None,
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Doctor,
    Validate,
    Analyze,
    Predict,
    Evaluate,
    Runs,
    Compare,
    Resume,
    Report,
    Ora,
}
impl Operation {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Doctor => "doctor",
            Self::Validate => "validate",
            Self::Analyze => "analyze",
            Self::Predict => "predict",
            Self::Evaluate => "evaluate",
            Self::Runs => "runs",
            Self::Compare => "compare",
            Self::Resume => "resume",
            Self::Report => "report",
            Self::Ora => "ora",
        }
    }
    pub fn mutates(&self) -> bool {
        matches!(
            self,
            Self::Analyze
                | Self::Predict
                | Self::Evaluate
                | Self::Resume
                | Self::Report
                | Self::Ora
        )
    }
    pub fn options(&self) -> &'static [&'static str] {
        match self {
            Self::Doctor => &[],
            Self::Validate | Self::Analyze => &["config"],
            Self::Predict => &["model", "data", "output", "time-unit"],
            Self::Evaluate => &[
                "model",
                "data",
                "output",
                "time-unit",
                "bootstrap-samples",
                "seed",
            ],
            Self::Runs => &["output"],
            Self::Compare => &["run"],
            Self::Resume | Self::Report => &["run", "recover-lock"],
            Self::Ora => &[
                "run",
                "gmt",
                "term-map",
                "mapping",
                "annotation",
                "annotation-version",
                "network",
                "add-nodes",
                "string-score",
                "species",
                "permutations",
                "seed",
                "min-size",
                "max-size",
                "evidence",
                "output",
                "recover-lock",
            ],
        }
    }
}
/// Typed operation plus checked scalar options mirrors the CLI without duplicating
/// the scientific schema. `run` is an array only for compare (comma-safe paths).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EngineRequest {
    pub operation: Operation,
    #[serde(default)]
    pub options: BTreeMap<String, Value>,
    pub config: Option<Value>,
    pub settings: Option<RuntimeSettings>,
}
impl EngineRequest {
    pub fn validate(&self) -> Result<(), String> {
        for (key, value) in &self.options {
            if !self.operation.options().contains(&key.as_str()) {
                return Err(format!(
                    "Unsupported option --{key} for {}",
                    self.operation.name()
                ));
            }
            if key == "run" && self.operation == Operation::Compare {
                if !value.as_array().is_some_and(|a| {
                    a.len() >= 2 && a.iter().all(|v| v.as_str().is_some_and(|s| !s.is_empty()))
                }) {
                    return Err("Compare requires an array of at least two run paths".into());
                }
            } else if !(value.is_string() || value.is_number()) {
                return Err(format!("Option --{key} must be a string or number"));
            }
        }
        if self.config.is_some()
            && (!matches!(self.operation, Operation::Analyze | Operation::Validate)
                || self.options.contains_key("config"))
        {
            return Err("Inline config is only supported for analyze/validate, without a config file option".into());
        }
        if self.config.as_ref().is_some_and(|c| !c.is_object()) {
            return Err("Configuration must be a JSON object".into());
        }
        Ok(())
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineResponse {
    pub success: bool,
    pub cancelled: bool,
    pub exit_code: Option<i32>,
    pub result: Value,
    pub verification_error: Option<String>,
    pub stderr_tail: Vec<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineEvent {
    pub job_id: String,
    pub operation: String,
    pub r#type: String,
    pub payload: Value,
}
pub fn scalar(value: &Value) -> String {
    value
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| value.to_string())
}
