#!/usr/bin/env python3
"""Collect tested installer files, with per-platform provenance and hashes."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundles', type=Path, required=True)
    parser.add_argument('--platform', choices=['linux-x64', 'windows-x64', 'macos-universal'], required=True)
    parser.add_argument('--sha', required=True)
    parser.add_argument('--verification', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if actual != args.sha:
        raise RuntimeError('Asset source SHA differs from the verified checkout.')
    args.output.mkdir(parents=True, exist_ok=False)
    expected = {'linux-x64': ['.deb', '.rpm', '.AppImage'], 'windows-x64': ['.msi', '.exe'], 'macos-universal': ['.dmg']}[args.platform]
    files = []
    for suffix in expected:
        candidates = list(args.bundles.rglob('*' + suffix))
        if len(candidates) != 1:
            raise RuntimeError(f'Expected exactly one {suffix} installer: {candidates}')
        destination = args.output / candidates[0].name
        shutil.copyfile(candidates[0], destination)
        files.append(destination)
    if args.platform == 'macos-universal':
        bundle = next((args.bundles / 'macos').glob('*.app'))
        destination = args.output / 'BioMarkerPred-macos-universal.app.tar.gz'
        with tarfile.open(destination, 'w:gz') as archive:
            archive.add(bundle, arcname=bundle.name)
        files.append(destination)
    verification = json.loads(args.verification.read_text())
    if args.platform == 'windows-x64':
        if len(verification) != 2 or not all(row.get('native_ipc') == 'passed' for row in verification):
            raise RuntimeError('Both installed Windows formats must pass native IPC.')
    elif args.platform == 'linux-x64':
        if len(verification) != 1 or verification[0].get('native_ipc') != 'passed':
            raise RuntimeError('Installed Linux native IPC did not pass.')
    else:
        if len(verification) != 1 or verification[0].get('app_launch') != 'passed':
            raise RuntimeError('Installed macOS application launch did not pass.')
    proof = args.output / f'{args.platform}-verification.json'
    proof.write_text(json.dumps(verification, indent=2), encoding='utf-8')
    files.append(proof)
    manifest = {'source_sha': args.sha, 'platform': args.platform,
                'version': 'v' + json.loads((ROOT / 'gui/package.json').read_text())['version'],
                'files': {p.name: {'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'bytes': p.stat().st_size} for p in files}}
    (args.output / f'{args.platform}-manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
