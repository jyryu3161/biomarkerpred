#!/usr/bin/env bash
# Mount one explicit workspace; the image contains the shared R engine.
set -euo pipefail
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'HELP'
Usage: ./run_docker.sh COMMAND [CLI OPTIONS]
Default published image: jyryu3161/biomarkerpred:v0.5.0.
Fetch explicitly first: docker pull jyryu3161/biomarkerpred:v0.5.0
For a local build, set BMP_DOCKER_IMAGE=biomarkerpred-engine:local.
Override BMP_DOCKER_IMAGE or BMP_DOCKER_PATH (one executable path) if needed.
The current host directory is mounted at /work and is the container working directory.
Only files under that directory are mounted. Use /work/... container paths in configs,
or relative paths resolved from their config directory; workdir: /work is explicit.
Absolute host paths and paths outside this directory are not translated or mounted.
Use the desktop Docker backend or explicit docker run mounts for separate locations.
The launcher records the inspected immutable image identity and does not pull images.
Examples:
  ./run_docker.sh doctor --json
  ./run_docker.sh validate --config /work/config/analysis.json --json
  ./run_docker.sh analyze --config /work/config/analysis.json --json
For full engine help: ./run_docker.sh help
HELP
  exit 0
fi
if (( $# == 0 )); then printf '%s\n' 'Provide a CLI command; see --help.' >&2; exit 2; fi
bmp_docker="${BMP_DOCKER_PATH:-docker}"
bmp_image="${BMP_DOCKER_IMAGE:-jyryu3161/biomarkerpred:v0.5.0}"
bmp_digest="$("$bmp_docker" image inspect --format '{{.Id}}' "$bmp_image")"
if [[ ! "$bmp_digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
  printf '%s\n' 'Cannot determine the immutable identity of the locally available engine image.' >&2
  exit 1
fi
# --volume accepts spaces/commas as one argv value. A colon is its delimiter.
bmp_work="$(pwd -P)"
if [[ "$bmp_work" == *:* || "$bmp_work" == *$'\n'* ]]; then
  printf '%s\n' 'Workspace paths containing colons/newlines require explicit Docker --mount arguments.' >&2
  exit 2
fi
exec "$bmp_docker" run --rm --pull never --user "$(id -u):$(id -g)" \
  --volume "$bmp_work:/work" --workdir /work --env "BMP_IMAGE_DIGEST=$bmp_digest" "$bmp_digest" "$@"
