const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const version = (process.argv[2] || '').replace(/^v/, '');
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) throw new Error('Expected a semantic version, e.g. v0.5.0');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const write = (name, value) => fs.writeFileSync(path.join(root, name), value);
for (const name of ['gui/package.json', 'gui/package-lock.json']) {
  const data = JSON.parse(read(name));
  data.version = version;
  if (data.packages) data.packages[''].version = version;
  write(name, JSON.stringify(data, null, 2) + '\n');
}
for (const name of ['pixi.toml', 'tests/runtime/pixi.toml', 'gui/src-tauri/Cargo.toml']) {
  write(name, read(name).replace(/^version = "[^"]+"/m, `version = "${version}"`));
}
write('gui/src-tauri/Cargo.lock', read('gui/src-tauri/Cargo.lock').replace(/(name = "biomarkerpred"\nversion = ")[^"]+/, `$1${version}`));
write('R/cli.R', read('R/cli.R').replace(/application_version = "[^"]+"/, `application_version = "${version}"`));
write('Dockerfile', read('Dockerfile').replace(/image.version="[^"]+"/, `image.version="${version}"`));
for (const name of ['gui/src-tauri/src/commands/engine_types.rs', 'run_docker.sh', 'run_docker.bat']) {
  write(name, read(name).replace(/jyryu3161\/biomarkerpred:v\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?/g, `jyryu3161/biomarkerpred:v${version}`));
}
require('node:child_process').execFileSync(process.execPath, [path.join(__dirname, 'check_release_version.cjs'), version], {stdio: 'inherit'});
