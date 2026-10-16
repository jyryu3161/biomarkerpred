// A candidate is built from already synchronized, committed manifests/locks.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const requested = (process.argv[2] || process.env.BMP_RELEASE_VERSION || '').replace(/^v/, '');
if (!/^\d+\.\d+\.\d+([+-][0-9A-Za-z.-]+)?$/.test(requested)) {
  throw new Error('Supply a semantic release version such as v0.5.0.');
}
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const json = file => JSON.parse(read(file));
const tomlVersion = text => text.match(/^version\s*=\s*"([^"]+)"\s*$/m)?.[1];
const cargo = read('gui/src-tauri/Cargo.toml').split(/^\[package\]\s*$/m)[1]?.split(/^\[/m)[0];
const name = cargo?.match(/^name\s*=\s*"([^"]+)"\s*$/m)?.[1];
const cargoLock = read('gui/src-tauri/Cargo.lock').split(/^\[\[package\]\]\s*$/m)
  .find(block => block.match(/^name\s*=\s*"([^"]+)"\s*$/m)?.[1] === name);
const lock = json('gui/package-lock.json');
const versions = {
  'gui/package.json': json('gui/package.json').version,
  'gui/package-lock.json': lock.version,
  'gui/package-lock.json root package': lock.packages?.['']?.version,
  'gui/src-tauri/Cargo.toml': tomlVersion(cargo || ''),
  'gui/src-tauri/Cargo.lock': tomlVersion(cargoLock || ''),
  'R/cli.R application_version': read('R/cli.R').match(/application_version = "([^"]+)"/)?.[1],
  'Dockerfile image version': read('Dockerfile').match(/image.version="([^"]+)"/)?.[1],
  'pixi.toml': tomlVersion(read('pixi.toml').split(/^\[workspace\]\s*$/m)[1]?.split(/^\[/m)[0] || ''),
};
for (const name of ['gui/src-tauri/src/commands/engine_types.rs', 'run_docker.sh', 'run_docker.bat']) {
  const images = [...read(name).matchAll(/jyryu3161\/biomarkerpred:v(\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?)/g)];
  if (!images.length || images.some(match => match[1] !== requested)) throw new Error(`${name}: default published image version differs`);
}
for (const [file, actual] of Object.entries(versions)) {
  if (actual !== requested) throw new Error(`${file}: expected ${requested}, found ${actual}; synchronize versions before building.`);
}
console.log(`Release candidate version ${requested} agrees across npm, Cargo and workspace manifests.`);
