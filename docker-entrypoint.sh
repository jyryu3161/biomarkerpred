#!/usr/bin/env bash
set -euo pipefail
bmp_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bmp_engine_root="${BMP_ENGINE_ROOT:-/app}"
if [[ ! -f "$bmp_engine_root/BiomarkerCLI.R" && -f "$bmp_script_dir/BiomarkerCLI.R" && -z "${BMP_ENGINE_ROOT:-}" ]]; then
  bmp_engine_root="$bmp_script_dir"
fi
exec "${BMP_RSCRIPT:-Rscript}" "$bmp_engine_root/BiomarkerCLI.R" "$@"
