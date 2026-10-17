#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8').replace(/\r\n/g, '\n');
const pkg = JSON.parse(read('gui/package.json'));
const version = (process.argv[2] || pkg.version).replace(/^v/, '');
assert.match(version, /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/);
const lock = JSON.parse(read('gui/package-lock.json'));
const versions = {
  'gui/package.json': pkg.version,
  'gui/package-lock.json': lock.version,
  'gui/package-lock.json root package': lock.packages[''].version,
  'pixi.toml': read('pixi.toml').match(/^version = "([^"]+)"/m)?.[1],
  'gui/src-tauri/Cargo.toml': read('gui/src-tauri/Cargo.toml').match(/^version = "([^"]+)"/m)?.[1],
  'gui/src-tauri/Cargo.lock': read('gui/src-tauri/Cargo.lock').match(/\[\[package\]\]\r?\nname = "biomarkerpred"\r?\nversion = "([^"]+)"/)?.[1],
  Dockerfile: read('Dockerfile').match(/^LABEL version="([^"]+)"/m)?.[1],
};
for (const [file, actual] of Object.entries(versions)) assert.equal(actual, version, file);
assert.equal(JSON.parse(read('gui/src-tauri/tauri.conf.json')).version, '../package.json');
for (const file of ['README.md', 'run_docker.sh', 'run_docker.bat', 'docker-entrypoint.sh', 'gui/src/lib/environment.ts']) {
  const refs = read(file).replace(/https:\/\/github\.com\/\S+/g, '').match(/jyryu3161\/biomarkerpred(?::[^\s"'`\\)]+)?/g) || [];
  const dockerRefs = refs.filter(ref => !ref.endsWith('.git') && !ref.includes('/releases'));
  assert(dockerRefs.length > 0, `No Docker reference in ${file}`);
  for (const ref of dockerRefs) assert.equal(ref, `jyryu3161/biomarkerpred:v${version}`, file);
}
const commands = 'gui/src-tauri/src/commands';
assert(read(`${commands}/mod.rs`).includes('concat!("jyryu3161/biomarkerpred:v", env!("CARGO_PKG_VERSION"))'));
assert(read(`${commands}/mod.rs`).includes('"https://hub.docker.com/v2/repositories/jyryu3161/biomarkerpred/tags/v",\n    env!("CARGO_PKG_VERSION")'));
for (const file of ['analysis.rs', 'model.rs', 'ora.rs', 'setup.rs']) {
  assert(read(`${commands}/${file}`).includes('DOCKER_IMAGE'), `Unpinned Docker path: ${file}`);
}
console.log(`Release version verified: v${version}`);
