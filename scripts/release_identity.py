#!/usr/bin/env python3
"""Resolve one committed release source; never move an existing tag."""
import os
from pathlib import Path
import re
import subprocess
import json
import urllib.error
import urllib.request


def main():
    version = os.environ['BMP_VERSION']
    if not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version):
        raise ValueError('Version must be a v-prefixed semantic release tag.')
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    if sha != os.environ['GITHUB_SHA']:
        raise RuntimeError('Checkout differs from the triggering workflow SHA.')
    existing = subprocess.run(['git', 'rev-parse', '--verify', f'refs/tags/{version}^{{commit}}'], capture_output=True, text=True)
    if existing.returncode == 0 and existing.stdout.strip() != sha:
        raise RuntimeError('Existing release tag points to another commit; tag movement is forbidden.')
    # Recheck remote publication before any Docker version/latest tag is pushed.
    repository = os.environ['GITHUB_REPOSITORY']
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'BioMarkerPred-release-preflight'}
    if os.environ.get('GITHUB_TOKEN'):
        headers['Authorization'] = 'Bearer ' + os.environ['GITHUB_TOKEN']
    request = urllib.request.Request(f'https://api.github.com/repos/{repository}/releases/tags/{version}', headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            release = json.load(response)
        if not release.get('draft'):
            raise RuntimeError('This version is already public; do not replace its installers or Docker tags.')
        if release.get('target_commitish') != sha:
            raise RuntimeError('Existing draft targets a different source SHA.')
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    subprocess.run(['node', 'scripts/check_release_version.cjs', version], check=True)
    if not Path(f'docs/releases/{version}.md').is_file():
        raise RuntimeError('Reviewed release notes are required.')
    publish = os.environ.get('BMP_PUBLISH', 'false').lower()
    if publish not in ('true', 'false'):
        raise ValueError('Invalid publish flag')
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as stream:
        stream.write(f'sha={sha}\nversion={version}\npublish={publish}\n')
    print(f'Candidate {version}: source {sha}; publication requested: {publish}')


if __name__ == '__main__':
    main()
