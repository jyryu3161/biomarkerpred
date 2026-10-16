# Desktop API handoff (stage 5a)

The desktop uses `BiomarkerCLI.R` for every scientific operation. Old `analysis_run`, `prediction_run`, `ora_run`, their events, and `setup_*` commands have been removed. Stage 5b must replace their consumers; a passing Rust build alone does not make the old frontend compatible.

## Requests, settings and schema

```ts
type Backend = 'local' | 'docker'
interface RuntimeSettings {
  backend: Backend
  rPath: string | null
  dockerPath: string | null
  dockerImage: string // default biomarkerpred-engine:local
  outputRoot: string | null
}
interface EngineRequest {
  operation: 'doctor' | 'validate' | 'analyze' | 'predict' | 'evaluate' |
             'runs' | 'compare' | 'resume' | 'report' | 'ora'
  options?: Record<string, string | number | string[]>
  config?: Record<string, unknown> | null
  settings?: RuntimeSettings | null
}
interface EngineResponse {
  success: boolean
  cancelled: boolean
  exitCode: number | null
  result: Record<string, unknown> // original CLI result, including invalid QC/partial status
  verificationError: string | null
  stderrTail: string[]
}
```

- `engine_schema` returns the installed `config/schema.json`. Use `$defs.analysis.properties` defaults, applying `x-survival-default` for survival. Send scientific fields directly as snake_case JSON; there is no separate desktop defaults/knob translator.
- `engine_get_settings` / `engine_save_settings({settings})` persist settings in Tauri's user config directory. An explicit request settings object overrides saved settings for that invocation. `rPath`, `BMP_RSCRIPT`, project Pixi (development only), then PATH determine local R. Local readiness does not depend on Docker.
- `engine_call({request})` accepts `doctor`, `validate`, `runs`, `compare`. Compare uses `options: {run: [path1, path2]}`; paths with commas remain intact. It deliberately disallows comparison output writes. Export the returned JSON separately if wanted.
- `engine_start({request, jobId})` starts `analyze`, `predict`, `evaluate`, `resume`, `report`, `ora`. `jobId` must be a fresh 1–100 character ASCII identifier (`crypto.randomUUID()` works). Reserve/listen before invoking; the job is registered atomically before any runtime starts.
- Inline `config` is supported for analyze/validate only, mutually exclusive with `options.config`. File config uses `options: {config: '/absolute/config.yaml'}`. Local file configurations go unchanged to R, preserving its YAML normalization and original source path. Inline paths should be absolute. Relative local paths follow the invocation working directory; file-relative paths follow R's original config-directory/workdir rules.
- Options use **CLI names** (`time-unit`, `bootstrap-samples`, `annotation-version`, `add-nodes`, `term-map`, `recover-lock`), not camelCase. All arguments are structured process arguments, never shell strings. Unknown options fail.
- `doctor` calls the actual shared CLI and checks interface/config/model version 1, core package availability, Cairo/PNG/TIFF. Optional GO packages are separate. Doctor timeout is 30 seconds; other read-only CLI calls are limited to 120 seconds, with bounded Docker inspection/control calls. Mutation fitting is not time limited.
- `runtime_pull_image({settings})` explicitly pulls the configured image using its configured Docker executable, with a five-minute limit. Run doctor afterwards; image presence is insufficient. Automatic installation into bundled resources was removed. Select a compatible R executable or build/install the pinned engine image described by packaging documentation.

CLI JSON nested inside `result` retains **snake_case** fields, e.g. `run_dir`, `source_run_dir`, `run_id`, `paths.report_html`, `qc`. Invalid QC is a resolved EngineResponse with `success:false`, `result.qc` and `result.error`; do not discard it because exitCode is nonzero. Protocol/runtime launch errors reject engine_call, while background mutations finish with an error response. Analysis success requires exit zero, CLI `ok:true`, completed identity/status, required files and SHA-256 checks, and a valid frozen model. Report-only success preserves the source run's existing status. A cancelled request may retain a CLI completed result if cancellation was accepted after the calculation finished; the wrapper's `cancelled`/`success` flags remain authoritative for the request, and immutable completed artifacts remain intact.

## Events and job recovery

Subscribe once to `engine://event` before starting a job:

```ts
interface EngineEvent {
  jobId: string
  operation: EngineRequest['operation']
  type: 'accepted' | 'started' | 'progress' | 'log' | 'warning' |
        'complete' | 'cancellation_unverified'
  payload: unknown
}
```

`progress.payload` is the original `BMP_EVENT` object (`event`, `type`, `run_dir`, `current`, `total`, `message`, etc.), with container paths mapped to host paths. `log`/`warning` payloads have `message`. `complete.payload` is EngineResponse. Filter every event by the active jobId; never let a delayed event finish another job. Keep a bounded UI log.

`engine_job_status({jobId})` returns `{jobId, operation, phase, lastEvent, response}`. `engine_job_status({jobId:null})` returns the active snapshot or null. Check status after start resolves to recover an event emitted before the invoke promise resolved, and on remount. The registry retains the 32 most recent completed snapshots plus small used-ID tombstones; persistent run history comes from `runs`, not this memory cache.

`engine_cancel({jobId})` requests cancellation and returns a snapshot. Keep the UI busy until completion. Unix cancellation stops the entire process group, including R PSOCK workers; Windows uses process-tree taskkill; Docker uses an owned named container created separately before start, then stop/remove verification. Only the terminated owner's exact lock token/context is archived. Cancellation marks unfinished active run manifests and their still-current latest pointers; ORA modifies its derivative, preserving the completed source manifest.

