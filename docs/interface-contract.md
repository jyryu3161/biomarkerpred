# Engine, CLI and desktop integration contract

This is the implementation contract for stages 3–6. Update it to describe the final working interfaces as integration proceeds; it is not a statement that pending commands already work.

## Commands and machine output

`BiomarkerCLI.R` accepts both `--key=value` and `--key value`. Paths containing spaces are ordinary argument values, never executable shell strings. `--help` documents required options and exit behavior. Unknown flags fail with an actionable message.

- `validate --config PATH [--json]`: normalize config and inspect input without creating a modeling run. Return normalized config, QC and explicit errors. Failed QC must be consumable by the GUI, including errors and warnings.
- `analyze --config PATH [--json]`: create a unique run, execute the shared engine, generate metrics/reports, validate artifacts, then mark completion. `binary` and `survival` supply the analysis type for legacy two-section configs.
- `predict --model PATH --data PATH --output PATH [--json]`: validate a frozen model and input columns; create predictions without requiring outcomes. Preserve sample/group strings. A `.csv` output is a file; a directory output receives `predictions.csv` for compatibility with `Predict_New.R`. Report actual output paths and model hash.
- `evaluate --model PATH --data PATH --output PATH [--json]`: score an independent cohort without modifying the model, thresholds or encoders. Require the model's declared outcome/time/event roles. Record model and cohort hashes, metrics, drift diagnostics and support/overlap warnings. Do not require enough external rows to perform development nested CV.
- `runs --output PATH [--json]`: read persistent manifests, including failed, partial and cancelled runs.
- `compare --runs PATH1,PATH2 [--output PATH] [--json]`: compare compatible recorded metrics, panels, validation methods and cohort identities. Also accept repeated `--run PATH1 --run PATH2` so comma-containing paths are unambiguous. Label incompatible cohort/validation comparisons; do not fabricate a paired significance test.
- `resume --run PATH [--json]`: verify unchanged config/data/engine/environment and checkpoint hashes, then continue incomplete work. Completed verified runs may be returned without re-fitting.
- `report --run PATH [--json]`: regenerate reports from saved predictions, model, metrics and run metadata. Never re-fit for a figure.
- `ora --run PATH [...] [--json]`: perform pathway/network analysis from the recorded measured/eligible universe and ranked training statistics, retaining original and expanded genes separately. Support local term mappings for offline reproducible checks.
- `doctor [--json]` and `--version`: expose the engine/interface/config/model versions, R version and required core package availability. Desktop runtime checks must distinguish an executable R or existing Docker image from an environment that can actually run this engine. Optional pathway packages must not block core analysis.

With `--json`, stdout contains exactly one JSON result. Human logs and warnings use stderr. Progress is a separate stderr line prefixed `BMP_EVENT:` with a JSON object: `event`, `run_id`, `run_dir`, `status`, `current`, `total`, `message`, and relevant artifact/error fields. Optional fields may be absent. Never infer success from a human log string. Exit zero means the requested operation and its required artifact verification succeeded.

## Results and model semantics

- The run manifest is authoritative. Desktop results open the actual unique `run_dir` returned by the engine, not the parent configured output directory or a previous `latest.json` value.
- Primary assessment predictions represent the inner-selected modeling procedure. Fixed algorithm/feature-set/panel arms are descriptive comparisons on the same outer folds. Display the distinction in metric tables, exports and model metadata.
- Panel size is a maximum gene count; clinical covariates and actual fitted gene count are separate fields.
- Unavailable estimates are JSON `null` with a reason, never zero. Record the number of patients, rows, events, folds and successful bootstrap resamples supporting estimates.
- Preserve sample IDs as strings. Only declared numeric result columns are parsed as numbers in Rust/TypeScript.
- Model metadata describes a frozen final full-development-data fit. Its development validation evaluates a procedure, not a new independent test of that exact fit. External evaluation is displayed separately.
- Predictions store their fold, repeat, patient/group, primary/comparison role and frozen threshold. Survival assessment has the corresponding training censoring curve and follow-up support, allowing figures and metrics to reuse predictions without access to a fitted native R object.

