use std::process::Command;

/// Find an executable in PATH
pub fn find_in_path(name: &str) -> Option<String> {
    Command::new("which")
        .arg(name)
        .output()
        .ok()
        .and_then(|out| {
            if out.status.success() {
                Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
            } else {
                None
            }
        })
}

/// Get R version string
pub fn get_r_version(rscript_path: &str) -> Option<String> {
    Command::new(rscript_path)
        .arg("--version")
        .output()
        .ok()
        .and_then(|out| {
            let combined = format!(
                "{}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            combined
                .lines()
                .find(|l| l.contains("version"))
                .map(|l| l.trim().to_string())
        })
}
