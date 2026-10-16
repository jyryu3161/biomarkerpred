# BioMarkerPred contributor and CLI instructions

## Working agreement

- Implement the platform roadmap in `docs/implementation-roadmap.md` sequentially. Delegate each implementation stage to one subagent, then have the primary session review the code and run relevant checks before advancing. Do not have agents edit the same files concurrently.
- Preserve existing user work. Routine local implementation does not authorize publishing. The current user explicitly authorized the v0.5.0 remote CI/release/Docker deployment; the primary session performs remote mutations after review. Never upload patient data.
- Scientific correctness is part of the interface contract: preprocessing, gene selection, model tuning, and threshold fitting must never use an outer assessment cohort or an external validation cohort.
- Keep GUI and CLI on the same R engine and configuration schema. An option is complete only when its input, execution, saved metadata and result display work together.
- Never report an analysis as successful merely because a process exited with code zero. Verify the run manifest and required artifacts. Missing metrics retain explicit reasons.

## Repository map

- `R/`, `config/schema.json`, `BiomarkerCLI.R`: executable shared research engine, authoritative defaults and CLI.
- `gui/src/`: React/TypeScript interface; `gui/src-tauri/src/`: Rust orchestration, resource resolution and process management.
- `Main_Binary.R`, `Main_Survival.R`, `Predict_New.R`, `ORA_PPI_Analysis.R`: compatibility wrappers; `Save_Model.R` validates/copies complete models.
- `pixi.toml`/`pixi.lock`: exact core runtime, Linux x86_64 only. `Dockerfile`: the same lock in a pinned production image.
- `scripts/ci_scientific.sh`, `scripts/ci_browser.py`, `tests/`: executable acceptance. Browser IPC simulation and actual native execution are separate checks.

## CLI operation

Read `README.md`, the requested configuration and input headers before an analysis. Use synthetic fixtures for development. Run `./install.sh` with Pixi 0.71.2 to install the locked Linux runtime; this runs doctor and fails honestly. Other platforms require a verified manual local R installation or the supported Docker engine. Do not silently mutate packages or regenerate locks to bypass a failure.

Use `./run_analysis.sh --help` and `./run_analysis.sh doctor --json` to inspect commands/readiness. Set `BMP_RSCRIPT` to one Rscript executable path if needed. The launcher preserves the caller's working directory. Config paths normally resolve relative to the config directory; an explicit `workdir` changes that base. Never infer outcome coding, grouping, units or normalization from filenames.

Run `validate --config CONFIG --json` before `analyze --config CONFIG --json`. Preserve the QC result and exact normalized configuration, including failed-but-editable QC. The schema and examples (`config/example_analysis.yaml`, `config/example_survival.yaml`) define current options. Progress is `BMP_EVENT:` JSON on stderr; `--json` stdout is one result object. Commands also include `binary`, `survival`, `predict`, `evaluate`, `runs`, `compare`, `resume`, `report`, `ora`, `doctor`, `version` and `help`.

Read each returned `run_dir`, `run_id` and `paths` object. Outputs are unique `output_dir/runs/RUN_ID/`; `latest.json` is only a pointer. Inspect manifest status, required SHA-verified artifacts and metric warnings. Report the run ID, actual directory, validation method, cohort sizes, failed folds/warnings, model path and report path. Treat external results separately from development; never tune on the external cohort. Bootstrap intervals are conditional on saved predictions and exclude full model-selection uncertainty.

`predict --model MODEL --data CSV --output CSV` applies a frozen artifact. `evaluate` creates its own run with outcomes, metrics and required-predictor drift. Survival scoring requires `--time-unit` to match the saved units. Valid null models are supported; old incomplete model files require retraining. Do not invent encoders, thresholds or survival baselines. Report unavailable discrimination or censoring-support metrics as unavailable, never zero.

`report --run RUN_DIR` regenerates derived reports without fitting. `resume --run RUN_DIR` checks input/config/engine/runtime/evidence compatibility and hashes; changed code or evidence generally requires a new run. A foreign-context lock may be recovered with `--recover-lock TOKEN` only after verifying its owner has stopped. Never displace a live process or interpret an unverified cancellation as completed.

