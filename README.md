# BioMarkerPred

BioMarkerPred fits and evaluates small biomarker panels for binary outcomes and censored survival outcomes. The React/Tauri desktop application and command line use the same R engine, configuration schema and saved run artifacts. This is research software; development performance does not establish clinical utility.

## Reproducible runtime

The reviewed core is **R 4.4.3** with yaml 2.3.12, jsonlite 1.9.1, digest 0.6.39, survival 3.8.12, glmnet 4.1.10 and pROC 1.18.5. [pixi.lock](pixi.lock) locks the complete conda dependency graph. Core plots use R's Cairo graphics; no package installation occurs during analysis.

| Environment | Current support and verification |
| --- | --- |
| Linux x86_64 | Locked Pixi runtime; engine, CLI, browser and Rust/R/Docker acceptance; installed `.deb` tested through actual Tauri IPC under Xvfb |
| Docker `linux/amd64` | Production image built from pinned base digests, Debian package snapshot and the same R lock; CJK fonts included |
| Other local R installations | Configure an Rscript executable and run `doctor`; package/graphics compatibility must be checked locally |
| Windows x64 | Release CI installs MSI and EXE separately, then requires actual native IPC, R binary/Cox workflows, Cairo reports and PSOCK/taskkill verification; consult the published release evidence for the executed result |
| macOS universal desktop | Release CI runs R/Rust on Apple Silicon, mounts the DMG, verifies the bundled engine and app launch; native WebDriver IPC and Intel execution are not verified by this route |
| ARM Docker | No native ARM engine lock/image supplied; any amd64 emulation requires separate verification |

