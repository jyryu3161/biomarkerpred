#!/usr/bin/env bash
# Source-checkout desktop development launcher; installed desktop apps do not need npm.
set -euo pipefail
bmp_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
Usage: ./run_gui.sh [TAURI DEV OPTIONS]
Requires Node.js 22.18.x, npm, Rust/Cargo >= 1.90 and Tauri system dependencies.
Runs npm ci from this checkout's gui directory, then npm run tauri -- dev.
Linux needs WebKitGTK/GTK development libraries; see the platform runtime instructions.
Select an installed local R runtime or locally built Docker engine in desktop Settings.
HELP
  exit 0
fi
command -v node >/dev/null 2>&1 || { printf '%s\n' 'Install Node.js 22.18.x and npm first.' >&2; exit 127; }
node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major !== 22 || minor !== 18) { console.error("This checkout requires Node.js 22.18.x; found " + process.versions.node); process.exit(1); }'
command -v npm >/dev/null 2>&1 || { printf '%s\n' 'npm is unavailable.' >&2; exit 127; }
if ! command -v cargo >/dev/null 2>&1 && [[ -f "$HOME/.cargo/env" ]]; then source "$HOME/.cargo/env"; fi
command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1 || { printf '%s\n' 'Install Rust/Cargo >= 1.90 and Tauri system dependencies first.' >&2; exit 127; }
bmp_rust_version="$(rustc --version)"
node -e 'const match = process.argv[1].match(/^rustc (\d+)\.(\d+)/); if (!match || Number(match[1]) < 1 || (Number(match[1]) === 1 && Number(match[2]) < 90)) { console.error("Rust >= 1.90 is required; found " + process.argv[1]); process.exit(1); }' "$bmp_rust_version"
cd -- "$bmp_script_dir/gui"
npm ci
exec npm run tauri -- dev "$@"
