# One dispatcher for local, container and desktop execution. Never invoke a shell.
bmp_cli_version <- function() list(application = "BioMarkerPred", application_version = "0.5.0", engine_version = "1.0.0", interface_version = 1L, config_version = 1L, model_version = 1L, selection_policy_version = 2L)
bmp_cli_help <- function() paste(c(
  "BioMarkerPred shared research engine", "Usage: Rscript BiomarkerCLI.R COMMAND [OPTIONS]", "",
  "validate --config PATH           Validate and return QC without creating a run",
  "analyze --config PATH            Nested grouped development analysis and reports",
  "binary|survival --config PATH    Analysis-type aliases (legacy YAML supported)",
  "predict --model PATH --data CSV --output CSV_OR_DIRECTORY [--time-unit UNIT]",
  "evaluate --model PATH --data CSV --output DIRECTORY [--bootstrap-samples N] [--seed N] [--time-unit UNIT]",
  "runs --output DIRECTORY          Read persistent run manifests",
  "compare --run PATH --run PATH    Compare recorded runs; --runs PATH1,PATH2 also accepted",
  "        [--output JSON_PATH_OR_DIRECTORY]",
  "resume --run PATH                Verify compatibility and resume checkpoints",
  "report --run PATH                Regenerate reports from stored results only",
  "       [--recover-lock TOKEN]    Acknowledge verified termination of a lock owner in another host/container context",
  "ora --run PATH --gmt PATH        Offline exploratory ORA, full-ranked GSEA and gene evidence",
  "    --term-map CSV               Alternative local annotation: term_id,gene_id[,description]",
  "    --mapping CSV                Optional source_id,target_id mapping; ambiguity excluded",
  "    --annotation go-bp|go-mf|go-cc Optional GO packages; local GMT also supports KEGG/Reactome exports",
  "    --annotation-version TEXT    Label a local annotation release (file hash always saved)",
  "    --network none|string        Offline default none; STRING transmits gene IDs only",
  "    --add-nodes N --string-score N Explicit STRING expansion (default 0) and score 0..1000 (default 400)",
  "    --species N                  NCBI taxon (default 9606); STRING functional associations, not direct binding",
  "    --permutations N --seed N     Competitive GSEA permutations (default 1000), seed (default 1)",
  "    --min-size N --max-size N     Background-intersected term limits (default 5..500)",
  "    --evidence CSV --output DIR   Optional supplied evidence and isolated output root",
  "    --recover-lock TOKEN         Acknowledge verified termination of a foreign-context lock owner",
  "doctor                          Check versions and core runtime dependencies",
  "--version | --help", "",
  "All commands accept --json. Stdout then contains exactly one JSON object; progress and warnings use stderr.",
  "Options accept --key=value or --key value. Unknown or duplicate options fail (except repeated --run for compare).",
  "Exit 0 means the requested operation and required artifact checks succeeded. Errors exit 1; interruption exits 130.",
  "Survival units: days, months, years. External evaluation never refits or changes thresholds.",
  "Legacy incomplete model artifacts must be retrained with analyze; missing encoders/baselines are never invented."
), collapse = "\n")

