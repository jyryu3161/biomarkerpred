use std::fs;

/// Read a YAML file and return as serde_json::Value
pub fn read_yaml_file(path: &str) -> Result<serde_json::Value, String> {
    let content = fs::read_to_string(path)
        .map_err(|e| format!("Cannot read file: {}", e))?;
    let yaml: serde_yaml::Value = serde_yaml::from_str(&content)
        .map_err(|e| format!("YAML parse error: {}", e))?;
    serde_json::to_value(yaml)
        .map_err(|e| format!("JSON conversion error: {}", e))
}

/// Write a serde_json::Value as YAML to file
pub fn write_yaml_file(path: &str, value: &serde_json::Value) -> Result<(), String> {
    let yaml_str = serde_yaml::to_string(value)
        .map_err(|e| format!("YAML serialize error: {}", e))?;
    fs::write(path, yaml_str)
        .map_err(|e| format!("Cannot write file: {}", e))
}