Install **Pixi 0.71.2** from its [versioned release](https://github.com/prefix-dev/pixi/releases/tag/v0.71.2), then run on Linux x86_64:

```bash
./install.sh
./run_analysis.sh doctor --json
./run_analysis.sh --help
```

`install.sh` uses `pixi install --locked`, runs the core/graphics doctor, and fails if either step fails. It does not run an unpinned installer or mutate CRAN packages. Set `BMP_PIXI=/path/to/pixi` if necessary. The doctor also describes optional pathway capabilities: missing native GO databases do not disable the offline GMT/term-map workflow.

`run_analysis.sh` preserves the caller's working directory. It uses `BMP_RSCRIPT` when supplied, then an Rscript on PATH, then the root `.pixi` environment, then a locked Pixi installation. `BMP_RSCRIPT` is one executable path, not a shell command. A manually provisioned R runtime needs the listed packages and `capabilities(c("cairo", "png", "tiff"))` all true. Install a suitable Unicode font such as Noto CJK when reports contain Korean/CJK text.

## CLI: validate, develop and freeze

Run these examples from the repository root. They use only the synthetic test fixtures. [Binary](config/example_analysis.yaml) and [survival](config/example_survival.yaml) YAML examples explicitly set patient groups; survival also sets years and a three-year horizon. Relative paths resolve against the configuration directory unless an explicit `workdir` is supplied. CSV headers and IDs are preserved, including spaces, commas, leading zeros and long numeric-looking identifiers.

```bash
mkdir -p results/tutorial
./run_analysis.sh validate --config config/example_analysis.yaml --json > results/tutorial/binary-qc.json
./run_analysis.sh analyze --config config/example_analysis.yaml --json > results/tutorial/binary-run.json
./run_analysis.sh validate --config config/example_survival.yaml --json > results/tutorial/survival-qc.json
./run_analysis.sh analyze --config config/example_survival.yaml --json > results/tutorial/survival-run.json
```

Inspect QC errors/warnings before fitting. The JSON QC result includes the normalized configuration even when data QC fails after valid parsing. Failed commands exit nonzero. Progress is emitted as `BMP_EVENT:` JSON on stderr; `--json` stdout contains exactly one result object. The examples use 20 bootstrap samples for a short demonstration, not a final uncertainty budget.

Each analysis creates a new `output_dir/runs/RUN_ID/`. Read its actual path from the returned JSON rather than guessing a timestamp or reusing a fixed filename:

```bash
RUN_DIR=$(python -c 'import json; print(json.load(open("results/tutorial/binary-run.json"))["run_dir"])')
MODEL=$(python -c 'import json; print(json.load(open("results/tutorial/binary-run.json"))["paths"]["model"])')
SURV_MODEL=$(python -c 'import json; print(json.load(open("results/tutorial/survival-run.json"))["paths"]["model"])')
./run_analysis.sh runs --output results/examples/binary --json
./run_analysis.sh report --run "$RUN_DIR" --json
./run_analysis.sh resume --run "$RUN_DIR" --json
```

A successful process alone is insufficient: inspect `manifest.json`, its status and required artifact hashes. `latest.json` is a pointer. Failed/partial/cancelled runs remain inspectable. Resume checks input, configuration, engine, runtime and artifacts; changing code or evidence requires a new run. Never displace a live lock. Recover a foreign-context lock with `--recover-lock TOKEN` only after confirming its owner has stopped.

## Frozen prediction and external evaluation

Prediction applies the saved recipe, coefficients and threshold without fitting. A valid null model needs identifiers but no predictor columns. A non-null model requires its saved predictor columns and categorical levels. Survival scoring requires the training time unit; there is no implicit conversion.

```bash
./run_analysis.sh predict --model "$MODEL" --data tests/fixtures/binary.csv --output results/tutorial/predictions.csv --json
./run_analysis.sh predict --model "$SURV_MODEL" --data tests/fixtures/survival.csv --time-unit years --output results/tutorial/survival-predictions.csv --json
./run_analysis.sh evaluate --model "$MODEL" --data tests/fixtures/binary.csv --output results/tutorial/evaluation --bootstrap-samples 20 --json > results/tutorial/evaluation-run.json
EVAL_DIR=$(python -c 'import json; print(json.load(open("results/tutorial/evaluation-run.json"))["run_dir"])')
./run_analysis.sh compare --run "$RUN_DIR" --run "$EVAL_DIR" --json
```

The evaluation command above deliberately reuses synthetic development data to demonstrate the overlap diagnostic; it is **not independent external validation**. For research, supply a separately collected cohort with compatible measurement/preprocessing semantics. Evaluation keeps the model bytes unchanged, saves required-predictor distribution comparisons and cohort overlap diagnostics, and reports missing/non-estimable metrics with reasons. Drift covers predictors retained by the frozen model, not the entire assay. Comparisons identify incompatible outcome, cohort or evaluation settings rather than producing one misleading leaderboard.

## What the engine estimates

- Patient-grouped, stratified outer validation isolates assessment cohorts. Inner validation selects the model, feature set, panel size and tuning parameters. Imputation, scaling, categorical encoding, gene screening and binary/risk thresholds are learned only from the relevant training partition.
- Clinical-only, genes-only and combined feature sets use common outer folds. Stepwise logistic/Cox and elastic-net logistic/Cox arms are compared alongside the adaptive inner-selected workflow. The final model is refitted on the development cohort after validation.
- Selection policy **v2** performs a full training-only prescreen, then a bounded stability-bootstrap candidate pool (default maximum 200), retaining the full eligible multiplicity count. It may select different panels than the retired policy. Partition screening artifacts, outer-fold selection frequencies, direction consistency and panel overlap are retained. Workers are bounded and seeded resampling is deterministic.
- Binary results include ROC AUC, average precision (PR-AUC), Brier/log loss, frozen-threshold sensitivity/specificity, calibration and decision curves. Survival includes within-fold concordance, IPCW time-dependent discrimination/Brier, fixed-horizon survival probabilities, calibration and KM summaries, with censoring-support limits exposed.
- Bootstrap intervals resample patients/groups conditional on the stored predictions. They do **not** measure uncertainty from rerunning the full model-selection process. Repeated outer folds are dependent; unavailable metrics or failed resamples are shown explicitly.

The versioned `.bmpmodel` JSON stores required preprocessing/encoders, outcome codes and display labels, coefficients and thresholds. Cox models additionally store baseline hazard, training censoring information, time unit and horizon. Predictions are invariant to single-versus-batch scoring and serialization in the executable acceptance suites.

## Exploratory pathways and gene evidence

A pathway request starts from a verified, completed development run and writes a separate derivative run. It preserves the source model/predictions. Offline annotations can be a versioned GMT or term-to-gene CSV; an optional identifier mapping CSV uses exact `source_id,target_id` columns.

```bash
./run_analysis.sh ora --run "$RUN_DIR" --gmt config/example_pathways.gmt --annotation-version synthetic-v1 --network none --min-size 1 --permutations 19 --json
# For an actual study, supply its versioned annotation export and adequate permutation budget:
# ./run_analysis.sh ora --run "$RUN_DIR" --gmt study.gmt --annotation-version RELEASE --network string --add-nodes 0 --json
```

ORA uses the measured, eligible, QC-passing, annotation-mapped development universe, with exact hypergeometric tests and BH adjustment. Original and expanded sets are separate. Added, unmeasured STRING genes remain visible in the network and are excluded from the measured enrichment query/background. Mapping coverage, ambiguous/unmapped IDs, collapsed mappings, requests and response hashes are retained.

Ranked GSEA uses all finite QC-eligible development ranks, weighted running-sum ES, competitive gene-label permutations and sign-specific NES. It is not ORA on selected genes. BH-adjusted permutation p-values are not GSEA FDR q-values. Insufficient support, constant ranks and full-universe terms retain unavailable reasons.

STRING 12.5 is an explicitly requested **functional association** network, not proof of physical binding or causality. Default expansion is zero. Network requests send public gene identifiers, never patient rows. Native GO requires separately supplied annotation packages; KEGG/Reactome use versioned local exports, with no silent online provider. Requested network/evidence failures produce visible partial results and a nonzero exit.

Open Targets disease evidence is available in desktop Settings/setup and through Python's standard-library CLI:

```bash
python fetch_opentargets_genes.py search --query 'breast carcinoma'
# Select a current ontology ID from the search result, then:
python fetch_opentargets_genes.py fetch --disease-id MONDO_0004989 --output-dir evidence/opentargets
python generate_configs.py --help
python generate_opentargets_configs.py --help
```

Fetches create unique CSV/metadata/request/response snapshots and reject inconsistent/incomplete pagination. API release is recorded as unknown when not supplied. Evidence filtering matches exact gene symbols or Ensembl IDs; it does not guess case or strip versions. Input and evidence identities are bound across QC, fitting and completion. Disease-association scores are not evidence of drug-response prediction. In the gene explorer, inspect selection stability, coefficient direction, evidence context, pathway membership and each original gene mapped to a shared network node.

## Reports and desktop application

Every completed development/evaluation run includes an HTML report and searchable Unicode PDF, with methods, QC/exclusions, validation, metrics, provenance and limitations. Figures are saved as SVG, PDF and **150 dpi TIFF**. Reports reuse saved predictions; `report` does not refit. Research-report contents are informed by TRIPOD+AI items, not a claim of formal compliance.

The desktop provides setup/import/QC, persistent run history/comparison, frozen prediction/evaluation, pathways/evidence and runtime settings. Choose **local R** or **Docker** in Settings; local R does not require Docker. A global job state tracks the actual run directory and prevents conflicting mutations. Cancellation stays active if termination cannot be verified, with a visible retry path. See [desktop instructions](gui/README.md) and the [IPC contract](docs/desktop-api.md).

For source development, use Node **22.18.0**, npm **11.9.0**, Rust **1.90.0** and platform Tauri system dependencies:

```bash
./run_gui.sh
```

The installed desktop bundles the engine code/schema, not an R runtime. Select a compatible local Rscript or the published `jyryu3161/biomarkerpred:v0.5.0` image. Docker mode requires Docker Desktop/Engine with Linux containers. In Settings, choose Docker, use **Pull configured image**, save settings, then run the doctor. Pulling is explicit; existing settings are preserved. Bundled engine resolution is independent of the working directory.

## Docker engine

```bash
docker pull jyryu3161/biomarkerpred:v0.5.0
docker run --rm jyryu3161/biomarkerpred:v0.5.0 doctor --json
./run_docker.sh validate --config config/test_docker.yaml --json
./run_docker.sh analyze --config config/test_docker.yaml --json
```

For local engine development, build `docker build --platform linux/amd64 -t biomarkerpred-engine:local .` and set `BMP_DOCKER_IMAGE=biomarkerpred-engine:local`. On Windows use `run_docker.bat` with the same commands after an explicit pull.

The launcher mounts its caller's working directory at `/work`; paths referenced by configs must be inside that mounted directory. Run the examples from the repository root. Additional data volumes require explicit Docker mounts or desktop path configuration. The build context is an allowlist of engine code, schema, lockfiles and entrypoint; no CSV, patient data or result directories are copied into the image. No registry push occurs in these commands. GUI execution and `run_docker.sh` record the inspected immutable image ID; direct `docker run` calls may set `BMP_IMAGE_DIGEST` explicitly for the same provenance.

## Migration and verification

`Main_Binary.R`, `Main_Survival.R`, `Predict_New.R` and `ORA_PPI_Analysis.R` forward to the shared engine. Older incomplete model files require retraining; missing encoders, thresholds or survival baselines cannot be reconstructed safely. Legacy Streamlit, train-AUC monoliths, coexpression analysis and drug-score fetching are retired with explicit migration messages. Old split/seed-frequency YAML settings are normalized with warnings where meaningful; review the normalized configuration. Do not compare obsolete best-seed/train-AUC reports with nested validation.

```bash
./scripts/ci_scientific.sh
python tests/test_documented_workflow.py --rscript "$PWD/.pixi/envs/default/bin/Rscript"
(cd gui && npm ci && npm test && npm run lint && npm run build)
# From the repository root, after building the production image:
python tests/test_docker_image.py --image biomarkerpred-engine:local
# Optional browser acceptance, after pip install -r tests/requirements-browser.txt
# and python -m playwright install chromium:
python scripts/ci_browser.py --rscript "$PWD/.pixi/envs/default/bin/Rscript" --output /tmp/biomarkerpred-browser-review
```

Rust checks run in `gui/src-tauri` with `cargo test --locked`. Set `BMP_TEST_RSCRIPT`, `BMP_TEST_ENGINE_ROOT`, `BMP_TEST_DOCKER_IMAGE` and `BMP_TEST_DOCKER_PATH` to enable real R/PSOCK and Docker gates; CI sets all four. [CI](.github/workflows/ci.yml) runs scientific/CLI/helper, frontend, installed-image, resource and browser contracts. Browser tests simulate desktop IPC and do not establish native packaging or OS behavior. [Release CI](.github/workflows/release.yml) builds MSI/EXE, universal macOS DMG/app archives and Linux deb/rpm/AppImage. A manual dispatch defaults to verification only; `publish=true` or a version-tag push publishes only after same-source scientific, OS and image checks pass. Existing published versions and moved tags are rejected. Release assets include checksums, source, installed-platform evidence and notes with the source SHA and image digest.

[AGENTS.md](AGENTS.md), [CLAUDE.md](CLAUDE.md), the [roadmap/review log](docs/implementation-roadmap.md) and [scientific acceptance contract](tests/SCIENTIFIC_ACCEPTANCE.md) describe the required contributor workflow and current verification evidence.

## Installed Windows and macOS runtimes

Download installers from the project's GitHub Releases and verify `SHA256SUMS`. Windows MSI and EXE install the same app; choose one. This release has no commercial signing certificate. Windows SmartScreen may show an unknown-publisher prompt, and macOS downloads are not notarized and may be blocked by Gatekeeper. Follow your organization's software approval policy; do not disable system-wide security controls. The release notes distinguish actual native tests from build-only coverage.

For local R on Windows x64 or Apple Silicon, install official R **4.4.3** first. The source release includes a separate hash-locked native binary package manifest and installer (Python 3.12.10 used by CI):

```powershell
# Windows PowerShell, from the extracted source directory:
python scripts/provision_native_r.py --rscript "C:/Program Files/R/R-4.4.3/bin/Rscript.exe" --library "$env:LOCALAPPDATA/BioMarkerPred/R-library" --evidence native-runtime.json
[Environment]::SetEnvironmentVariable("R_LIBS_USER", "$env:LOCALAPPDATA/BioMarkerPred/R-library", "User")
# Restart the desktop so it inherits R_LIBS_USER, then select the Rscript path in Settings.
```

On Apple Silicon, install [XQuartz 2.8.6](https://www.xquartz.org/releases/XQuartz-2.8.6.html) before provisioning R packages, then restart R and the desktop. Official R's Cairo report devices need its `/opt/X11` libraries even for file exports without an X11 window. Release CI checks the official package SHA-256 `9ac35a505095bfbd3009c3b4772f0c6421e2f79c4210ab908459270d1c447909` before installing. `doctor --json` tests actual SVG, Cairo PDF, PNG and TIFF exports and reports backend errors; a build's graphics capability flags alone are insufficient.

The equivalent native package command uses the installed `Rscript` and a writable library, then launches the app with `R_LIBS_USER` pointing to that library. The native package lock currently verifies yaml 2.3.10, jsonlite 1.9.1, digest 0.6.37, survival 3.8.3, glmnet 4.1.8 and pROC 1.18.5, plus exact transitive binary hashes. It is separate from Linux's conda environment. Runtime versions are retained with each run; cross-runtime resume is not assumed compatible. No native Intel Mac R package lock is claimed. Docker's published Linux amd64 image is an alternative; ARM emulation needs separate verification.
