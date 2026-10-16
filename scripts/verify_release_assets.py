#!/usr/bin/env python3
"""Reject mismatched/tampered candidates before loading an image or publishing."""
import hashlib
import json
import os
from pathlib import Path
import re

PLATFORMS = ['linux-x64', 'windows-x64', 'macos-universal']


def verify(assets, engine, sha, version):
    if not re.fullmatch(r'[0-9a-f]{40}', sha) or not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
        raise ValueError('Invalid release identity')
    expected_files = set()
    for platform in PLATFORMS:
        manifest = json.loads((assets / f'{platform}-manifest.json').read_text())
        if manifest['source_sha'] != sha or manifest['version'] != version or manifest['platform'] != platform:
            raise RuntimeError(f'{platform}: source/version mismatch')
        required = {'linux-x64': ['.deb', '.rpm', '.AppImage'], 'windows-x64': ['.msi', '.exe'], 'macos-universal': ['.dmg', '.app.tar.gz']}[platform]
        for suffix in required:
            if len([name for name in manifest['files'] if name.endswith(suffix)]) != 1:
                raise RuntimeError(f'{platform}: expected one {suffix} installer')
        proof_name = f'{platform}-verification.json'
        if proof_name not in manifest['files']:
            raise RuntimeError(f'{platform}: installed verification is missing')
        expected_files.update(manifest['files'])
        expected_files.add(f'{platform}-manifest.json')
        for name, item in manifest['files'].items():
            if Path(name).name != name:
                raise RuntimeError('Invalid artifact filename')
            path = assets / name
            if path.stat().st_size != item['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
                raise RuntimeError(f'{name}: checksum mismatch')
        proof = json.loads((assets / proof_name).read_text())
        required_proofs = ['.msi', '.exe'] if platform == 'windows-x64' else ['.deb'] if platform == 'linux-x64' else ['.dmg']
        if len(proof) != len(required_proofs):
            raise RuntimeError(f'{platform}: installed verification count differs')
        for suffix in required_proofs:
            rows = [row for row in proof if row.get('installer', '').endswith(suffix)]
            if len(rows) != 1 or rows[0]['installer'] not in manifest['files']:
                raise RuntimeError(f'{platform}: missing installed {suffix} proof')
            row = rows[0]
            required_status = 'app_launch' if platform == 'macos-universal' else 'native_ipc'
            if row.get(required_status) != 'passed':
                raise RuntimeError(f'{platform}: installed verification failed')
            doctor = row.get('doctor', {})
            if not doctor.get('ok') or doctor.get('application_version') != version[1:] or not all(doctor.get('graphics', {}).get(name) is True for name in ('cairo', 'png', 'tiff')):
                raise RuntimeError(f'{platform}: installed runtime/graphics doctor failed')
    unexpected = {p.name for p in assets.iterdir()} - expected_files - {'published-image.json'}
    if unexpected:
        raise RuntimeError(f'Unverified extra release assets: {sorted(unexpected)}')
    image = json.loads((engine / 'image-inspect.json').read_text())[0]
    if image['Config']['Labels']['org.opencontainers.image.revision'] != sha:
        raise RuntimeError('Image source SHA differs')
    if image['Config']['Labels']['org.opencontainers.image.version'] != version[1:]:
        raise RuntimeError('Image version differs')
    recorded = (engine / 'image.tar.gz.sha256').read_text().split()[0]
    hasher = hashlib.sha256()
    with (engine / 'image.tar.gz').open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    if digest != recorded:
        raise RuntimeError('Downloaded tested-image archive differs')
    return image['Id']


if __name__ == '__main__':
    print(verify(Path('release-assets'), Path('verified-engine'), os.environ['BMP_SOURCE_SHA'], os.environ['BMP_RELEASE_VERSION']))