## Desktop orchestration

- Local and Docker backends call the same CLI and configuration schema. Ship all R modules and the schema with the desktop resources/container; development bind mounts must include the entire engine.
- A shared runner handles validate/analyze/predict/evaluate/history/compare/resume/report/ora. Do not add another independent configuration transformer for each operation.
- Register process state atomically before allowing another run. Completion events contain the actual operation/run/output paths and verified status. Read failures do not become successful empty results.
- Cancellation reaches the process group, worker processes and the named Docker container. Mark cancellation in the active manifest only after the process has stopped; stale completion events must not overwrite the cancelled state or another run.
- Local runtime availability is sufficient for local mode. Docker availability is sufficient only when the requested compatible engine image is available. Runtime version and image identity appear in provenance.
- Runtime checks invoke the packaged CLI `doctor --json`, honor executable/image overrides and check interface/config/model compatibility. Optional pathway annotation packages are separate from core readiness. Resolve packaged resources independently of the user's working directory; never require the source checkout for an installed application.
- Docker arguments use structured process arguments and explicit bind mounts. Paths from returned summaries/events must resolve to actual host files, including spaces and separate input/model/output locations. Resume must reconstruct the original input/evidence mounts and retain their hashes; a container path cannot be passed directly to a host file reader. Record the inspected image identity, not merely a mutable tag.
- Preserve R path semantics when staging configuration: explicit relative `workdir` is resolved from the original invocation directory; without `workdir`, a file configuration resolves paths from its original directory. Shared-schema default output paths also need writable Docker mounts. Temporary configuration mounts must not enter persisted resume requirements. YAML scalar interpretation must not change silently between direct CLI and desktop execution.
- A cancellation token identifies one job throughout spawn, process registration, output draining and completion. On Unix stop the whole process group, including PSOCK R workers; on Windows stop the process tree; for Docker stop the named container and wait for termination. Coordinate with `R/locks.R`: release/recover only the terminated owner's lock, and preserve completed checkpoints. Reject incompatible resume explicitly rather than silently restarting with different settings.
- Deadlines and cancellation remain active while draining child output, including after the process leader exits. An orphaned worker holding a pipe cannot hang the interface indefinitely. Docker creation and startup must be separately controlled so cancellation cannot leave a container starting after cleanup. Unknown termination preserves the lock and a recoverable job state.
- Configuration controls cover patient grouping, explicit outcome coding/display names, time units/horizon, clinical columns, nested folds/repeats/seed/workers, algorithms, feature sets, panels and feature filtering. Defaults come from the shared schema.
- QC precedes modeling and displays exclusions, missingness, constant columns, count/support problems and warnings. Client checks improve interaction; R remains authoritative.
- Persistent history can select, compare and resume runs. Prediction/evaluation show model role/requirements and fixed thresholds. Reports and figures open/export from the selected run. Evidence inspection joins gene selection frequency, coefficient direction, external evidence, pathway membership and interactive network edges.
- CSV preview/results use a real quoted-field parser, preserving leading-zero/long identifiers and embedded newlines. Empty null models remain valid models. Missing metrics remain nullable; an old model lacking encoders/baselines receives an actionable migration error. Saving a model to its existing source path must not truncate it.
- The existing Streamlit entrypoint must either consume the same CLI/manifest artifacts or give an explicit migration path before execution. Its old exit-code-only success check, legacy progress parser and hardcoded AUC filenames cannot remain an apparently working alternative workflow.

Desktop review combines component interaction tests, Rust command/process tests and local browser inspection with synthetic IPC responses. The primary session has a working headless Chromium/Playwright runtime; a browser preview is not evidence that a packaged macOS/Windows desktop application was executed. Cancellation additionally requires an actual child/worker process test, and Docker behavior must be checked against a compatible local image before claiming it works.

