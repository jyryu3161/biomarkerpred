# Run API: new_run(config,qc), update_manifest(run,status,...),
# resume_run(run_dir,config), list_runs(output_dir). A run is a list containing
# id/run_id, dir/output_dir (the unique run directory), config and manifest.
# All JSON writes use a same-directory temporary file and atomic rename.
bmp_read_json <- function(path) {
  bmp_require("jsonlite")
  if (!file.exists(path)) stop(sprintf("JSON file not found: %s", path), call. = FALSE)
  jsonlite::fromJSON(path, simplifyVector = FALSE)
}

# auto_unbox is convenient for metadata scalars, but public list-valued fields
# must retain [] / [one] shape for GUI consumers and JSON Schema validation.
bmp_json_arrays <- function(value, key = NULL, coerce_key = TRUE) {
  arrays <- c("models", "feature_sets", "panel_sizes", "alpha_grid", "clinical_columns", "features",
    "gene_columns", "include", "exclude", "warnings", "errors", "normalization_warnings", "required_artifacts",
    "missing", "mismatch", "constant_columns", "high_missing_columns", "eligible_genes", "measured_genes", "duplicate_sample_ids")
  sequence <- is.null(value) || is.atomic(value) || (is.list(value) && is.null(names(value)))
  if (coerce_key && !is.null(key) && key %in% arrays && sequence) {
    flat <- unlist(value, use.names = FALSE)
    return(if (!length(flat)) list() else I(flat))
  }
  if (!is.list(value) || is.data.frame(value)) return(value)
  if (is.null(names(value))) return(lapply(value, bmp_json_arrays))
  # Named maps may legitimately use a schema field name as an arbitrary gene,
  # category or arm identifier. Their keys are data, not array declarations.
  literal_maps <- c("models", "predictors", "distribution", "coefficients", "counts",
    "missing_fraction", "clinical_types", "files", "sha256", "dropped")
  for (name in names(value)) value[name] <- list(bmp_json_arrays(value[[name]], name,
    coerce_key = is.null(key) || !key %in% literal_maps))
  value
}

bmp_atomic_json <- function(value, path) {
  bmp_require("jsonlite")
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  temporary <- tempfile(pattern = paste0(".", basename(path), "-"), tmpdir = dirname(path))
  on.exit(unlink(temporary), add = TRUE)
  jsonlite::write_json(bmp_json_arrays(value), temporary, auto_unbox = TRUE, pretty = TRUE,
    null = "null", na = "null", digits = 16, dataframe = "rows")
  if (!file.rename(temporary, path)) stop(sprintf("Unable to atomically write %s.", path), call. = FALSE)
  invisible(path)
}

bmp_sha256 <- function(path) {
  bmp_require("digest")
  if (!file.exists(path)) stop(sprintf("Cannot fingerprint missing file: %s", path), call. = FALSE)
  digest::digest(file = path, algo = "sha256", serialize = FALSE)
}

bmp_canonical <- function(value) {
  if (!is.list(value)) return(value)
  if (!is.null(names(value))) value <- value[order(names(value))]
  lapply(value, bmp_canonical)
}

bmp_hash_object <- function(value) {
  bmp_require("digest")
  bmp_require("jsonlite")
  digest::digest(jsonlite::toJSON(bmp_canonical(value), auto_unbox = TRUE, null = "null", na = "null", digits = 16), algo = "sha256", serialize = FALSE)
}

bmp_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%OS3Z", tz = "UTC")

# Source paths and output locations are provenance, not statistical inputs.
# Derived QC fields are reproducible from the input hash and excluded here.
bmp_semantic_config <- function(config) {
  config <- bmp_load_config(config)
  config[setdiff(names(config), c("output_dir", "workdir", "source_config", "normalization_warnings",
    "gene_columns", "clinical_types", "data_file", "run_id", "run_dir", "resume"))]
}

bmp_evidence_identity <- function(config) {
  if (is.null(config$evidence)) return(NULL)
  value <- config$evidence
  # Supplied metadata cannot override the identity of the actual bytes read.
  value$sha256 <- bmp_sha256(value$gene_file)
  value$bytes <- unname(file.info(value$gene_file)$size)
  value
}

bmp_assert_evidence_identity <- function(expected, phase) {
  if (is.null(expected)) return(invisible(TRUE))
  if (!file.exists(expected$gene_file) || !identical(bmp_sha256(expected$gene_file), expected$sha256)) {
    stop(paste("Development evidence changed", phase,
      "Recorded filtering/results cannot be attributed to changed evidence; retry with an unchanged evidence snapshot."), call. = FALSE)
  }
  invisible(TRUE)
}