bmp_cli_parse <- function(args) {
  if (!length(args)) return(list(command = "help", options = list()))
  command <- if (args[1L] %in% c("--help", "-h")) "help" else if (args[1L] == "--version") "version" else args[1L]
  args <- args[-1L]; options <- list(); flags <- c("json", "help")
  while (length(args)) {
    token <- args[1L]; args <- args[-1L]
    if (token == "-h") token <- "--help"
    if (!grepl("^--[a-z][a-z0-9-]*(=|$)", token)) stop(paste("Unexpected argument:", token), call. = FALSE)
    key <- sub("=.*$", "", substring(token, 3L))
    if (grepl("=", token, fixed = TRUE)) {
      value <- sub("^[^=]*=", "", token)
      if (key %in% flags) stop(paste("Boolean flag takes no value:", key), call. = FALSE)
    } else if (key %in% flags) value <- TRUE else {
      if (!length(args) || startsWith(args[1L], "--")) stop(paste("Missing value for --", key, sep = ""), call. = FALSE)
      value <- args[1L]; args <- args[-1L]
    }
    if (!is.null(options[[key]]) && !(command == "compare" && key == "run")) stop(paste("Duplicate option: --", key, sep = ""), call. = FALSE)
    if (key == "run" && command == "compare") options[[key]] <- c(options[[key]], value) else options[[key]] <- value
  }
  allowed <- list(help = character(), version = character(), doctor = character(),
    validate = "config", analyze = "config", binary = "config", survival = "config",
    predict = c("model", "data", "output", "time-unit"), evaluate = c("model", "data", "output", "time-unit", "bootstrap-samples", "seed"),
    runs = "output", compare = c("run", "runs", "output"), resume = c("run", "recover-lock"), report = c("run", "recover-lock"),
    ora = c("run", "gmt", "output", "species", "add-nodes", "string-score", "permutations", "seed", "min-size", "max-size", "network", "mapping", "term-map", "annotation", "annotation-version", "evidence", "recover-lock"))
  if (!command %in% names(allowed)) stop(paste("Unknown command:", command, "; use --help."), call. = FALSE)
  unknown <- setdiff(names(options), c(allowed[[command]], flags))
  if (length(unknown)) stop(paste("Unsupported option(s) for", command, ":", paste(paste0("--", unknown), collapse = ", ")), call. = FALSE)
  if (isTRUE(options$help)) command <- "help"
  list(command = command, options = options)
}
bmp_cli_required <- function(options, keys) {
  for (key in keys) if (is.null(options[[key]]) || !nzchar(options[[key]])) stop(paste("Required option: --", key, sep = ""), call. = FALSE)
}
bmp_cli_integer <- function(value, default, key) {
  if (is.null(value)) return(as.integer(default))
  number <- suppressWarnings(as.numeric(value))
  if (length(number) != 1L || !is.finite(number) || number < 0 || number != floor(number) || number > 2147483646) stop(paste(key, "must be an integer in [0,2147483646]."), call. = FALSE)
  as.integer(number)
}
bmp_cli_load_model <- function(path) tryCatch(bmp_load_model(path), error = function(error) stop(paste(conditionMessage(error), "Retrain legacy or incomplete artifacts with analyze; a frozen version-1 encoder, threshold and survival baseline are required."), call. = FALSE))
bmp_run_open <- function(directory) {
  directory <- normalizePath(directory, winslash = "/", mustWork = TRUE)
  manifest <- bmp_read_json(file.path(directory, "manifest.json"))
  list(id = manifest$run_id, run_id = manifest$run_id, dir = directory, output_dir = directory,
    root_output_dir = dirname(dirname(directory)), config = bmp_read_json(file.path(directory, "config.json")), manifest = manifest)
}
bmp_run_summary <- function(run, operation = NULL) {
  run <- bmp_run_open(run$dir)
  paths <- list(manifest = file.path(run$dir, "manifest.json"), config = file.path(run$dir, "config.json"), qc = file.path(run$dir, "qc.json"),
    model = file.path(run$dir, "model.bmpmodel"), predictions = file.path(run$dir, "predictions.csv"), metrics = file.path(run$dir, "metrics.json"),
    report_html = file.path(run$dir, "report.html"), report_pdf = file.path(run$dir, "report.pdf"), figures = file.path(run$dir, "figures", "index.json"))
  list(ok = identical(run$manifest$status, "completed"), operation = if (is.null(operation)) if (is.null(run$manifest$operation)) "analyze" else run$manifest$operation else operation,
    run_id = run$id, run_dir = run$dir, status = run$manifest$status, analysis_type = run$manifest$analysis_type,
    validation = run$manifest$validation, cohort = run$manifest$cohort, failed_folds = run$manifest$failed_folds,
    warnings = run$manifest$warnings, paths = paths, qc = bmp_read_json(paths$qc))
}
bmp_verify_recorded <- function(run, completed = identical(run$manifest$status, "completed")) {
  records <- c("engine_artifact_verification", "evaluation_artifact_verification", "metrics_artifact_verification", "report_artifact_verification")
  if (completed) records <- c(records, "artifact_verification")
  for (name in records) {
    hashes <- run$manifest[[name]]$sha256
    if (length(hashes)) {
      check <- bmp_verify_artifacts(run$dir, names(hashes), hashes)
      if (!check$ok) stop(paste("Saved artifact integrity check failed:", paste(c(check$missing, check$mismatch), collapse = ", ")), call. = FALSE)
    }
  }
  if (completed) {
    check <- bmp_verify_artifacts(run$dir, run$manifest$required_artifacts, run$manifest$artifact_verification$sha256)
    if (!check$ok || !length(run$manifest$artifact_verification$sha256)) stop("Completed artifact verification is absent or invalid.", call. = FALSE)
  }
  invisible(TRUE)
}
bmp_run_attempt <- function(run) {
  attempts <- run$manifest$attempts
  attempts[[length(attempts) + 1L]] <- list(started_at = bmp_now(), previous_status = run$manifest$status, previous_stage = run$manifest$stage,
    previous_errors = run$manifest$errors, previous_finished_at = run$manifest$finished_at)
  bmp_update_manifest(run, "running", attempts = attempts, errors = character(), finished_at = NULL)
}
bmp_finalize_run <- function(run) {
  run <- bmp_run_open(run$dir)
  bmp_verify_recorded(run, completed = FALSE)
  bmp_cli_load_model(file.path(run$dir, "model.bmpmodel"))
  if (!identical(bmp_sha256(run$manifest$provenance$input$path), run$manifest$provenance$input$sha256)) stop("Input changed before final completion; recorded results cannot be attributed to the current input.", call. = FALSE)
  bmp_assert_evidence_identity(run$manifest$provenance$evidence, "before final completion.")
  if (identical(run$manifest$operation, "evaluate") && !identical(bmp_sha256(run$manifest$provenance$model$path), run$manifest$provenance$model$sha256)) stop("Source frozen model changed before final completion.", call. = FALSE)
  if (length(run$manifest$failed_folds)) stop("Run has failed outer folds; it cannot be marked completed.", call. = FALSE)
  run <- bmp_update_manifest(run, "completed", stage = "complete", report_status = "completed", errors = character())
  bmp_engine_event("completed", run_id = run$id, run_dir = run$dir, status = "completed", paths = bmp_run_summary(run)$paths)
  bmp_run_summary(run)
}
bmp_run_failure <- function(run, error) {
  if (is.null(run)) return(invisible(NULL))
  current <- bmp_run_open(run$dir)
  if (!current$manifest$status %in% c("failed", "partial", "cancelled")) bmp_update_manifest(current, if (inherits(error, "interrupt")) "cancelled" else "failed",
    errors = conditionMessage(error), stage = current$manifest$stage)
  invisible(NULL)
}
bmp_cli_analyze <- function(config_path, type = NULL, run_dir = NULL, recover_token = NULL) {
  run <- NULL; lock <- NULL; active <- FALSE
  on.exit(bmp_lock_release(lock), add = TRUE)
  tryCatch({
    if (!is.null(run_dir)) lock <- bmp_lock_acquire(run_dir, "resume", recover_token)
    config <- bmp_load_config(config_path, analysis_type = type)
    input_hash <- bmp_sha256(config$data_file)
    evidence_identity <- bmp_evidence_identity(config)
    validated <- bmp_validate_data(config)
    if (!identical(input_hash, bmp_sha256(config$data_file))) stop("Development input changed during validation. Retry with an unchanged input file.", call. = FALSE)
    bmp_assert_evidence_identity(evidence_identity, "during validation.")
    if (is.null(run_dir)) {
      run <- bmp_new_run(validated$config, validated$qc, evidence_identity); active <- TRUE
      lock <- bmp_lock_acquire(run$dir, "analyze")
    } else {
      run <- bmp_resume_run(run_dir, validated$config); bmp_verify_recorded(run)
      bmp_assert_evidence_identity(evidence_identity, "during resume verification.")
      if (identical(run$manifest$status, "completed")) return(bmp_run_summary(run, "resume"))
      run <- bmp_run_attempt(run); active <- TRUE
    }
    if (!identical(input_hash, run$manifest$provenance$input$sha256)) stop("Development input changed between validation and run creation.", call. = FALSE)
    bmp_assert_evidence_identity(evidence_identity, "between validation and run creation.")
    bmp_engine_event("run_start", run_id = run$id, run_dir = run$dir, status = "running")
    result <- bmp_run_engine(validated, run, resume = !is.null(run_dir)); run <- result$run
    bmp_metrics_for_run(run$dir)
    bmp_report_run(run$dir)
    if (!identical(input_hash, bmp_sha256(config$data_file))) stop("Development input changed during analysis. Recorded results cannot be attributed to the current input.", call. = FALSE)
    bmp_assert_evidence_identity(evidence_identity, "during analysis.")
    bmp_finalize_run(run)
  }, error = function(error) {
    if (active) bmp_run_failure(run, error)
    if (!is.null(run)) { error$run_id <- run$id; error$run_dir <- run$dir }
    stop(error)
  }, interrupt = function(error) { if (active) bmp_run_failure(run, error); stop(error) })
}
bmp_cli_evaluate <- function(options, run = NULL, lock = NULL) {
  active <- run
  on.exit(bmp_lock_release(lock), add = TRUE)
  tryCatch({
    bmp_cli_load_model(options$model)
    result <- bmp_evaluate(options$model, options$data, options$output,
      bmp_cli_integer(options[["bootstrap-samples"]], 200L, "bootstrap-samples"), bmp_cli_integer(options$seed, 1L, "seed"), options[["time-unit"]], resume_run = run,
      run_ready = function(value) { active <<- value; if (is.null(lock)) lock <<- bmp_lock_acquire(value$dir, "evaluate") })
    active <- result$run
    bmp_report_run(active$dir)
    summary <- bmp_finalize_run(active); summary$model_sha256 <- result$model_sha256; summary$model_unchanged <- result$model_unchanged
    summary
  }, error = function(error) {
    bmp_run_failure(active, error)
    if (!is.null(active)) { error$run_id <- active$id; error$run_dir <- active$dir }
    stop(error)
  }, interrupt = function(error) { bmp_run_failure(active, error); stop(error) })
}
bmp_resume_evaluation <- function(run, recover_token = NULL) {
  lock <- bmp_lock_acquire(run$dir, "resume_evaluate", recover_token)
  on.exit(bmp_lock_release(lock), add = TRUE)
  run <- bmp_run_open(run$dir)
  config <- run$config; recorded <- run$manifest$provenance
  model <- bmp_cli_load_model(config$model_path)
  expected <- bmp_evaluation_provenance(model, config$model_path, config$data_file)
  if (!identical(bmp_hash_object(expected), bmp_hash_object(recorded)) || !identical(run$manifest$fingerprint, bmp_hash_object(list(provenance = expected, config = config)))) stop("External resume is incompatible: frozen model, input, config or evaluation engine changed. Start a new evaluation.", call. = FALSE)
  bmp_verify_recorded(run)
  if (file.exists(file.path(run$dir, "model.bmpmodel")) && !identical(bmp_sha256(file.path(run$dir, "model.bmpmodel")), recorded$model$sha256)) stop("Frozen evaluation snapshot changed; refuse resume.", call. = FALSE)
  if (identical(run$manifest$status, "completed")) return(bmp_run_summary(run, "resume"))
  run <- bmp_run_attempt(run)
  # Frozen scoring may be repeated after interruption, but never development fitting.
  bmp_cli_evaluate(list(model = config$model_path, data = config$data_file, output = run$root_output_dir,
    `bootstrap-samples` = config$bootstrap_samples, seed = config$seed, `time-unit` = config$declared_external_time_unit), run, lock)
}
bmp_cli_predict <- function(options) {
  model_path <- normalizePath(options$model, winslash = "/", mustWork = TRUE)
  data_path <- normalizePath(options$data, winslash = "/", mustWork = TRUE)
  requested <- normalizePath(options$output, winslash = "/", mustWork = FALSE)
  # Check the original argument before deciding that a non-CSV path is a directory.
  if (requested %in% c(model_path, data_path)) stop("Prediction output must not overwrite its input or source model.", call. = FALSE)
  output <- if (grepl("\\.csv$", requested, ignore.case = TRUE) && !dir.exists(requested)) requested else file.path(requested, "predictions.csv")
  output <- normalizePath(output, winslash = "/", mustWork = FALSE)
  if (output %in% c(model_path, data_path)) stop("Prediction output aliases its input or source model.", call. = FALSE)
  before_model <- bmp_sha256(model_path); before_data <- bmp_sha256(data_path)
  model <- bmp_cli_load_model(model_path); validated <- bmp_validate_prediction_data(model, data_path, time_unit = options[["time-unit"]])
  predictions <- bmp_predict_model(model, validated$data); predictions$group_id <- validated$groups
  attr(predictions, "survival_probabilities") <- NULL; attr(predictions, "horizons") <- NULL
  if (!identical(before_model, bmp_sha256(model_path)) || !identical(before_data, bmp_sha256(data_path))) stop("Prediction input/model changed while being read.", call. = FALSE)
  bmp_atomic_csv(predictions, output)
  list(ok = TRUE, operation = "predict", status = "completed", analysis_type = model$analysis_type, rows = nrow(predictions),
    model_sha256 = before_model, input_sha256 = before_data, model_unchanged = identical(before_model, bmp_sha256(model_path)),
    output = output, paths = list(predictions = output), threshold = model$threshold, threshold_method = model$threshold_method, qc = validated$qc)
}
bmp_compare_runs <- function(paths, output = NULL) {
  if (length(paths) < 2L) stop("Compare requires at least two --run paths or --runs PATH1,PATH2.", call. = FALSE)
  rows <- lapply(paths, function(path) {
    run <- bmp_run_open(path); bmp_verify_recorded(run)
    model <- if (file.exists(file.path(run$dir, "model.bmpmodel"))) bmp_cli_load_model(file.path(run$dir, "model.bmpmodel")) else NULL
    metrics <- if (file.exists(file.path(run$dir, "metrics.json"))) bmp_read_json(file.path(run$dir, "metrics.json")) else NULL
    criteria <- list(analysis_type = run$config$analysis_type, cohort_sha256 = run$manifest$provenance$input$sha256,
      operation = if (is.null(run$manifest$operation)) "analyze" else run$manifest$operation,
      outcome = model$outcome, time_unit = if (run$config$analysis_type == "survival") run$config$time_unit else NULL,
      horizon = if (run$config$analysis_type == "survival") run$config$horizon else NULL,
      validation = run$manifest$validation, metric_methods = metrics$methods)
    list(run_id = run$id, run_dir = run$dir, status = run$manifest$status, analysis_type = run$config$analysis_type,
      criteria = criteria, comparison_group = bmp_hash_object(criteria), primary = metrics$primary,
      panel = list(selected_genes = model$selected_genes, actual_gene_count = model$actual_gene_count, clinical_columns = model$clinical_columns), warnings = run$manifest$warnings)
  })
  baseline <- rows[[1]]$criteria
  for (i in seq_along(rows)) {
    differences <- names(baseline)[!vapply(names(baseline), function(key) identical(bmp_hash_object(baseline[[key]]), bmp_hash_object(rows[[i]]$criteria[[key]])), logical(1))]
    rows[[i]]$comparable_to_first <- !length(differences) && identical(rows[[i]]$status, "completed") && identical(rows[[1]]$status, "completed")
    rows[[i]]$incompatibilities <- I(c(differences, if (!identical(rows[[i]]$status, "completed")) "incomplete_run"))
  }
  result <- list(ok = TRUE, operation = "compare", runs = rows,
    interpretation = "Descriptive recorded results only. Matching groups share cohort/outcome/validation definitions; differing groups are not ranked together. No paired significance test or selection-adjusted superiority claim is made.", paired_test = NULL)
  if (!is.null(output)) {
    target <- if (grepl("\\.json$", output, ignore.case = TRUE)) output else file.path(output, "comparison.json")
    protected <- unlist(lapply(rows, function(row) file.path(row$run_dir, list.files(row$run_dir, recursive = TRUE))), use.names = FALSE)
    if (normalizePath(target, mustWork = FALSE) %in% normalizePath(protected, mustWork = FALSE)) stop("Comparison output cannot overwrite an existing run artifact.", call. = FALSE)
    bmp_atomic_json(result, target); result$output <- normalizePath(target, winslash = "/", mustWork = TRUE)
  }
  result
}
bmp_cli_doctor <- function() {
  packages <- c("yaml", "jsonlite", "digest", "survival", "glmnet", "pROC")
  versions <- stats::setNames(lapply(packages, function(package) if (requireNamespace(package, quietly = TRUE)) as.character(utils::packageVersion(package)) else NULL), packages)
  missing <- packages[vapply(versions, is.null, logical(1))]
  graphics <- capabilities(c("cairo", "png", "tiff"))
  result <- c(list(ok = !length(missing) && all(graphics), operation = "doctor"), bmp_cli_version(),
    list(r_version = R.version.string, platform = R.version$platform, packages = versions, missing_packages = I(missing),
      graphics = as.list(graphics), engine_root = bmp_repo_root,
      schema = file.path(bmp_repo_root, "config", "schema.json"), optional_pathways = exists("bmp_pathway_analysis", mode = "function"),
      pathway_capabilities = list(offline_gmt = exists("bmp_pathway_analysis", mode = "function"), offline_term_mapping = TRUE, native_ranked_gsea = TRUE,
        string_transport = if (requireNamespace("curl", quietly = TRUE)) "curl POST" else "base libcurl GET (7000-byte limit)",
        optional_packages = stats::setNames(lapply(c("AnnotationDbi", "GO.db", "org.Hs.eg.db", "org.Mm.eg.db", "curl"), function(package) if (requireNamespace(package, quietly = TRUE)) as.character(utils::packageVersion(package)) else NULL), c("AnnotationDbi", "GO.db", "org.Hs.eg.db", "org.Mm.eg.db", "curl")),
        kegg_reactome = "Provide a versioned local GMT or term mapping; no online provider is silently assumed.")))
  if (!isTRUE(result$ok)) result$error <- "Install missing core packages and an R build with Cairo PDF/SVG, PNG and TIFF support. Optional pathway packages are not required for core analysis."
  result
}
bmp_cli_dispatch <- function(parsed) {
  command <- parsed$command; options <- parsed$options
  if (command == "help") return(list(ok = TRUE, help = bmp_cli_help()))
  if (command == "version") return(c(list(ok = TRUE), bmp_cli_version()))
  if (command == "doctor") return(bmp_cli_doctor())
  if (command %in% c("validate", "analyze", "binary", "survival")) {
    bmp_cli_required(options, "config")
    if (command == "validate") {
      config <- bmp_load_config(options$config)
      value <- tryCatch(bmp_validate_data(config), error = function(error) { error$config <- config; stop(error) })
      return(list(ok = TRUE, operation = command, status = "validated", config = value$config, qc = value$qc))
    }
    return(bmp_cli_analyze(options$config, if (command %in% c("binary", "survival")) command else NULL))
  }
  if (command %in% c("predict", "evaluate")) {
    bmp_cli_required(options, c("model", "data", "output"))
    return(if (command == "predict") bmp_cli_predict(options) else bmp_cli_evaluate(options))
  }
  if (command == "runs") { bmp_cli_required(options, "output"); return(list(ok = TRUE, operation = "runs", runs = bmp_list_runs(options$output))) }
  if (command == "compare") return(bmp_compare_runs(c(options[["run"]], if (!is.null(options$runs)) strsplit(options$runs, ",", fixed = TRUE)[[1]]), options$output))
  bmp_cli_required(options, "run")
  if (command == "report") {
    lock <- bmp_lock_acquire(options[["run"]], "report", options[["recover-lock"]]); on.exit(bmp_lock_release(lock), add = TRUE)
    bmp_report_run(options[["run"]]); result <- bmp_run_summary(bmp_run_open(options[["run"]]), "report"); result$ok <- TRUE; return(result)
  }
  if (command == "resume") {
    run <- bmp_run_open(options[["run"]])
    return(if (identical(run$manifest$operation, "evaluate")) bmp_resume_evaluation(run, options[["recover-lock"]]) else bmp_cli_analyze(run$config, run_dir = run$dir, recover_token = options[["recover-lock"]]))
  }
  if (command == "ora") {
    if (!exists("bmp_pathway_analysis", mode = "function")) stop("Pathway engine is not installed yet. Core analyze/evaluate/report commands are available; install the pathway module for ora.", call. = FALSE)
    return(bmp_pathway_analysis(run_dir = options[["run"]], options = options))
  }
  stop("Unhandled CLI command.", call. = FALSE)
}
bmp_cli_json <- function(value, pretty = FALSE) {
  if (requireNamespace("jsonlite", quietly = TRUE)) return(as.character(jsonlite::toJSON(bmp_json_arrays(value), auto_unbox = TRUE, null = "null", na = "null", pretty = pretty, digits = 16, dataframe = "rows")))
  # Doctor must still explain a missing jsonlite installation to the desktop.
  # This tiny fallback only serializes ordinary scalar/list diagnostic values.
  quote <- function(text) {
    text <- encodeString(enc2utf8(text), quote = '"', na.encode = FALSE)
    text <- gsub("\\a", "\\u0007", text, fixed = TRUE); text <- gsub("\\v", "\\u000b", text, fixed = TRUE)
    text
  }
  encode <- function(item) {
    if (is.null(item)) return("null")
    if (is.list(item)) {
      values <- vapply(item, encode, character(1))
      if (!is.null(names(item))) return(paste0("{", paste(paste0(vapply(names(item), quote, character(1)), ":", values), collapse = ","), "}"))
      return(paste0("[", paste(values, collapse = ","), "]"))
    }
    if (length(item) != 1L || inherits(item, "AsIs")) return(paste0("[", paste(vapply(as.list(unclass(item)), encode, character(1)), collapse = ","), "]"))
    if (is.na(item)) return("null")
    if (is.logical(item)) return(if (item) "true" else "false")
    if (is.numeric(item)) return(if (is.finite(item)) format(item, scientific = FALSE, trim = TRUE) else "null")
    quote(as.character(item))
  }
  encode(value)
}
bmp_cli_main <- function(args = commandArgs(TRUE), exit = TRUE) {
  json <- "--json" %in% args; status <- 0L
  # Third-party package messages must never corrupt the one-object stdout API.
  logfile <- tempfile("bmp-cli-log-"); connection <- file(logfile, "wt", encoding = "UTF-8")
  sink(connection)
  result <- tryCatch(withCallingHandlers({
    parsed <- bmp_cli_parse(args); value <- bmp_cli_dispatch(parsed)
    if (!isTRUE(value$ok)) status <- 1L
    value
  }, warning = function(warning) { cat("Warning: ", conditionMessage(warning), "\n", sep = "", file = stderr()); invokeRestart("muffleWarning") }),
    error = function(error) { status <<- 1L; list(ok = FALSE, status = "failed", error = conditionMessage(error), config = error$config, qc = error$qc, run_id = error$run_id, run_dir = error$run_dir) },
    interrupt = function(error) { status <<- 130L; list(ok = FALSE, status = "cancelled", error = "Operation interrupted.") })
  sink(); close(connection)
  logs <- readLines(logfile, warn = FALSE); unlink(logfile)
  if (length(logs)) cat(paste(logs, collapse = "\n"), "\n", file = stderr())
  if (json) cat(bmp_cli_json(result), "\n", sep = "")
  else if (!is.null(result$help)) cat(result$help, "\n")
  else cat(bmp_cli_json(result, pretty = TRUE), "\n")
  if (exit) quit(save = "no", status = status, runLast = FALSE)
  invisible(list(status = status, result = result))
}
