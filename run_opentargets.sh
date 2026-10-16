#!/usr/bin/env bash
# Batch disease-prior analyses through the same QC/manifest-verifying engine.
set -euo pipefail
bmp_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
bmp_expected_type=""
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
Usage: ./run_opentargets.sh [--binary] CONFIG [CONFIG ...]
Each explicit disease-evidence config is validated, then analyzed by the shared CLI.
Paths are relative to the invocation directory; quote paths containing spaces.
Stdout contains one JSON result per CLI invocation; progress/summary use stderr.
Any invalid config, failed analysis or invalid manifest makes the batch exit nonzero.
Use generate_opentargets_configs.py to attach an immutable disease snapshot first.
Set BMP_RSCRIPT to one Rscript executable path if the project runtime is elsewhere.
HELP
  exit 0
fi
if [[ "${1:-}" == "--binary" ]]; then bmp_expected_type="binary"; shift; fi
if (( $# == 0 )); then
  printf '%s\n' 'Provide one or more config paths; see --help. Automatic drug/disease inference is retired.' >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'Python 3 is required to verify batch results.' >&2; exit 127; }
bmp_failed=0
for bmp_config in "$@"; do
  printf 'Validating %s\n' "$bmp_config" >&2
  if bmp_validation="$("$bmp_script_dir/run_analysis.sh" validate --config "$bmp_config" --json)"; then
    printf '%s\n' "$bmp_validation"
    if ! python3 -c '
import json, sys
def require(condition, message):
    if not condition: raise ValueError(message)
value = json.load(sys.stdin)
require(value.get("ok") is True and value.get("qc", {}).get("status") == "passed", "QC did not pass")
config = value["config"]
require(config.get("evidence"), "This runner requires an explicit disease-evidence snapshot")
require(not sys.argv[1] or config["analysis_type"] == sys.argv[1], "Binary runner received a non-binary configuration")
' "$bmp_expected_type" <<< "$bmp_validation"; then
      bmp_failed=$((bmp_failed + 1)); continue
    fi
  else
    printf '%s\n' "$bmp_validation"
    bmp_failed=$((bmp_failed + 1)); continue
  fi
  if bmp_result="$("$bmp_script_dir/run_analysis.sh" analyze --config "$bmp_config" --json)"; then
    printf '%s\n' "$bmp_result"
    if ! python3 -c '
import hashlib, json, pathlib, sys
def require(condition, message):
    if not condition: raise ValueError(message)
value = json.load(sys.stdin)
require(value.get("ok") is True and value.get("status") == "completed", "CLI did not complete")
run = pathlib.Path(value["run_dir"]).resolve()
manifest = json.loads((run / "manifest.json").read_text())
require(manifest["status"] == "completed" and manifest["run_id"] == value["run_id"], "Run identity/status mismatch")
hashes = manifest["artifact_verification"]["sha256"]
for name in manifest["required_artifacts"]:
    path = (run / name).resolve()
    require(path.is_relative_to(run) and path.is_file() and path.stat().st_size > 0, "Missing/invalid artifact: " + name)
    require(hashlib.sha256(path.read_bytes()).hexdigest() == hashes[name], "Changed artifact: " + name)
' <<< "$bmp_result"; then bmp_failed=$((bmp_failed + 1)); fi
  else
    printf '%s\n' "$bmp_result"
    bmp_failed=$((bmp_failed + 1))
  fi
done
printf 'Batch finished: %s configuration(s), %s failure(s).\n' "$#" "$bmp_failed" >&2
(( bmp_failed == 0 ))
