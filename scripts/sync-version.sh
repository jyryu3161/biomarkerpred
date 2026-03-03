#!/usr/bin/env bash
# sync-version.sh — Sync all project version files from the latest git tag.
#
# Usage:
#   ./scripts/sync-version.sh          # auto-detect from git tag
#   ./scripts/sync-version.sh 0.4.0    # explicit version
#   VERSION=0.4.0 ./scripts/sync-version.sh  # via env var
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve version: argument > env var > git tag
if [[ -n "${1:-}" ]]; then
  VERSION="${1#v}"
elif [[ -n "${VERSION:-}" ]]; then
  VERSION="${VERSION#v}"
else
  TAG=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 2>/dev/null || echo "")
  if [[ -z "$TAG" ]]; then
    echo "ERROR: No git tag found and no version argument provided." >&2
    echo "Usage: $0 [version]" >&2
    exit 1
  fi
  VERSION="${TAG#v}"
fi

# Validate semver format (x.y.z with optional pre-release)
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
  echo "ERROR: Invalid version format: $VERSION (expected semver x.y.z)" >&2
  exit 1
fi

echo "Syncing version to: $VERSION"

# 1. pixi.toml
PIXI="$REPO_ROOT/pixi.toml"
if [[ -f "$PIXI" ]]; then
  sed -i.bak "s/^version = \".*\"/version = \"$VERSION\"/" "$PIXI"
  rm -f "$PIXI.bak"
  echo "  Updated pixi.toml"
fi

# 2. gui/package.json
PKG="$REPO_ROOT/gui/package.json"
if [[ -f "$PKG" ]]; then
  node -e "
    const fs = require('fs');
    const pkg = JSON.parse(fs.readFileSync('$PKG', 'utf8'));
    pkg.version = '$VERSION';
    fs.writeFileSync('$PKG', JSON.stringify(pkg, null, 2) + '\n');
  "
  echo "  Updated gui/package.json"
fi

# 3. gui/package-lock.json (top-level version entries only)
LOCK="$REPO_ROOT/gui/package-lock.json"
if [[ -f "$LOCK" ]]; then
  node -e "
    const fs = require('fs');
    const lock = JSON.parse(fs.readFileSync('$LOCK', 'utf8'));
    if (lock.version) lock.version = '$VERSION';
    if (lock.packages && lock.packages['']) lock.packages[''].version = '$VERSION';
    fs.writeFileSync('$LOCK', JSON.stringify(lock, null, 2) + '\n');
  "
  echo "  Updated gui/package-lock.json"
fi

# 4. gui/src-tauri/Cargo.toml (replace first ^version line only = [package] version)
CARGO="$REPO_ROOT/gui/src-tauri/Cargo.toml"
if [[ -f "$CARGO" ]]; then
  awk -v ver="$VERSION" '!done && /^version = "/ { sub(/"[^"]*"/, "\"" ver "\""); done=1 } 1' "$CARGO" > "$CARGO.tmp"
  mv "$CARGO.tmp" "$CARGO"
  echo "  Updated gui/src-tauri/Cargo.toml"
fi

echo "Done. All versions set to $VERSION"