For exploratory pathways, use `ora --run DEVELOPMENT_RUN --gmt ANNOTATION.gmt --annotation-version VERSION --network none --json`. The source must be a verified, completed development run. A derivative preserves source models/predictions, measured and mapped backgrounds, full development ranks and original/expanded sets. `--network string --add-nodes N` explicitly requests public identifiers/expansion; zero is default. Unmeasured expansion never enters the measured ORA background/query. Native GO packages are optional; KEGG/Reactome use versioned local annotation exports. Requested network/evidence failure means visible partial status and nonzero exit.

Use `fetch_opentargets_genes.py search --query TEXT` then `fetch --disease-id ID --output-dir DIRECTORY` for immutable disease-association snapshots. Exact gene symbols or Ensembl IDs are matched; no case/version guessing. Do not replace disease-association scores with drug-target membership. Legacy drug-score, Streamlit and train-AUC/coexpression entrypoints are retired with migration messages.

## Verification

- Core: `./scripts/ci_scientific.sh` uses root `.pixi/envs/default/bin/Rscript` (or `BMP_RSCRIPT`) for all R acceptance and independent CLI/helper processes. `python tests/test_documented_workflow.py --rscript "$PWD/.pixi/envs/default/bin/Rscript"` checks README examples.
- Frontend: `cd gui && npm ci && npm test && npm run lint && npm run build` with Node 22.18.0/npm 11.9.0.
- Rust: `cd gui/src-tauri && cargo fmt --check && cargo test --locked` with Rust 1.90.0 and Tauri libraries. Set `BMP_TEST_RSCRIPT`, `BMP_TEST_ENGINE_ROOT`, `BMP_TEST_DOCKER_IMAGE` and `BMP_TEST_DOCKER_PATH` to exercise real R/PSOCK and Docker; ungated unit tests alone do not establish these behaviors.
- Image: build `biomarkerpred-engine:local`, then `python tests/test_docker_image.py --image biomarkerpred-engine:local`. This mounts synthetic data only and verifies installed code hashes, null models, scoring, resume and Unicode reports.
- Browser: install `tests/requirements-browser.txt` and Chromium, build `gui/dist`, then run `scripts/ci_browser.py --rscript PATH --output NEW_DIRECTORY`. It creates fresh fixtures; IPC jobs/dialogs are simulated. `tests/test_native_desktop.py` separately checks real installed Linux IPC.
- Resource staging: `python tests/test_engine_resources.py --engine-root gui/src-tauri/resources/engine --rscript PATH` after a Rust build.

Verify serialization/single-batch invariance, grouped holdout isolation, failed-run semantics, exact evidence identity and resume compatibility with executable checks. Record unavailable runtimes and unverified OS behavior honestly. A passing build is not scientific validation. Do not rerun unrelated expensive checks after a narrow non-code edit; choose checks based on changed behavior.

## Authorized release verification

Synchronize an explicit application version with `scripts/sync-version.sh v0.5.0`, then `node scripts/check_release_version.cjs v0.5.0`. Scientific engine/interface/model versions are independent. The release workflow uses one source SHA, never moves an existing tag, and defaults manual dispatch to `publish=false`. Publication requires the scientific CI, every desktop platform gate and installed-image checks. A published version is immutable; use a new version for changed artifacts. Docker Hub remains `jyryu3161/biomarkerpred`; launchers/default settings select the versioned published image and pull only explicitly.

Windows must pass actual installed MSI and NSIS IPC, binary/Cox R workflows, Cairo graphics and PSOCK/taskkill termination; a successful build alone is insufficient. macOS currently verifies Apple Silicon R/Rust, the mounted DMG's engine and app launch; native WebDriver IPC/Intel execution are not claimed. Native package hashes live in `tests/runtime/native-r-lock.json`, separate from Linux's conda lock. Use only synthetic data on hosted runners. Release notes/checksums record the exact source and registry image digest, signing limitations and observed verification scope.
