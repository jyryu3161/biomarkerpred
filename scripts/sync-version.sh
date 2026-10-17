#!/usr/bin/env bash
# Sync application metadata without changing dependency or model-format versions.
# Usage: ./scripts/sync-version.sh v0.4.3
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_VERSION="${1:-${VERSION:-}}"
if [[ -z "$RELEASE_VERSION" ]]; then
  RELEASE_VERSION=$(git -C "$REPO_ROOT" describe --tags --abbrev=0)
fi
RELEASE_VERSION="${RELEASE_VERSION#v}"
SYNC_ROOT="$REPO_ROOT" SYNC_VERSION="$RELEASE_VERSION" node <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const version = process.env.SYNC_VERSION;
if (!/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
  throw new Error(`Invalid release version: ${version}`);
}
const changes = new Map();
function update(file, transform) {
  const filename = path.join(process.env.SYNC_ROOT, file);
  changes.set(filename, transform(fs.readFileSync(filename, 'utf8')));
}
function replaceOnce(text, pattern, replacement) {
  if (!pattern.test(text)) throw new Error(`Missing version field: ${pattern}`);
  return text.replace(pattern, replacement);
}
for (const file of ['pixi.toml', 'gui/src-tauri/Cargo.toml']) {
  update(file, text => replaceOnce(text, /^version = "[^"]+"/m, `version = "${version}"`));
}
for (const file of ['gui/package.json', 'gui/package-lock.json']) {
  update(file, text => {
    const data = JSON.parse(text);
    data.version = version;
    if (data.packages?.['']) data.packages[''].version = version;
    return JSON.stringify(data, null, 2) + '\n';
  });
}
update('gui/src-tauri/Cargo.lock', text => replaceOnce(text,
  /(\[\[package\]\]\r?\nname = "biomarkerpred"\r?\nversion = ")[^"]+(")/,
  `$1${version}$2`));
update('Dockerfile', text => replaceOnce(text, /^LABEL version="[^"]+"/m, `LABEL version="${version}"`));
for (const file of ['README.md', 'run_docker.sh', 'run_docker.bat', 'docker-entrypoint.sh', 'gui/src/lib/environment.ts']) {
  update(file, text => {
    const pattern = /jyryu3161\/biomarkerpred:v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?/g;
    if (!pattern.test(text)) throw new Error(`Missing pinned image reference in ${file}`);
    return text.replace(pattern, `jyryu3161/biomarkerpred:v${version}`);
  });
}
// Validate all inputs first, then write only metadata and image references.
for (const [filename, text] of changes) fs.writeFileSync(filename, text);
console.log(`Application and Docker image versions set to ${version}`);
JS
node "$REPO_ROOT/scripts/check_release_version.cjs" "$RELEASE_VERSION"