`tests/fixtures/worker_process_tree.R MARKER_DIRECTORY` starts a real R parent and two local PSOCK workers, publishing their PIDs and a readiness marker. Use it for process-group cancellation acceptance and verify all workers have stopped. The local Rust validation container can execute the pinned R environment when the repository is also mounted at its original absolute path, preserving the environment prefix; this permits real R/Rust integration tests without a host Cargo installation.

## Scientific review reminders

Do not pool uncentered Cox linear predictors from independently fitted folds as a single concordance score. Either use comparable absolute horizon probabilities or aggregate within-fold comparable pairs, describing the method. Censoring before the horizon is not an observed non-event. Group bootstrap uncertainty must keep all rows/repeats from a patient together. Document whether point estimates weight samples or patients. Training-only plots must be labeled exploratory and kept distinct from assessment plots.

HTML and PDF reports share run identity, cohorts/exclusions, validation/selection procedure, comparisons, performance with uncertainty and unavailable reasons, panels/stability, external evidence limits and provenance. Reporting follows relevant TRIPOD+AI items without claiming guideline certification.

## Report and CLI review details

- `tests/test_cli_review.py` is an independent end-to-end review prepared for stage 3c. It invokes the real CLI without a shell from a different working directory, checks both option syntaxes, machine-readable failures, binary/survival completion, PDF text identity, artifact hashes, report/resume invariance, external single-class/no-event cohorts, persistent history and legacy entrypoints. It must pass before new commands are described as available.
- Prediction output must not overwrite its input data or source model, including aliases of the same path. Report generation verifies the source artifacts before writing derived files, preserves model/prediction bytes and maintains completed-run artifact hashes. A failed/partial run cannot become completed merely because a report was generated.
- Completed resume verifies saved artifacts before returning without fitting. An incomplete analysis resumes compatible fold/final checkpoints. External evaluation resume needs its own frozen-model/input compatibility path and must never enter the development fitting engine.
- The comparison response includes the runs even when they differ in analysis type, cohort, outcome coding, time units/horizon or validation method. Explain which quantities are comparable; incompatible rows must not be ranked together or assigned a paired significance result.
- A probability waterfall uses stored assessment probabilities and per-row frozen thresholds. A single line at 0.5 is misleading when fold thresholds differ. Survival probability plots use the declared horizon; raw fold-specific Cox linear predictors must not be presented as a common absolute risk scale.
- HTML escapes user-provided labels, gene names, filenames and metadata. PDF text remains searchable and includes the complete run ID. Plot failures or unavailable metrics are explicit, and required-report failures prevent a success status.

## Pathway/evidence integration details

- Retain the measured assay universe, configured eligible universe, any full-development QC restriction and annotation-mapped universe separately, with counts, hashes and exclusion reasons. A selected panel is never its own enrichment background. The chosen background must be explicitly named in each result.
- Original model genes and STRING-expanded genes are distinct sets. Network expansion does not expand the measured assay background; unmeasured interactors can appear in the graph but require visible membership flags and exclusions from assay-background ORA.
- Local GMT/term mappings provide an offline reproducible path. Identifier mapping reports unmapped, ambiguous and collapsed identifiers; changes to the statistical unit must not silently duplicate genes. Database/annotation version or local file hash is recorded.
- Ranked GSEA uses the recorded full eligible development statistic, including genes outside the selected signature. Non-estimable ranks and tied/duplicate identifiers have explicit policies. Save ES, normalized score, permutation method/count/seed, p-value adjustment and leading-edge genes. This is exploratory development evidence, separate from held-out prediction performance.
- STRING tabular/JSON requests explicitly set `add_nodes` (including zero), map identifiers first, identify species and record source version, parameters and response hashes. Failed network retrieval is visible; an unavailable network cannot be presented as evidence of no interactions.
- Gene evidence records join selection frequency/direction, final coefficients, rank statistic, supplied Open Targets evidence, pathway membership and graph role. Missing external evidence stays missing, not a zero association score. Interactive graph selection/filtering/search and detail links consume these saved records without changing the fitted model.
