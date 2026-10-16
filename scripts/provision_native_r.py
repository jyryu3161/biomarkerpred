#!/usr/bin/env python3
"""Install hash-locked Windows/macOS R binary packages into an isolated library.

R 4.4.3 itself is installed by the pinned setup-r action. No package resolution,
source compilation or fallback to an unpinned repository is permitted here.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ORDER = ['yaml', 'jsonlite', 'digest', 'Rcpp', 'Matrix', 'survival', 'RcppEigen',
         'iterators', 'foreach', 'shape', 'plyr', 'glmnet', 'pROC']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rscript', default=shutil.which('Rscript'))
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    key = 'windows' if os.name == 'nt' else 'macos-arm64' if platform.system() == 'Darwin' and platform.machine() == 'arm64' else None
    if key is None or not args.rscript:
        raise RuntimeError('This binary lock requires Windows x64 or native Apple Silicon and an installed Rscript.')
    lock = json.loads((ROOT / 'tests/runtime/native-r-lock.json').read_text())
    version = subprocess.check_output([args.rscript, '--vanilla', '-e', 'cat(as.character(getRversion()))'], text=True).strip()
    if version != lock['r_version']:
        raise RuntimeError(f'Expected R {lock["r_version"]}, found {version}')
    library = args.library.resolve()
    library.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['R_LIBS_USER'] = str(library)
    packages = lock['platforms'][key]
    with tempfile.TemporaryDirectory(prefix='bmp-native-packages-') as directory:
        for name in ORDER:
            item = packages[name]
            path = Path(directory) / item['url'].rsplit('/', 1)[1]
            with urllib.request.urlopen(item['url'], timeout=120) as response:
                payload = response.read()
            if hashlib.sha256(payload).hexdigest() != item['sha256']:
                raise RuntimeError(f'{name}: binary hash changed; stop and review the lock.')
            path.write_bytes(payload)
            subprocess.run([args.rscript, '--vanilla', '-e',
                            'a<-commandArgs(TRUE);install.packages(a[1],repos=NULL,type=.Platform$pkgType,lib=a[2])',
                            str(path), str(library)], env=env, check=True)
    expected = {name: item['version'].replace('-', '.') for name, item in packages.items()}
    code = 'p<-commandArgs(TRUE);cat(jsonlite::toJSON(setNames(lapply(p,function(x)as.character(packageVersion(x))),p),auto_unbox=TRUE))'
    installed = json.loads(subprocess.check_output([args.rscript, '--vanilla', '-e', code, *ORDER], env=env, text=True))
    if installed != expected:
        raise RuntimeError(f'Installed versions differ: {installed} != {expected}')
    doctor = subprocess.run([args.rscript, str(ROOT / 'BiomarkerCLI.R'), 'doctor', '--json'], env=env, text=True, capture_output=True, check=True)
    evidence = {'platform': key, 'rscript': args.rscript, 'library': str(library), 'packages': packages,
                'doctor': json.loads(doctor.stdout)}
    args.evidence.parent.mkdir(parents=True, exist_ok=True)
    args.evidence.write_text(json.dumps(evidence, indent=2), encoding='utf-8')
    if os.environ.get('GITHUB_ENV'):
        with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as stream:
            stream.write(f'R_LIBS_USER={library}\nBMP_TEST_RSCRIPT={args.rscript}\nBMP_RSCRIPT={args.rscript}\n')
    print(json.dumps({'ok': True, 'platform': key, 'doctor': evidence['doctor']}, indent=2))


if __name__ == '__main__':
    main()
