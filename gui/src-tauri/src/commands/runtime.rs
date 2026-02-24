use super::hide_console;
use crate::models::config::RuntimeInfo;
use std::process::Command;

#[tauri::command]
pub async fn runtime_detect() -> Result<RuntimeInfo, String> {
    let r_path = find_executable("Rscript");
    let pixi_path = find_executable("pixi");

    let r_version = if let Some(ref rpath) = r_path {
        hide_console(Command::new(rpath))
            .args(["--version"])
            .output()
            .ok()
            .and_then(|out| {
                let stderr = String::from_utf8_lossy(&out.stderr);
                let stdout = String::from_utf8_lossy(&out.stdout);
                let combined = format!("{}{}", stdout, stderr);
                combined
                    .lines()
                    .find(|l| l.contains("version"))
                    .map(|l| l.trim().to_string())
            })
    } else {
        None
    };

    Ok(RuntimeInfo {
        r_path,
        pixi_path,
        r_version,
    })
}

#[tauri::command]
pub async fn runtime_check_deps() -> Result<Vec<serde_json::Value>, String> {
    let required_packages = vec![
        "survival", "glmnet", "pROC", "survminer", "timeROC",
        "caret", "yaml", "ggplot2", "dplyr",
    ];

    let mut results = Vec::new();
    for pkg in required_packages {
        let check_cmd = format!(
            "cat(requireNamespace('{}', quietly=TRUE))",
            pkg
        );
        let output = hide_console(Command::new("Rscript"))
            .args(["-e", &check_cmd])
            .output();

        let installed = output
            .map(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .trim()
                    .eq_ignore_ascii_case("true")
            })
            .unwrap_or(false);

        results.push(serde_json::json!({
            "package": pkg,
            "installed": installed,
        }));
    }

    Ok(results)
}

pub(crate) fn find_executable(name: &str) -> Option<String> {
    let cmd = if cfg!(windows) { "where" } else { "which" };
    hide_console(Command::new(cmd))
        .arg(name)
        .output()
        .ok()
        .and_then(|out| {
            if out.status.success() {
                // `where` on Windows may return multiple lines; take the first
                let output = String::from_utf8_lossy(&out.stdout);
                output.lines().next().map(|l| l.trim().to_string())
            } else {
                None
            }
        })
}