bmp_provenance <- function(config) {
  files <- unique(c(list.files(file.path(bmp_repo_root, "R"), pattern = "\\.R$", full.names = TRUE),
    list.files(bmp_repo_root, pattern = "\\.R$", full.names = TRUE), file.path(bmp_repo_root, "config", "schema.json")))
  files <- sort(files[file.exists(files)])
  relative <- substring(files, nchar(bmp_repo_root) + 2L)
  engine_files <- stats::setNames(lapply(files, bmp_sha256), relative)
  packages <- c("jsonlite", "yaml", "digest", "survival", "glmnet", "pROC")
  package_versions <- stats::setNames(lapply(packages, function(package) {
    if (requireNamespace(package, quietly = TRUE)) as.character(utils::packageVersion(package)) else "unavailable"
  }), packages)
  evidence <- bmp_evidence_identity(config)
  source_config <- if (!is.null(config$source_config) && file.exists(config$source_config)) {
    list(path = config$source_config, sha256 = bmp_sha256(config$source_config))
  } else NULL
  list(input = list(path = config$data_file, sha256 = bmp_sha256(config$data_file), bytes = unname(file.info(config$data_file)$size)),
    source_config = source_config, config_sha256 = bmp_hash_object(bmp_semantic_config(config)),
    engine = list(sha256 = bmp_hash_object(engine_files), files = engine_files),
    environment = list(r_version = R.version.string, platform = R.version$platform, packages = package_versions,
      docker_image_digest = Sys.getenv("BMP_IMAGE_DIGEST", unset = NA_character_)),
    evidence = evidence)
}

bmp_run_fingerprint <- function(provenance) {
  bmp_hash_object(list(input = provenance$input$sha256, config = provenance$config_sha256,
    engine = provenance$engine$sha256, environment = provenance$environment,
    evidence = if (is.null(provenance$evidence)) NULL else provenance$evidence$sha256))
}

bmp_new_run <- function(config, qc, evidence_identity = bmp_evidence_identity(config)) {
  config <- bmp_load_config(config)
  if (!identical(qc$status, "passed")) stop("Cannot create a run until preflight QC has passed.", call. = FALSE)
  # Force the bound identity before computing provenance; lazy evaluation must
  # not take a fresh evidence hash after another file read has changed it.
  force(evidence_identity)
  provenance <- bmp_provenance(config)
  bmp_assert_evidence_identity(evidence_identity, "between validation and run creation.")
  if (!identical(provenance$evidence, evidence_identity)) stop("Development evidence identity changed before run creation.", call. = FALSE)
  provenance$evidence <- evidence_identity
  parent <- file.path(config$output_dir, "runs")
  dir.create(parent, recursive = TRUE, showWarnings = FALSE)
  # tempfile does not consume the R modeling RNG. mkdir is the exclusive claim.
  repeat {
    id <- paste0(format(Sys.time(), "%Y%m%dT%H%M%S", tz = "UTC"), "-", basename(tempfile(pattern = "")))
    directory <- file.path(parent, id)
    if (dir.create(directory, showWarnings = FALSE)) break
    if (!dir.exists(parent) || file.access(parent, 2L) != 0L) stop("Run output directory is not writable.", call. = FALSE)
  }
  manifest <- list(schema_version = 1L, run_id = id, analysis_type = config$analysis_type,
    status = "created", created_at = bmp_now(), updated_at = bmp_now(),
    run_dir = normalizePath(directory, winslash = "/", mustWork = TRUE),
    fingerprint = bmp_run_fingerprint(provenance), provenance = provenance,
    validation = qc$validation, cohort = list(rows = qc$rows, groups = qc$groups,
      class_counts = qc$class_counts, events = qc$events, censored = qc$censored),
    warnings = qc$warnings, errors = character(), failed_folds = list(), resume_count = 0L,
    required_artifacts = c("config.json", "qc.json", "splits.json", "predictions.csv", "metrics.json",
      "model.bmpmodel", "stability.csv", "panel_comparison.csv", "model_comparison.csv", "report.html", "report.pdf"),
    artifacts = list())
  run <- list(id = id, run_id = id, dir = manifest$run_dir, output_dir = manifest$run_dir,
    root_output_dir = config$output_dir, config = config, manifest = manifest)
  bmp_atomic_json(config, file.path(run$dir, "config.json"))
  bmp_atomic_json(qc, file.path(run$dir, "qc.json"))
  bmp_atomic_json(manifest, file.path(run$dir, "manifest.json"))
  bmp_atomic_json(list(run_id = id, run_dir = run$dir, status = manifest$status), file.path(config$output_dir, "latest.json"))
  run
}

