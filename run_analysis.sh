#!/usr/bin/env bash
set -euo pipefail
bmp_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# BMP_RSCRIPT is one executable path, never a shell command or option string.
if [[ -n "${BMP_RSCRIPT:-}" ]]; then
  exec "$BMP_RSCRIPT" "$bmp_script_dir/BiomarkerCLI.R" "$@"
elif command -v Rscript >/dev/null 2>&1; then
  exec Rscript "$bmp_script_dir/BiomarkerCLI.R" "$@"
elif [[ -x "$bmp_script_dir/.pixi/envs/default/bin/Rscript" ]]; then
  exec "$bmp_script_dir/.pixi/envs/default/bin/Rscript" "$bmp_script_dir/BiomarkerCLI.R" "$@"
elif command -v pixi >/dev/null 2>&1; then
  pixi install --locked --manifest-path "$bmp_script_dir/pixi.toml" >&2
  exec "$bmp_script_dir/.pixi/envs/default/bin/Rscript" "$bmp_script_dir/BiomarkerCLI.R" "$@"
else
  printf '%s\n' 'Rscript is unavailable. Install the project runtime or set BMP_RSCRIPT to an Rscript executable.' >&2
  exit 127
fi
