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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeInfo {
    pub r_path: Option<String>,
    pub pixi_path: Option<String>,
    pub r_version: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageUpdateStatus {
    pub has_update: bool,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvStatus {
    pub pixi_installed: bool,
    pub r_available: bool,
    pub packages_ok: bool,
    pub docker_available: bool,
    pub docker_image_present: bool,
    pub pixi_path: Option<String>,
    pub r_path: Option<String>,
    pub r_version: Option<String>,
}
