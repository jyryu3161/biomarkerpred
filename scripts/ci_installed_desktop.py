#!/usr/bin/env python3
"""Install candidate bundles and test actual installed engines; Windows/Linux IPC.

Synthetic files only. macOS checks bundled CLI and real app launch, not WebDriver
IPC: this project uses the native tauri-driver route, which has no WKWebView driver.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def progress(output, phase, status, **details):
    record = {'timestamp': datetime.now(timezone.utc).isoformat(), 'phase': phase,
              'status': status, **details}
    print(json.dumps(record), flush=True)
    with (output / 'progress.jsonl').open('a', encoding='utf-8') as stream:
        stream.write(json.dumps(record) + '\n')


def diagnostics(output, phase):
    """Record only process names/PIDs and synthetic-test logs, never environment/argv."""
    if os.name == 'nt':
        command = ['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
            "Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(msiexec|biomarkerpred|Rscript|Rterm|tauri-driver|msedgedriver|msedgewebview2|MicrosoftEdgeUpdate|setup).*' } | Select-Object Name,ProcessId,ParentProcessId | ConvertTo-Json"]
    else:
        command = ['ps', '-eo', 'pid,ppid,stat,comm']
    try:
        result = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=10)
        (output / f'{phase}-processes.log').write_text(result.stdout + result.stderr, encoding='utf-8')
    except (OSError, subprocess.TimeoutExpired) as error:
        progress(output, phase, 'diagnostic_failed', error=str(error))
    for name in ('install.log', 'uninstall.log', 'driver.log'):
        path = output / name
        if path.exists():
            with path.open('rb') as stream:
                encoding = 'utf-16-le' if stream.read(2) == b'\xff\xfe' else 'utf-8'
                stream.seek(max(0, path.stat().st_size - 16384))
                tail = stream.read().decode(encoding, errors='replace')
            (output / f'{phase}-{name}.tail').write_text(tail, encoding='utf-8')
            print(f'[{phase}] {name} tail:\n{tail}', flush=True)


def terminate_owned(process, output, phase):
    # Never signal a PID after our direct child has exited (it may be reused).
    if process.poll() is not None:
        return True
    try:
        if os.name == 'nt':
            stopped = subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                                     capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=20)
            if stopped.returncode != 0:
                progress(output, phase, 'cleanup_unverified', error=stopped.stderr)
                return False
        else:
            os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)
        progress(output, phase, 'owned_process_stopped', pid=process.pid, returncode=process.returncode)
        return True
    except (OSError, subprocess.TimeoutExpired) as error:
        progress(output, phase, 'cleanup_unverified', error=str(error), pid=process.pid)
        return False


def bounded(command, *, output, phase, timeout, allowed=(0,), capture=False, **kwargs):
    """Bound an owned process and retain phase evidence without skipping a gate."""
    started = time.monotonic()
    progress(output, phase, 'starting', timeout_seconds=timeout)
    streams = []
    try:
        if capture:
            streams = [(output / f'{phase}-{name}.log').open('wb') for name in ('stdout', 'stderr')]
            kwargs.update(stdout=streams[0], stderr=streams[1])
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=os.name != 'nt', **kwargs)
        progress(output, phase, 'running', pid=process.pid)
        while True:
            remaining = timeout - (time.monotonic() - started)
            try:
                process.wait(timeout=max(.01, min(30, remaining)))
                break
            except subprocess.TimeoutExpired:
                elapsed = round(time.monotonic() - started, 1)
                if elapsed < timeout:
                    progress(output, phase, 'waiting', pid=process.pid, elapsed_seconds=elapsed)
                    continue
                progress(output, phase, 'timed_out', pid=process.pid, elapsed_seconds=elapsed)
                try:
                    diagnostics(output, phase)
                except OSError as error:
                    progress(output, phase, 'diagnostic_failed', error=str(error))
                terminate_owned(process, output, phase)
                raise TimeoutError(f'{phase} exceeded {timeout}s; see {output}/progress.jsonl and diagnostic logs')
        progress(output, phase, 'completed' if process.returncode in allowed else 'failed',
                 pid=process.pid, returncode=process.returncode, elapsed_seconds=round(time.monotonic() - started, 1))
        if process.returncode not in allowed:
            diagnostics(output, phase)
            raise subprocess.CalledProcessError(process.returncode, command)
    finally:
        for stream in streams:
            stream.close()
    return (output / f'{phase}-stdout.log').read_text(encoding='utf-8') if capture else None


def edge_driver(destination):
    progress(destination, 'webdriver_download', 'starting')
    candidates = []
    for variable in ('ProgramFiles(x86)', 'ProgramFiles', 'LOCALAPPDATA'):
        parent = Path(os.environ.get(variable, 'C:/not-found')) / 'Microsoft/EdgeWebView/Application'
        for executable in parent.glob('*/msedgewebview2.exe'):
            if re.fullmatch(r'\d+\.\d+\.\d+\.\d+', executable.parent.name):
                candidates.append((tuple(map(int, executable.parent.name.split('.'))), executable.parent))
    if not candidates:
        raise RuntimeError('WebView2 runtime is missing after installer execution.')
    numbers, folder = max(candidates)
    version = '.'.join(map(str, numbers))
    # Bind this test process to the detected runtime, preventing an update race.
    os.environ['WEBVIEW2_BROWSER_EXECUTABLE_FOLDER'] = str(folder)
    versions = [version]
    try:
        with urllib.request.urlopen(f'https://msedgedriver.microsoft.com/LATEST_RELEASE_{numbers[0]}_WINDOWS', timeout=60) as response:
            payload = response.read()
            fallback = payload.decode('utf-16' if payload[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8-sig').strip()
        if fallback.split('.')[:3] == version.split('.')[:3] and fallback not in versions:
            versions.append(fallback)
    except (urllib.error.URLError, TimeoutError):
        pass
    for candidate in versions:
        url = f'https://msedgedriver.microsoft.com/{candidate}/edgedriver_win64.zip'
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                data = response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                continue
            raise
        path = destination / 'edgedriver.zip'
        path.write_bytes(data)
        with zipfile.ZipFile(path) as archive:
            driver = destination / 'msedgedriver.exe'
            driver.write_bytes(archive.read('msedgedriver.exe'))
        actual = bounded([str(driver), '--version'], output=destination, phase='webdriver_version', timeout=15, capture=True).strip()
        if not re.search(r'\b' + re.escape('.'.join(version.split('.')[:3])) + r'\.', actual):
            raise RuntimeError(f'WebView2/driver mismatch: {version}, {actual}')
        (destination / 'webdriver-provenance.json').write_text(json.dumps({
            'runtime': version, 'runtime_directory': str(folder), 'driver': actual,
            'url': url, 'download_sha256': hashlib.sha256(data).hexdigest()}, indent=2))
        progress(destination, 'webdriver_download', 'completed', runtime=version, driver=actual)
        return driver
    raise RuntimeError(f'No compatible Microsoft Edge driver for WebView2 {version}; do not skip native verification.')


def verify_engine(engine, rscript, output):
    expected = [*ROOT.glob('*.R'), *(ROOT / 'R').glob('*.R'), ROOT / 'config/schema.json']
    for source in expected:
        target = engine / source.relative_to(ROOT)
        if not target.is_file() or target.read_bytes() != source.read_bytes():
            raise AssertionError(f'Installed engine differs: {target}')
    result = bounded([str(rscript), str(engine / 'BiomarkerCLI.R'), 'doctor', '--json'], output=output,
                     phase='installed_doctor', timeout=90, capture=True, cwd=engine.parent)
    doctor = json.loads(result)
    assert doctor['ok'] and all(doctor['graphics'][name] for name in ('cairo', 'png', 'tiff'))
    assert doctor['application_version'] == json.loads((ROOT / 'gui/package.json').read_text())['version']
    return doctor


def native(application, engine, rscript, output, driver):
    data = output / 'synthetic data 한글'
    data.mkdir()
    shutil.copyfile(ROOT / 'tests/fixtures/binary.csv', data / 'binary.csv')
    (data / 'identifiers.csv').write_text('sample,patient\n00001,patient001\n9007199254740993123,patient002\n', encoding='utf-8')
    command = ['tauri-driver', '--native-driver', str(driver)]
    with (output / 'driver.log').open('w') as log:
        server = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, cwd=output, start_new_session=os.name != 'nt')
        progress(output, 'webdriver_server', 'running', pid=server.pid)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError('tauri-driver exited; inspect driver.log')
                try:
                    with urllib.request.urlopen('http://127.0.0.1:4444/status', timeout=1):
                        break
                except (OSError, urllib.error.HTTPError):
                    time.sleep(.2)
            else:
                raise RuntimeError('tauri-driver was not ready')
            screenshot = ['--screenshot', output / 'installed-app.png'] if os.name == 'nt' else []
            bounded([str(value) for value in (sys.executable, ROOT / 'tests/test_native_desktop.py', '--application', application,
                '--rscript', rscript, '--engine-root', engine, '--data-dir', data, *screenshot)],
                output=output, phase='installed_native_ipc', timeout=420, cwd=output)
        finally:
            failed = sys.exc_info()[0] is not None
            if not terminate_owned(server, output, 'webdriver_cleanup') and not failed:
                raise RuntimeError('Cannot verify owned WebDriver tree cleanup; see progress.jsonl')
    return {'application': str(application), 'engine': str(engine), 'native_ipc': 'passed'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundles', type=Path, required=True)
    parser.add_argument('--rscript', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    bundles = args.bundles.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    progress(output, 'installed_desktop', 'starting', output_directory=str(output), cwd=str(Path.cwd()), bundles=str(bundles))
    results = []
    if os.name == 'nt':
        msi = next(bundles.rglob('*.msi'))
        exe = next((bundles / 'nsis').glob('*.exe'))
        driver = None
        for kind, installer in [('msi', msi), ('nsis', exe)]:
            folder = output / kind
            folder.mkdir()
            progress(folder, kind, 'starting', installer=installer.name)
            install = folder / 'Installed BioMarkerPred'
            if kind == 'msi':
                resolved_msiexec = shutil.which('msiexec.exe')
                if not resolved_msiexec or not Path(resolved_msiexec).is_file():
                    raise RuntimeError('Cannot locate the Windows Installer executable msiexec.exe')
                msiexec = str(Path(resolved_msiexec).resolve())
                # MSI parses property=value itself: quote the value, not the
                # whole property token produced by Python's CRT argv quoting.
                # https://learn.microsoft.com/en-us/windows/win32/msi/command-line-options
                if any(character in str(install) for character in ('"', '\r', '\n')):
                    raise ValueError('MSI property path contains unsupported quote/newline characters')
                command = subprocess.list2cmdline([msiexec, '/i', str(installer), '/qn', '/norestart',
                                                  '/L*V!', str(folder / 'install.log')])
                command += f' INSTALLDIR="{install}"'
                bounded(command, executable=msiexec, output=folder, phase='msi_install',
                        timeout=300, allowed=(0, 3010))
            else:
                # NSIS /D is the final, unquoted raw command-line tail (no shell).
                bounded(f'"{installer}" /S /D={install}', executable=str(installer),
                        output=folder, phase='nsis_install', timeout=300)
            application = install / 'biomarkerpred.exe'
            if not application.is_file():
                raise RuntimeError(f'Installer did not create {application}')
            engine = next(install.rglob('BiomarkerCLI.R')).parent
            doctor = verify_engine(engine, args.rscript, folder)
            if driver is None:
                driver = edge_driver(output)
            record = native(application, engine, args.rscript, folder, driver)
            record.update(installer=installer.name, doctor=doctor)
            results.append(record)
            (folder / 'verification.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
            progress(folder, kind, 'verified')
            if kind == 'msi':
                bounded(['msiexec.exe', '/x', str(installer), '/qn', '/norestart', '/L*V!', str(folder / 'uninstall.log')],
                        output=folder, phase='msi_uninstall', timeout=180, allowed=(0, 3010))
    elif sys.platform == 'darwin':
        dmg = next(bundles.rglob('*.dmg'))
        mount = output / 'mounted'
        run('hdiutil', 'attach', dmg, '-readonly', '-nobrowse', '-mountpoint', mount)
        try:
            source = next(mount.glob('*.app'))
            application_bundle = output / source.name
            run('ditto', source, application_bundle)
        finally:
            run('hdiutil', 'detach', mount)
        engine = application_bundle / 'Contents/Resources/engine'
        doctor = verify_engine(engine, args.rscript, output)
        application = application_bundle / 'Contents/MacOS/biomarkerpred'
        with (output / 'application.log').open('w') as log:
            process = subprocess.Popen([str(application)], cwd=output, stdout=log, stderr=subprocess.STDOUT)
            try:
                time.sleep(10)
                if process.poll() is not None:
                    raise RuntimeError('Installed macOS application exited during launch smoke')
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=15)
        results.append({'installer': dmg.name, 'doctor': doctor, 'app_launch': 'passed',
                        'native_ipc': 'not tested: native tauri-driver has no WKWebView driver'})
    else:
        deb = next(bundles.rglob('*.deb'))
        run('sudo', 'dpkg', '-i', deb)
        package = subprocess.check_output(['dpkg-deb', '-f', str(deb), 'Package'], text=True).strip()
        files = subprocess.check_output(['dpkg', '-L', package], text=True).splitlines()
        engine = next(Path(file).parent for file in files if file.endswith('/engine/BiomarkerCLI.R'))
        application = Path(shutil.which('biomarkerpred'))
        doctor = verify_engine(engine, args.rscript, output)
        record = native(application, engine, args.rscript, output, shutil.which('WebKitWebDriver'))
        record.update(installer=deb.name, doctor=doctor)
        results.append(record)
    (output / 'installed-verification.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
