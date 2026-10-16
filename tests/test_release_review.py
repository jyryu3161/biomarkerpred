#!/usr/bin/env python3
"""Independent offline checks for the release's identity and artifact gates."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VERIFY = runpy.run_path(str(ROOT / 'scripts/verify_release_assets.py'))['verify']


class ReleaseReview(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='bmp-release-review-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.assets = self.base / 'assets'
        self.engine = self.base / 'engine'
        self.assets.mkdir()
        self.engine.mkdir()
        self.sha = 'a' * 40
        self.version = 'v0.5.0'
        self.image_id = 'sha256:' + 'b' * 64
        self.names = {
            'linux-x64': ['BioMarkerPred_0.5.0_amd64.deb', 'BioMarkerPred-0.5.0-1.x86_64.rpm', 'BioMarkerPred_0.5.0_amd64.AppImage'],
            'windows-x64': ['BioMarkerPred_0.5.0_x64_en-US.msi', 'BioMarkerPred_0.5.0_x64-setup.exe'],
            'macos-universal': ['BioMarkerPred_0.5.0_universal.dmg', 'BioMarkerPred-macos-universal.app.tar.gz'],
        }
        for platform, names in self.names.items():
            for name in names:
                (self.assets / name).write_bytes(('synthetic installer: ' + name).encode())
            if platform == 'windows-x64':
                proof = [{'installer': name, 'native_ipc': 'passed'} for name in names]
            elif platform == 'linux-x64':
                proof = [{'installer': names[0], 'native_ipc': 'passed'}]
            else:
                proof = [{'installer': names[0], 'app_launch': 'passed', 'native_ipc': 'not tested'}]
            for row in proof:
                row['doctor'] = {'ok': True, 'application_version': self.version[1:],
                                 'graphics': {name: True for name in ('cairo', 'png', 'tiff')}}
            proof_name = platform + '-verification.json'
            (self.assets / proof_name).write_text(json.dumps(proof))
            manifest = {'source_sha': self.sha, 'version': self.version, 'platform': platform,
                        'files': {name: self.identity(self.assets / name) for name in [*names, proof_name]}}
            self.write_manifest(platform, manifest)
        self.image = [{'Id': self.image_id, 'Config': {'Labels': {
            'org.opencontainers.image.revision': self.sha,
            'org.opencontainers.image.version': self.version[1:]}}}]
        self.write_image()
        archive = self.engine / 'image.tar.gz'
        archive.write_bytes(b'synthetic archive bytes; the real workflow separately loads Docker')
        (self.engine / 'image.tar.gz.sha256').write_text(self.identity(archive)['sha256'] + '  image.tar.gz\n')

    @staticmethod
    def identity(path):
        return {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'bytes': path.stat().st_size}

    def write_manifest(self, platform, value):
        (self.assets / (platform + '-manifest.json')).write_text(json.dumps(value))

    def manifest(self, platform):
        return json.loads((self.assets / (platform + '-manifest.json')).read_text())

    def write_image(self):
        (self.engine / 'image-inspect.json').write_text(json.dumps(self.image))

    def verify(self):
        return VERIFY(self.assets, self.engine, self.sha, self.version)

    def test_complete_candidate_retains_exact_image_identity(self):
        self.assertEqual(self.verify(), self.image_id)

    def test_installer_tampering_is_rejected(self):
        (self.assets / self.names['windows-x64'][0]).write_bytes(b'changed')
        with self.assertRaises((RuntimeError, ValueError)):
            self.verify()

    def test_other_source_or_version_is_rejected(self):
        for field, value in [('source_sha', 'c' * 40), ('version', 'v9.9.9')]:
            with self.subTest(field=field):
                manifest = self.manifest('windows-x64')
                original = manifest[field]
                manifest[field] = value
                self.write_manifest('windows-x64', manifest)
                with self.assertRaises((RuntimeError, ValueError)):
                    self.verify()
                manifest[field] = original
                self.write_manifest('windows-x64', manifest)

    def test_missing_msi_cannot_be_hidden_by_removing_its_manifest_entry(self):
        name = self.names['windows-x64'][0]
        (self.assets / name).unlink()
        manifest = self.manifest('windows-x64')
        del manifest['files'][name]
        self.write_manifest('windows-x64', manifest)
        with self.assertRaises((RuntimeError, ValueError)):
            self.verify()

    def test_failed_native_proof_is_rejected_even_with_matching_hash(self):
        name = 'windows-x64-verification.json'
        path = self.assets / name
        proof = json.loads(path.read_text())
        proof[0]['native_ipc'] = 'failed'
        path.write_text(json.dumps(proof))
        manifest = self.manifest('windows-x64')
        manifest['files'][name] = self.identity(path)
        self.write_manifest('windows-x64', manifest)
        with self.assertRaises((RuntimeError, ValueError)):
            self.verify()

    def test_two_copies_of_one_windows_installer_are_not_two_verified_installers(self):
        name = 'windows-x64-verification.json'
        path = self.assets / name
        proof = json.loads(path.read_text())
        proof[1] = proof[0]
        path.write_text(json.dumps(proof))
        manifest = self.manifest('windows-x64')
        manifest['files'][name] = self.identity(path)
        self.write_manifest('windows-x64', manifest)
        with self.assertRaises((RuntimeError, ValueError)):
            self.verify()

    def test_image_archive_tampering_is_rejected(self):
        (self.engine / 'image.tar.gz').write_bytes(b'different image')
        with self.assertRaises((RuntimeError, ValueError)):
            self.verify()

    def test_image_from_another_source_is_rejected(self):
        self.image[0]['Config']['Labels']['org.opencontainers.image.revision'] = 'c' * 40
        self.write_image()
        with self.assertRaises((RuntimeError, ValueError)):
            self.verify()

    def test_collector_rejects_failed_proof_with_python_optimization(self):
        bundles = self.base / 'bundles'
        bundles.mkdir()
        for name in self.names['windows-x64']:
            (bundles / name).write_bytes(b'synthetic installer')
        proof = self.base / 'failed-verification.json'
        proof.write_text(json.dumps([{'installer': name, 'native_ipc': 'failed'} for name in self.names['windows-x64']]))
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        result = subprocess.run([sys.executable, '-O', str(ROOT / 'scripts/collect_release_assets.py'),
                                 '--bundles', str(bundles), '--platform', 'windows-x64', '--sha', head,
                                 '--verification', str(proof), '--output', str(self.base / 'collected')],
                                env={**os.environ, 'PYTHONUTF8': '1'}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.base / 'collected/windows-x64-manifest.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
