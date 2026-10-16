#!/usr/bin/env python3
"""Check the loaded tag against the tested image before any registry mutation."""
import json
import os
from pathlib import Path
import subprocess

version = os.environ['BMP_RELEASE_VERSION']
expected = json.loads(Path('verified-engine/image-inspect.json').read_text())[0]
loaded = json.loads(subprocess.check_output(['docker', 'image', 'inspect', f'jyryu3161/biomarkerpred:{version}'], text=True))[0]
if loaded['Id'] != expected['Id'] or loaded['Config']['Labels'] != expected['Config']['Labels']:
    raise RuntimeError('Loaded release tag does not identify the exact tested image; refusing to push.')
print(f'Loaded image identity verified: {loaded["Id"]}')
