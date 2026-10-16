#!/usr/bin/env python3
"""Generate synthetic runs and exercise the built UI with a simulated IPC bridge.

Standalone HTML interactions are tested too. This is separate from native desktop
IPC and real Rust process/container integration tests.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rscript', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='A new evidence directory')
    parser.add_argument('--port', type=int, default=5179)
    parser.add_argument('--chromium', type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    rscript = args.rscript.resolve()
    output.mkdir(parents=True, exist_ok=False)
    def run(command):
        subprocess.run([str(part) for part in command], cwd=ROOT, check=True)
    with (output / 'fixtures.log').open('w') as log:
        subprocess.run([str(rscript), str(ROOT / 'tests/generate_browser_fixtures.R'), str(output / 'fixtures')],
                       cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    fixtures = json.loads((output / 'fixtures/fixtures.json').read_text())
    chromium = ['--chromium', args.chromium] if args.chromium else []
    for test in ('test_pathway_report_browser.py', 'test_pathway_html_interactions.py'):
        run([sys.executable, ROOT / 'tests' / test, Path(fixtures['pathway']) / 'report.html', *chromium])
    url = f'http://127.0.0.1:{args.port}'
    with (output / 'preview.log').open('w') as log:
        server = subprocess.Popen(['npm', 'run', 'preview', '--', '--host', '127.0.0.1', '--port', str(args.port), '--strictPort'],
                                  cwd=ROOT / 'gui', stdout=log, stderr=subprocess.STDOUT,
                                  start_new_session=os.name != 'nt')
        try:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError('Preview exited; inspect preview.log')
                try:
                    with urllib.request.urlopen(url, timeout=1):
                        break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError('Preview did not become ready')
            run([sys.executable, ROOT / 'tests/test_desktop_browser.py', '--url', url,
                 '--rscript', rscript, '--development-run', fixtures['binary'],
                 '--survival-run', fixtures['survival'], '--pathway-run', fixtures['pathway'],
                 '--screenshot', output / 'desktop.png', '--log', output / 'ipc-calls.json', *chromium])
        finally:
            if os.name != 'nt':
                import signal
                try:
                    os.killpg(server.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            else:
                server.terminate()
            server.wait(timeout=10)


if __name__ == '__main__':
    main()
