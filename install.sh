#!/usr/bin/env bash
# Install only the reviewed lockfile. Install Pixi 0.71.2 separately first.
set -euo pipefail
bmp_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  printf '%s\n' 'The locked runtime supports Linux x86_64. See README.md for Docker or a manually provisioned local R runtime.' >&2
  exit 1
fi
bmp_pixi="${BMP_PIXI:-pixi}"
if ! command -v "$bmp_pixi" >/dev/null 2>&1; then
  printf '%s\n' 'Install Pixi 0.71.2 from https://github.com/prefix-dev/pixi/releases/tag/v0.71.2, then rerun. BMP_PIXI may name its executable.' >&2
  exit 127
fi
if [[ "$("$bmp_pixi" --version)" != 'pixi 0.71.2' ]]; then
  printf '%s\n' 'This installation is verified with Pixi 0.71.2; select it with BMP_PIXI.' >&2
  exit 1
fi
"$bmp_pixi" install --locked --manifest-path "$bmp_root/pixi.toml"
"$bmp_root/.pixi/envs/default/bin/Rscript" "$bmp_root/BiomarkerCLI.R" doctor --json
printf '%s\n' 'Locked runtime installed and core/graphics doctor passed.' >&2
