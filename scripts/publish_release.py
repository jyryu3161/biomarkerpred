#!/usr/bin/env python3
"""Publish only this gated candidate; complete assets before making a draft public.

Uses the workflow token without printing it. Existing published releases are never
replaced; a failed same-SHA draft can be retried with identical/checksummed assets.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import urllib.error
import urllib.parse
import urllib.request

from verify_release_assets import verify

ROOT = Path(__file__).resolve().parents[1]


def main():
    sha, version = os.environ['BMP_SOURCE_SHA'], os.environ['BMP_RELEASE_VERSION']
    repository = os.environ['GITHUB_REPOSITORY']
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid repository')
    assets = ROOT / 'release-assets'
    image_id = verify(assets, ROOT / 'verified-engine', sha, version)
    published = json.loads((assets / 'published-image.json').read_text())[0]
    if published['Id'] != image_id:
        raise RuntimeError('Published image is not the tested image')
    digest = next((x for x in published.get('RepoDigests', []) if x.startswith('jyryu3161/biomarkerpred@sha256:')), None)
    if not digest:
        raise RuntimeError('Registry digest is missing')
    api = f'https://api.github.com/repos/{repository}'
    headers = {'Authorization': 'Bearer ' + os.environ['GITHUB_TOKEN'], 'Accept': 'application/vnd.github+json',
               'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'BioMarkerPred-gated-release'}

    def request(method, url, payload=None, binary=False):
        data = payload if binary else None if payload is None else json.dumps(payload).encode()
        options = dict(headers)
        if data is not None:
            options['Content-Type'] = 'application/octet-stream' if binary else 'application/json'
        with urllib.request.urlopen(urllib.request.Request(url, data=data, method=method, headers=options), timeout=300) as response:
            content = response.read()
            return json.loads(content) if content else None

    def optional(url):
        try:
            return request('GET', url)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise

    reference = optional(api + '/git/ref/tags/' + version)
    if reference:
        target = reference['object']
        while target['type'] == 'tag':
            target = request('GET', target['url'])['object']
        if target['type'] != 'commit' or target['sha'] != sha:
            raise RuntimeError('Refusing to move a tag or publish from another SHA')
    existing = optional(api + '/releases/tags/' + version)
    if existing and not existing['draft']:
        raise RuntimeError('This version is already published; do not replace released artifacts.')
    if existing and existing['target_commitish'] != sha:
        raise RuntimeError('Existing draft targets another source; refusing to replace it.')

    # A source archive with only tracked program/config/docs/synthetic tests;
    # exclude root example datasets, outputs, caches and any untracked local files.
    source = assets / f'BioMarkerPred-{version}-source.tar.gz'
    allowed = ['R', 'gui/src', 'gui/public', 'gui/src-tauri/src', 'gui/src-tauri/icons', 'gui/src-tauri/capabilities',
               'config', 'scripts', 'tests', 'docs', '.github']
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    selected = []
    for name in filter(None, tracked):
        path = Path(name)
        root_file = len(path.parts) == 1 and path.suffix in ('.R', '.py', '.sh', '.bat', '.md', '.toml', '.lock')
        program = any(name == prefix or name.startswith(prefix + '/') for prefix in allowed)
        frontend_config = name.startswith('gui/') and len(path.parts) == 2 and path.suffix in ('.json', '.ts', '.js', '.html')
        rust_config = name in ('gui/src-tauri/Cargo.toml', 'gui/src-tauri/Cargo.lock', 'gui/src-tauri/build.rs', 'gui/src-tauri/tauri.conf.json', 'gui/src-tauri/rustfmt.toml', 'gui/src-tauri/.gitignore')
        if root_file or program or frontend_config or rust_config or name in ('Dockerfile', '.dockerignore', '.gitignore', '.gitattributes', 'LICENSE', 'LICENSE.txt'):
            selected.append(name)
    # git archive reads committed bytes, never a changed checkout file.
    raw = subprocess.check_output(['git', 'archive', '--format=tar', f'--prefix=BioMarkerPred-{version}/', sha, '--', *selected], cwd=ROOT)
    import gzip
    with source.open('wb') as stream:
        with gzip.GzipFile(filename='', mode='wb', fileobj=stream, mtime=0) as zipped:
            zipped.write(raw)
    notes = (ROOT / f'docs/releases/{version}.md').read_text()
    notes += f'\n\nSource commit: `{sha}`\n\nPublished engine: `{digest}`\n\nTested image ID: `{image_id}`\n\nVerification workflow: https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}\n'
    (assets / 'RELEASE_NOTES.md').write_text(notes, encoding='utf-8')
    paths = sorted(path for path in assets.iterdir() if path.is_file() and path.name != 'SHA256SUMS')
    (assets / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n' for path in paths), encoding='utf-8')
    paths.append(assets / 'SHA256SUMS')
    release = existing or request('POST', api + '/releases', {'tag_name': version, 'target_commitish': sha,
                    'name': f'BioMarkerPred {version}', 'body': notes, 'draft': True,
                    'prerelease': '-' in version})
    if existing:
        # The same-SHA draft is not public. Replace its incomplete candidate assets.
        for asset in request('GET', api + f'/releases/{release["id"]}/assets?per_page=100'):
            request('DELETE', asset['url'])
    upload = release['upload_url'].split('{')[0]
    for path in paths:
        result = request('POST', upload + '?name=' + urllib.parse.quote(path.name), path.read_bytes(), binary=True)
        if result['size'] != path.stat().st_size:
            raise RuntimeError(f'Upload size differs: {path.name}')
    completed = request('PATCH', api + f'/releases/{release["id"]}', {'draft': False, 'body': notes, 'make_latest': 'false' if '-' in version else 'true'})
    print(completed['html_url'])


if __name__ == '__main__':
    main()
