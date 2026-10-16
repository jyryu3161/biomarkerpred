#!/usr/bin/env bash
# Synchronize application release metadata; scientific/model format versions stay fixed.
set -euo pipefail
bmp_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if (( $# != 1 )); then
  printf '%s\n' 'Usage: scripts/sync-version.sh v0.5.0 (Node 22.18.x required)' >&2
  exit 2
fi
node "$bmp_root/scripts/sync_release_version.cjs" "$1"