# Required artifacts are run-relative non-empty files. A completed manifest
# records their hashes; missing files force partial state and an error.
bmp_verify_artifacts <- function(run_dir, required_artifacts, hashes = NULL) {
  required <- bmp_strings(required_artifacts)
  invalid <- required[grepl("(^/|^[A-Za-z]:|(^|[/\\\\])\\.\\.([/\\\\]|$))", required)]
  if (length(invalid)) stop("Artifact paths must stay inside the run directory.", call. = FALSE)
  missing <- required[!vapply(required, function(path) {
    full <- file.path(run_dir, path)
    file.exists(full) && !dir.exists(full) && file.info(full)$size > 0
  }, logical(1))]
  present <- setdiff(required, missing)
  actual <- stats::setNames(lapply(file.path(run_dir, present), bmp_sha256), present)
  mismatch <- if (is.null(hashes)) character() else present[vapply(present, function(path) {
    !is.null(hashes[[path]]) && !identical(actual[[path]], hashes[[path]])
  }, logical(1))]
  list(ok = !length(c(missing, mismatch)), missing = missing, mismatch = mismatch, sha256 = actual)
}

bmp_update_manifest <- function(run, status, ...) {
  if (!status %in% c("created", "validated", "running", "completed", "partial", "failed", "cancelled")) stop("Invalid run status.", call. = FALSE)
  manifest <- bmp_read_json(file.path(run$dir, "manifest.json"))
  updates <- list(...)
  immutable <- intersect(names(updates), c("run_id", "fingerprint", "provenance", "created_at", "run_dir"))
  if (length(immutable)) stop(paste("Cannot overwrite immutable manifest fields:", paste(immutable, collapse = ", ")), call. = FALSE)
  for (key in names(updates)) manifest[key] <- list(updates[[key]])
  manifest$status <- status
  manifest$updated_at <- bmp_now()
  verification <- NULL
  if (status == "completed") {
    verification <- bmp_verify_artifacts(run$dir, manifest$required_artifacts)
    manifest$artifact_verification <- verification
    if (!verification$ok) {
      manifest$status <- "partial"
      manifest$errors <- unique(c(bmp_strings(manifest$errors), paste("Required artifacts missing or invalid:", paste(c(verification$missing, verification$mismatch), collapse = ", "))))
    }
  }
  if (manifest$status %in% c("completed", "partial", "failed", "cancelled")) manifest$finished_at <- bmp_now()
  bmp_atomic_json(manifest, file.path(run$dir, "manifest.json"))
  root <- if (!is.null(run$root_output_dir)) run$root_output_dir else dirname(dirname(run$dir))
  bmp_atomic_json(list(run_id = manifest$run_id, run_dir = run$dir, status = manifest$status), file.path(root, "latest.json"))
  run$manifest <- manifest
  if (!is.null(verification) && !verification$ok) stop(paste("Run is partial:", tail(manifest$errors, 1L)), call. = FALSE)
  run
}

# Strict compatibility check only; callers decide whether and when to mark a
# resumed run running. This prevents a read-only compatibility check mutating it.
bmp_resume_run <- function(run_dir, config) {
  run_dir <- normalizePath(run_dir, winslash = "/", mustWork = TRUE)
  manifest <- bmp_read_json(file.path(run_dir, "manifest.json"))
  config <- bmp_load_config(config)
  provenance <- bmp_provenance(config)
  if (!identical(manifest$fingerprint, bmp_run_fingerprint(provenance))) {
    stop("Resume is incompatible: input data, semantic config, engine/schema, evidence or runtime versions changed. Start a new run.", call. = FALSE)
  }
  saved <- bmp_load_config(bmp_read_json(file.path(run_dir, "config.json")))
  if (!identical(bmp_hash_object(bmp_semantic_config(saved)), provenance$config_sha256)) stop("Saved run config was modified; start a new run.", call. = FALSE)
  if (identical(manifest$status, "completed")) {
    verification <- bmp_verify_artifacts(run_dir, manifest$required_artifacts, manifest$artifact_verification$sha256)
    if (!verification$ok) stop("Completed run artifacts are missing or changed; the run cannot be trusted for resume.", call. = FALSE)
  }
  list(id = manifest$run_id, run_id = manifest$run_id, dir = run_dir, output_dir = run_dir,
    root_output_dir = dirname(dirname(run_dir)), config = config, manifest = manifest)
}

bmp_list_runs <- function(output_dir) {
  directory <- file.path(output_dir, "runs")
  if (!dir.exists(directory)) return(list())
  paths <- file.path(list.dirs(directory, recursive = FALSE, full.names = TRUE), "manifest.json")
  manifests <- lapply(paths[file.exists(paths)], function(path) {
    tryCatch({
      value <- bmp_read_json(path)
      value$run_dir <- dirname(path)
      value
    }, error = function(error) list(run_id = basename(dirname(path)), run_dir = dirname(path),
      status = "invalid", errors = conditionMessage(error)))
  })
  if (!length(manifests)) return(manifests)
  manifests[order(vapply(manifests, function(value) if (is.null(value$created_at)) "" else value$created_at, character(1)), decreasing = TRUE)]
}
