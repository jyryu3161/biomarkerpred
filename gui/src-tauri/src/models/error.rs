use serde::Serialize;
use std::fmt;

#[derive(Debug, Serialize)]
pub struct AppError {
    pub code: String,
    pub message: String,
    pub details: Option<String>,
}

impl fmt::Display for AppError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl AppError {
    pub fn runtime_not_found(details: &str) -> Self {
        Self {
            code: "E001".to_string(),
            message: "R runtime not found. Please configure the R path in Settings.".to_string(),
            details: Some(details.to_string()),
        }
    }

    pub fn file_not_found(path: &str) -> Self {
        Self {
            code: "E003".to_string(),
            message: format!("File not found: {}", path),
            details: None,
        }
    }

    pub fn csv_parse_error(details: &str) -> Self {
        Self {
            code: "E004".to_string(),
            message: "Failed to parse CSV file.".to_string(),
            details: Some(details.to_string()),
        }
    }

    pub fn analysis_failed(details: &str) -> Self {
        Self {
            code: "E006".to_string(),
            message: "Analysis execution failed.".to_string(),
            details: Some(details.to_string()),
        }
    }

    pub fn config_parse_error(details: &str) -> Self {
        Self {
            code: "E005".to_string(),
            message: "Failed to parse configuration file.".to_string(),
            details: Some(details.to_string()),
        }
    }

    pub fn setup_failed(details: &str) -> Self {
        Self {
            code: "E007".to_string(),
            message: "Environment setup failed.".to_string(),
            details: Some(details.to_string()),
        }
    }

    pub fn docker_not_found(details: &str) -> Self {
        Self {
            code: "E008".to_string(),
            message: "Docker is not available.".to_string(),
            details: Some(details.to_string()),
        }
    }
}

// Allow AppError to be returned from Tauri commands
impl From<AppError> for String {
    fn from(e: AppError) -> String {
        serde_json::to_string(&e).unwrap_or_else(|_| e.message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_app_error_display() {
        let err = AppError::runtime_not_found("test detail");
        assert_eq!(format!("{}", err), "[E001] R runtime not found. Please configure the R path in Settings.");
    }

    #[test]
    fn test_app_error_to_string_json() {
        let err = AppError::file_not_found("/some/path");
        let json_str: String = err.into();
        let parsed: serde_json::Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(parsed["code"], "E003");
        assert!(parsed["message"].as_str().unwrap().contains("/some/path"));
    }

    #[test]
    fn test_csv_parse_error() {
        let err = AppError::csv_parse_error("bad row");
        assert_eq!(err.code, "E004");
        assert_eq!(err.details, Some("bad row".to_string()));
    }

    #[test]
    fn test_analysis_failed() {
        let err = AppError::analysis_failed("exit code 1");
        assert_eq!(err.code, "E006");
    }

    #[test]
    fn test_config_parse_error() {
        let err = AppError::config_parse_error("invalid YAML at line 3");
        assert_eq!(err.code, "E005");
        assert_eq!(err.details, Some("invalid YAML at line 3".to_string()));
    }
}
