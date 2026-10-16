# Review runtimes

The canonical runtime is the root `pixi.toml`/`pixi.lock` (Pixi 0.71.2, Linux x86_64, R 4.4.3 and six exact core packages). Run `./install.sh` from the repository to install it and check core packages/Cairo/PNG/TIFF. This directory retains an equivalent exact dependency manifest/lock for existing review scripts; new commands should use root `.pixi/envs/default/bin/Rscript` explicitly. Do not add test-only scientific dependencies silently.

`Dockerfile.rust` pins Rust 1.90 and installs Linux GTK/WebKit build libraries. It is a development/test image, not the production engine. The root Dockerfile independently builds the installed production engine from the root lock, pinned base digests and Debian package snapshot with Noto CJK fonts.

To run the full integration gates, set `BMP_TEST_RSCRIPT` and `BMP_TEST_ENGINE_ROOT` to accessible absolute paths, and `BMP_TEST_DOCKER_IMAGE=biomarkerpred-engine:local`, `BMP_TEST_DOCKER_PATH=/usr/bin/docker`. If cargo runs in a container using the host Docker socket, paths used for mounts and temporary configs must be visible at the same absolute paths to the host daemon. Give that container the socket's group and keep its temporary directory in a host-mounted location. Never expose real patient data to tests.

Python browser tooling is pinned in `tests/requirements-browser.txt`; Playwright pins its Chromium revision. `scripts/ci_browser.py` creates fresh synthetic null-model and mapped-network fixtures and starts an isolated built preview. Its IPC is simulated. Installed Linux desktop checks require WebKitWebDriver, tauri-driver 2.1.0, Xvfb and `tests/test_native_desktop.py`; that is separate evidence.
