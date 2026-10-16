# BioMarkerPred desktop

The Tauri desktop calls the same `BiomarkerCLI.R` engine used by the shell. It bundles all root R entrypoints, `R/*.R` and `config/schema.json`; it does not bundle R itself. The exact command/event contract is in [docs/desktop-api.md](../docs/desktop-api.md).

## Run from source

Use Node **22.18.0**, npm **11.9.0**, Rust **1.90.0**, and the required native Tauri libraries. Linux needs WebKitGTK 4.1, GTK 3, AppIndicator, librsvg and patchelf development/runtime packages. The Linux review container is defined in [tests/runtime/Dockerfile.rust](../tests/runtime/Dockerfile.rust). Release CI verifies Windows installed MSI and EXE with real IPC; macOS verifies the installed bundled engine and app launch. Read that release's execution evidence before claiming a specific platform passed.

Native macOS R also requires [XQuartz 2.8.6](https://www.xquartz.org/releases/XQuartz-2.8.6.html) for Cairo's `/opt/X11` libraries. Install it before provisioning the native R package library, restart R/the app, and require a successful doctor result. Doctor opens and exports SVG, PDF, PNG and TIFF files to test the actual backend. See the [native runtime instructions](../README.md#installed-windows-and-macos-runtimes) for the pinned package and runtime setup.

```bash
# Repository root:
./run_gui.sh
# Or, after preparing the tools:
cd gui
npm ci
npm run tauri -- dev
```

`npm run dev` alone serves the browser UI but cannot provide desktop IPC, dialogs or engine execution. It is useful with the explicitly simulated browser test bridge. The production desktop is built with:

```bash
npm run tauri -- build --ci -- --locked
```

Run `npm test`, `npm run lint` and `npm run build` before packaging. Build resources are staged by Rust `build.rs`. Runtime engine discovery uses installed resource paths, independent of the caller's current directory; a debug checkout fallback supports development.

## Connect a runtime

In **Settings**, select either local R or Docker, save settings and run the doctor. Local R needs no Docker. For the repository's Linux locked runtime, use the absolute path to `.pixi/envs/default/bin/Rscript` after `../install.sh`. For Docker, the release default is `jyryu3161/biomarkerpred:v0.5.0`. Start Docker Desktop/Engine with Linux containers, choose **Pull configured image**, save settings and run the doctor. Existing saved settings are preserved. Developers can instead build/select `biomarkerpred-engine:local` explicitly.

The doctor must pass core-package, Cairo, PNG and TIFF checks. Native GO databases remain optional; the offline versioned GMT workflow is available in the core image. CJK font availability matters for readable reports; the production engine image includes Noto CJK.

## Research workflow

1. In **Analysis setup**, import a YAML/JSON configuration or choose a CSV and exact role/feature columns. Preserve patient groups, binary outcome codes/labels, and survival time unit/horizon. Choose resampling, candidate panels and model arms. Run QC and inspect exclusions/warnings before enabling analysis. Editing a field invalidates previous QC.
2. The global job panel shows the operation and actual saved run directory. Use **Inspect actual run** to view its artifacts. A zero process exit alone does not imply success: manifest and required artifact checks also apply. Unverified cancellation remains active with a retry option.
3. **Results & history** reads persistent manifests, compares selected runs with compatibility information, opens saved HTML/PDF reports, and supports compatible resume/report regeneration. Failed and partial runs remain visible; unavailable metrics keep their reasons.
4. **Prediction & evaluation** loads a frozen `.bmpmodel` and scores a new CSV. Prediction does not need outcomes; evaluation does. A valid null model is supported. Survival units must match explicitly. External metrics, required-predictor drift and cohort overlap remain separate from development performance.
5. **Pathways & evidence** verifies a completed development source before starting an isolated derivative. Supply a versioned GMT/term-map and optional exact identifier mapping. STRING expansion is explicit and defaults to zero. Inspect mapped backgrounds, original/expanded sets, ranked GSEA, confidence-filtered draggable networks and each original source gene sharing a node.

Open Targets fetches public disease-gene associations into immutable snapshots; cached entries retain their disease/query context. Missing scores/channels stay unavailable. Neither public functional association networks nor disease association scores establish drug-response prediction or causal mechanisms. Patient CSV rows are not sent to these evidence services.

## Verification scope

[Frontend unit tests](src/__tests__) cover configuration and state contracts. Rust integration tests exercise real R, worker process trees and Docker when their environment gates are configured. The reproducible browser runner creates synthetic runs and uses real CLI QC/scoring plus simulated IPC events/dialogs:

```bash
# From repository root, after building gui/dist:
python -m pip install -r tests/requirements-browser.txt
python -m playwright install chromium
python scripts/ci_browser.py --rscript "$PWD/.pixi/envs/default/bin/Rscript" --output /tmp/bmp-browser-review
```

This browser suite does not prove native packaged desktop behavior. The separate [tests/test_native_desktop.py](../tests/test_native_desktop.py) check passed against the installed Linux `.deb` under Xvfb: real Tauri IPC resolved the packaged engine and performed doctor, QC, analysis, artifact/model inspection and exact-ID prediction without a repository-source mount. It used a separately supplied locked R runtime. Test-environment details and limitations are recorded in the [roadmap](../docs/implementation-roadmap.md). Release CI requires installed Windows MSI/NSIS IPC, both binary/Cox CLI workflows, graphics and real PSOCK/taskkill cancellation. macOS uses the native tauri-driver route, which has no WKWebView driver: its gate covers bundled R/CLI and app launch, not native IPC or Intel execution. Unsigned Windows and unnotarized macOS packages retain SmartScreen/Gatekeeper restrictions; no signing credentials are bundled.
