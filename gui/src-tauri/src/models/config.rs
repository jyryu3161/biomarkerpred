use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DataFileInfo {
    pub path: String,
    pub row_count: usize,
    pub columns: Vec<String>,
    pub preview: std::collections::HashMap<String, Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TcgaPreset {
    pub id: String,
    pub label: String,
    pub config_path: String,
    pub has_evidence: bool,
}
