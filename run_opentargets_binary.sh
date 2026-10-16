#!/usr/bin/env bash
# Compatibility alias: same engine, explicitly require binary configurations.
set -euo pipefail
bmp_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  exec "$bmp_script_dir/run_opentargets.sh" --help
fi
exec "$bmp_script_dir/run_opentargets.sh" --binary "$@"
