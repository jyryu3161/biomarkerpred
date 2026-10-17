pub mod analysis;
pub mod config;
pub mod fs_ops;
pub mod model;
pub mod opentargets;
pub mod ora;
pub mod runtime;
pub mod setup;

// Every Docker operation must use the engine matching this application version.
pub(crate) const DOCKER_IMAGE: &str = concat!("jyryu3161/biomarkerpred:v", env!("CARGO_PKG_VERSION"));
pub(crate) const DOCKER_IMAGE_TAG_URL: &str = concat!(
    "https://hub.docker.com/v2/repositories/jyryu3161/biomarkerpred/tags/v",
    env!("CARGO_PKG_VERSION")
);

/// Suppress the console window that flashes on Windows when spawning child processes.
/// No-op on non-Windows platforms.
pub(crate) fn hide_console(
    #[allow(unused_mut)] mut cmd: std::process::Command,
) -> std::process::Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    cmd
}

/// Find the Docker CLI binary path.
///
/// macOS GUI apps launched from Finder/Launchpad have a minimal PATH
/// (typically just /usr/bin:/bin:/usr/sbin:/sbin) that does NOT include
/// /usr/local/bin where Docker Desktop installs its symlink. This function
/// checks well-known locations so Docker works regardless of how the app
/// was launched.
pub(crate) fn find_docker() -> String {
    // 1. Try PATH first (works when launched from terminal or if PATH is set)
    if let Some(path) = runtime::find_executable("docker") {
        return path;
    }

    // 2. Check well-known Docker Desktop locations
    let candidates = if cfg!(target_os = "macos") {
        vec![
            "/usr/local/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
            "/opt/homebrew/bin/docker",
        ]
    } else if cfg!(target_os = "linux") {
        vec![
            "/usr/local/bin/docker",
            "/usr/bin/docker",
        ]
    } else {
        // Windows: rely on find_executable (which uses `where`)
        vec![]
    };

    for candidate in candidates {
        if std::path::Path::new(candidate).exists() {
            return candidate.to_string();
        }
    }

    // 3. Fallback: return bare "docker" and let the OS try
    "docker".to_string()
}
