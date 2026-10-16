#!/usr/bin/env python3
"""Install candidate bundles and test actual installed engines; Windows/Linux IPC.

Synthetic files only. macOS checks bundled CLI and real app launch, not WebDriver
IPC: this project uses the native tauri-driver route, which has no WKWebView driver.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def edge_driver(destination):
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
        actual = subprocess.check_output([str(driver), '--version'], text=True).strip()
        if not re.search(r'\b' + re.escape('.'.join(version.split('.')[:3])) + r'\.', actual):
            raise RuntimeError(f'WebView2/driver mismatch: {version}, {actual}')
        (destination / 'webdriver-provenance.json').write_text(json.dumps({
            'runtime': version, 'runtime_directory': str(folder), 'driver': actual,
            'url': url, 'download_sha256': hashlib.sha256(data).hexdigest()}, indent=2))
        return driver
    raise RuntimeError(f'No compatible Microsoft Edge driver for WebView2 {version}; do not skip native verification.')


def verify_engine(engine, rscript):
    expected = [*ROOT.glob('*.R'), *(ROOT / 'R').glob('*.R'), ROOT / 'config/schema.json']
    for source in expected:
        target = engine / source.relative_to(ROOT)
        if not target.is_file() or target.read_bytes() != source.read_bytes():
            raise AssertionError(f'Installed engine differs: {target}')
    result = run(rscript, engine / 'BiomarkerCLI.R', 'doctor', '--json', capture_output=True, text=True, cwd=engine.parent)
    doctor = json.loads(result.stdout)
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
        server = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, cwd=output)
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
            run(sys.executable, ROOT / 'tests/test_native_desktop.py', '--application', application,
                '--rscript', rscript, '--engine-root', engine, '--data-dir', data, *screenshot, cwd=output)
        finally:
            if server.poll() is None:
                if os.name == 'nt':
                    subprocess.run(['taskkill', '/PID', str(server.pid), '/T', '/F'], capture_output=True)
                else:
                    server.terminate()
                server.wait(timeout=15)
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
    results = []
    if os.name == 'nt':
        msi = next(bundles.rglob('*.msi'))
        exe = next((bundles / 'nsis').glob('*.exe'))
        driver = None
        for kind, installer in [('msi', msi), ('nsis', exe)]:
            folder = output / kind
            folder.mkdir()
            install = folder / 'Installed BioMarkerPred'
            if kind == 'msi':
                process = subprocess.run(['msiexec.exe', '/i', str(installer), '/qn', '/norestart',
                                          f'INSTALLDIR={install}', '/L*v', str(folder / 'install.log')])
                if process.returncode not in (0, 3010):
                    raise RuntimeError(f'MSI installation failed: {process.returncode}')
            else:
                # NSIS /D is the final, unquoted raw command-line tail (no shell).
                subprocess.run(f'"{installer}" /S /D={install}', executable=str(installer), check=True)
            application = install / 'biomarkerpred.exe'
            if not application.is_file():
                raise RuntimeError(f'Installer did not create {application}')
            engine = next(install.rglob('BiomarkerCLI.R')).parent
            doctor = verify_engine(engine, args.rscript)
            if driver is None:
                driver = edge_driver(output)
            record = native(application, engine, args.rscript, folder, driver)
            record.update(installer=installer.name, doctor=doctor)
            results.append(record)
            if kind == 'msi':
                removed = subprocess.run(['msiexec.exe', '/x', str(installer), '/qn', '/norestart'])
                if removed.returncode not in (0, 3010):
                    raise RuntimeError('MSI uninstall failed before NSIS verification')
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
        doctor = verify_engine(engine, args.rscript)
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
        doctor = verify_engine(engine, args.rscript)
        record = native(application, engine, args.rscript, output, shutil.which('WebKitWebDriver'))
        record.update(installer=deb.name, doctor=doctor)
        results.append(record)
    (output / 'installed-verification.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