If termination cannot be confirmed, phase/type is `cancellation_unverified`; the mutation registry remains occupied and locks remain intact. Show the returned diagnostic, including the container name where applicable. Calling cancel again retries termination and cleanup after connectivity/permissions are restored. Do not describe that state as cleanly cancelled or enable another mutation prematurely.

## Results, models and files

- `engine_read_run({runDir})` returns `{run_dir, manifest, artifacts, paths, verification_error, artifact_errors}`. It remains inspectable for failed/partial/tampered runs: available QC/metadata are returned along with integrity errors. It never converts a failed run to completed. `artifacts` keys are file names (`metrics.json`, `graph.json`, `gene_evidence.json`, `stability.csv`, `figures/index.json`, etc.); CSV entries are `{headers, rows, count}`. `paths` maps required relative artifact names to host paths. Display verification errors prominently when interpreting performance.
- `model_load({path})` returns `{path, sha256, model, metrics:null, metrics_reason}`. `model` is the complete frozen version-1 artifact. Requirements are `model.features` plus `sample_id`/`group_column`; outcome/time/event columns are required only for evaluation. Show coding/display labels, `threshold`, `threshold_method`, survival `time_unit`/`horizon`, algorithm, clinical columns and selected genes. Empty features/coefficients are valid null models. Missing performance is null with a reason; it is not zero. Legacy files without frozen encoders/baselines receive a retraining explanation.
- `model_save({sourcePath,destPath})` and `fs_save_file({sourcePath,defaultName})` preserve bytes when destination aliases source (canonical/symlink/hardlink on Unix), otherwise atomically copy.
- `fs_read_csv_header({path})` returns `{path,rowCount,columns,preview}`. `fs_read_csv({path,limit:null})` and `prediction_read_results({outputDir})` return `{headers,rows,count}`. Values remain **strings**, including leading zeros, long IDs, numeric-looking labels and missing empty cells. Parse numerical metric columns explicitly in the view. Real CSV parsing supports BOM, quoted commas/newlines and exact column names.
- `fs_read_text_file`, `fs_read_image` (base64), `fs_list_output_plots`, file/folder pickers and `fs_open_directory({path})` remain available. The latter uses the OS opener for files or directories, so it can open the saved HTML/PDF too. Use saved `figures/index.json` and manifest paths rather than legacy hardcoded AUC filenames.

## Docker and packaging

Docker executes the inspected immutable image ID and records it through `BMP_IMAGE_DIGEST`. Each request uses structured mounts for inputs, models, evidence, output and source runs. Unix paths are mirrored; Windows drive/UNC paths map under `/bmp-host`, then responses/events are translated back. `.desktop-runtime.json` stores non-ephemeral mount mappings next to a run so later resume reconstructs input/evidence mounts. It is separate from frozen scientific config/manifest hashes. Missing original mounts or incompatible engine/runtime provenance fail explicitly. An old published mutable image is not assumed compatible.

Docker YAML parsing rejects unquoted ambiguous YAML 1.1/1.2 scalar values (`yes/no/on/off/y/n`): quote such text or use JSON to preserve outcome coding. GUI-generated JSON avoids this ambiguity. Output defaults are read from the shared schema and receive writable mounts.

`build.rs` stages all root `*.R`, every `R/*.R`, and `config/schema.json` into generated `gui/src-tauri/resources/engine`; Tauri bundles that tree as `resource_dir/engine`. Release engine resolution uses this bundle independently of cwd; debug builds can use the checkout. Runtime/settings/cache writes never target bundled resources.

## Open Targets evidence

Existing search/fetch/list/count commands remain, but fetch/list now include immutable snapshot identity and provenance:

- `opentargets_fetch_genes({efoId,diseaseName})` returns `{cache_key,file_path,gene_count,provenance}`.
- `opentargets_list_cached` rows include `{cache_key,efo_id,disease_name,gene_count,fetched_at,file_path,provenance}`.
- `opentargets_delete_cached({cacheKey})` deletes one selected snapshot, not all snapshots for a disease.

The historic `efoId`/`efo_id` field accepts any returned ontology ID, including MONDO. Label it “Disease/ontology ID”; do not require an EFO prefix. CSV includes `gene_symbol,score,ensembl_id`. Provenance includes source, API URL, fetch time, disease context, query variables and CSV hash; unknown release remains null. Pass source/disease/EFO/fetch time to configuration evidence fields; do not invent a database version. Repeated fetches publish distinct CSV+metadata directories under the user's `.biomarkerpred/evidence/opentargets`. Partial/inconsistent pagination, duplicate IDs, missing IDs/symbols or invalid scores fail without publishing a partial snapshot. Missing external evidence in saved gene explorer records remains null.

## Validation scope

Rust tests exercise exact direct-CLI normalization/QC parity, real binary/survival null models, development/prediction/external evaluation/history/compare/resume/report/ORA, source-preserving pathway cancellation, actual R parent plus two PSOCK workers, CSV/alias-copy, artifact rejection, process drain timeouts, atomic job cancellation, Docker mount planning/create cancellation, and Open Targets immutable snapshots/protocol validation. Real R tests require `BMP_TEST_RSCRIPT` and optionally `BMP_TEST_ENGINE_ROOT`; real Docker integration is explicitly gated by `BMP_TEST_DOCKER_IMAGE`, optional `BMP_TEST_DOCKER_PATH`, and a daemon-visible TMPDIR. Linux container tests do not establish packaged macOS/Windows execution.
