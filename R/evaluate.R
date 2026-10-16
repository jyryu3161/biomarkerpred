# Frozen-model scoring and cohort evaluation. External data never enters the
# development validator or any fitting, threshold-selection or tuning function.
bmp_identifier_hashes <- function(ids) {
  I(vapply(unique(as.character(ids)), function(id) digest::digest(enc2utf8(id), algo = "sha256", serialize = FALSE), character(1), USE.NAMES = FALSE))
}
bmp_validate_prediction_data <- function(model, data, require_outcomes = FALSE, time_unit = NULL) {
  model <- bmp_model_artifact(model); bmp_validate_model(model)
  if (is.character(data) && length(data) == 1L) data <- bmp_read_csv(data)
  if (!is.data.frame(data)) stop("Prediction input must be a CSV path or data.frame.", call. = FALSE)
  qc <- list(schema_version = 1L, status = "passed", operation = if (require_outcomes) "evaluate" else "predict",
    analysis_type = model$analysis_type, rows = nrow(data), columns = ncol(data), errors = character(), warnings = character(),
    preprocessing = "Frozen training encoder only; no refitting, imputation learning, feature selection or threshold tuning")
  errors <- character()
  if (!nrow(data)) errors <- c(errors, "The input cohort has no rows.")
  if (anyDuplicated(names(data)) || anyNA(names(data)) || any(!nzchar(names(data)))) errors <- c(errors, "Input columns must have unique, nonempty names.")
  outcomes <- if (require_outcomes) if (model$analysis_type == "binary") model$outcome$column else c(model$outcome$time_variable, model$outcome$event) else character()
  required <- unique(c(model$sample_id, model$group_column, as.character(unlist(model$features)), outcomes))
  qc$required_columns <- I(required); qc$missing_columns <- I(setdiff(required, names(data)))
  if (length(qc$missing_columns)) errors <- c(errors, paste("Required model/input columns not found:", paste(qc$missing_columns, collapse = ", ")))
  if (length(errors)) bmp_qc_error(errors, qc)
  for (column in unique(c(model$sample_id, model$group_column))) {
    data[[column]] <- as.character(data[[column]])
    if (anyNA(data[[column]]) || any(!nzchar(trimws(data[[column]])))) errors <- c(errors, paste("Missing or blank identifier in", column))
  }
  group_column <- if (is.null(model$group_column)) model$sample_id else model$group_column
  groups <- data[[group_column]]
  qc$groups <- length(unique(groups)); qc$unique_samples <- length(unique(data[[model$sample_id]]))
  if (anyDuplicated(data[[model$sample_id]]) && !identical(model$group_column, model$sample_id)) errors <- c(errors, "Sample IDs must be unique unless the frozen model explicitly groups repeated measurements by sample_id.")
  qc$unknown_categories <- list(); qc$numeric_errors <- character()
  for (name in as.character(unlist(model$features))) {
    spec <- model$recipe$predictors[[name]]
    if (spec$type == "numeric") {
      value <- tryCatch(bmp_numeric(data[[name]], name), error = function(error) error)
      if (inherits(value, "error")) { errors <- c(errors, conditionMessage(value)); qc$numeric_errors <- c(qc$numeric_errors, name) }
      else data[[name]] <- value
    } else {
      unknown <- setdiff(unique(as.character(data[[name]][!is.na(data[[name]])])), as.character(unlist(spec$levels)))
      if (length(unknown)) {
        qc$unknown_categories[[name]] <- I(unknown)
        errors <- c(errors, sprintf("Unseen category in '%s': %s. Frozen model policy is error; the encoder was not changed.", name, paste(unknown, collapse = ", ")))
      }
    }
  }
  if (model$analysis_type == "survival") {
    qc$time_unit <- model$time_unit
    qc$time_unit_declared <- time_unit
    if (!is.null(time_unit) && !identical(as.character(time_unit), model$time_unit)) errors <- c(errors, sprintf("Time-unit mismatch: model expects '%s', input declared '%s'. Convert input times explicitly before evaluation.", model$time_unit, time_unit))
    if (is.null(time_unit) && require_outcomes) qc$warnings <- c(qc$warnings, paste("Input follow-up times assumed to use the frozen model unit:", model$time_unit, "; no unit conversion performed."))
  }
  if (require_outcomes && model$analysis_type == "binary") {
    y <- as.character(data[[model$outcome$column]])
    if (anyNA(y) || any(!y %in% c(model$outcome$positive_class, model$outcome$negative_class))) errors <- c(errors, "External binary outcomes must use exactly the model's declared positive/negative class codes, without missing values.")
    if (any(vapply(split(y, groups), function(values) length(unique(values)) > 1L, logical(1)))) errors <- c(errors, "Conflicting binary outcomes within a patient group.")
    qc$class_counts <- as.list(table(y)); if (length(unique(y)) < 2L) qc$warnings <- c(qc$warnings, "Only one outcome class: discrimination/calibration estimates requiring both classes will be unavailable.")
  }
  if (require_outcomes && model$analysis_type == "survival") {
    time <- suppressWarnings(as.numeric(data[[model$outcome$time_variable]])); event <- suppressWarnings(as.numeric(data[[model$outcome$event]]))
    if (any(!is.finite(time) | time <= 0)) errors <- c(errors, "External follow-up times must be finite and strictly positive.")
    if (anyNA(event) || any(!event %in% c(0,1))) errors <- c(errors, "External event codes must be 0 or 1, without missing values.")
    data[[model$outcome$time_variable]] <- time; data[[model$outcome$event]] <- event
    qc$events <- if (anyNA(event)) NULL else sum(event); qc$censored <- if (anyNA(event)) NULL else sum(event == 0)
    if (!any(event == 1, na.rm = TRUE)) qc$warnings <- c(qc$warnings, "No observed events: event-based discrimination is unavailable; supported Brier estimates remain reportable.")
  }
  if (length(errors)) bmp_qc_error(errors, qc)
  # Validate the complete frozen design, including any malformed stored encoder.
  tryCatch(bmp_apply_recipe(model$recipe, data, as.character(unlist(model$features))), error = function(error) bmp_qc_error(conditionMessage(error), qc))
  list(data = data, qc = qc, groups = groups)
}
bmp_distribution_drift <- function(model, data, data_sha256 = NULL) {
  features <- as.character(unlist(model$features)); distributions <- model$training$distribution
  records <- list(); categories <- list(); warnings <- character()
  absent <- setdiff(features, names(data))
  for (name in names(distributions)) {
    training <- distributions[[name]]; required <- name %in% features
    if (!name %in% names(data)) {
      records[[length(records)+1L]] <- data.frame(predictor = name, type = training$type, required = required, present = FALSE,
        training_missing_fraction = training$missing_fraction, external_missing_fraction = NA_real_, mean_difference_standardized = NA_real_, external_mean = NA_real_, external_sd = NA_real_, outside_training_range = NA_integer_, reason = "Column absent in external input")
      next
    }
    raw <- data[[name]]; missing <- is.na(raw)
    mean_difference <- external_mean <- external_sd <- NA_real_; outside <- NA_integer_; reason <- ""
    if (training$type == "numeric") {
      values <- suppressWarnings(as.numeric(as.character(raw)))
      if (any(!missing & !is.finite(values))) reason <- "Non-numeric values prevent numeric distribution comparison"
      else {
        observed <- values[!missing]
        if (length(observed)) external_mean <- mean(observed)
        if (length(observed) > 1L) external_sd <- stats::sd(observed)
        sd_training <- if (is.null(training$sd)) NA_real_ else training$sd
        mean_training <- if (is.null(training$mean)) NA_real_ else training$mean
        if (is.finite(sd_training) && sd_training > 0 && is.finite(external_mean)) mean_difference <- (external_mean-mean_training)/sd_training
        else reason <- "Standardized mean difference unavailable: missing/zero training SD or no observed external values"
        quantiles <- as.numeric(unlist(training$quantiles))
        if (length(quantiles) == 5L && all(is.finite(quantiles[c(1,5)]))) outside <- sum(observed < quantiles[1] | observed > quantiles[5])
      }
    } else {
      known <- names(training$counts); new_counts <- table(as.character(raw[!missing])); all_levels <- union(known, names(new_counts))
      train_counts <- as.numeric(unlist(training$counts)); names(train_counts) <- known
      categories[[name]] <- do.call(rbind, lapply(all_levels, function(level) data.frame(predictor = name, level = level,
        training_fraction = if (sum(train_counts) > 0) (if (level %in% known) train_counts[[level]] else 0)/sum(train_counts) else NA_real_,
        external_fraction = if (sum(new_counts) > 0) (if (level %in% names(new_counts)) unname(new_counts[[level]]) else 0)/sum(new_counts) else NA_real_,
        unknown_level = !level %in% known)))
      unknown <- setdiff(names(new_counts), known)
      if (length(unknown)) warnings <- c(warnings, paste("Unseen external categories:", name, paste(unknown, collapse = ", ")))
    }
    records[[length(records)+1L]] <- data.frame(predictor = name, type = training$type, required = required, present = TRUE,
      training_missing_fraction = training$missing_fraction, external_missing_fraction = mean(missing), mean_difference_standardized = mean_difference,
      external_mean = external_mean, external_sd = external_sd, outside_training_range = outside, reason = reason)
  }
  sample_hashes <- if (model$sample_id %in% names(data)) bmp_identifier_hashes(data[[model$sample_id]]) else character()
  group_column <- if (is.null(model$group_column)) model$sample_id else model$group_column
  group_hashes <- if (group_column %in% names(data)) bmp_identifier_hashes(data[[group_column]]) else character()
  hashes <- model$training$identifier_hashes
  overlap <- list(available = !is.null(hashes), samples = if (is.null(hashes)) NULL else length(intersect(sample_hashes, unlist(hashes$sample))),
    groups = if (is.null(hashes)) NULL else length(intersect(group_hashes, unlist(hashes$group))),
    identical_development_input = !is.null(data_sha256) && !is.null(model$provenance$input$sha256) && identical(data_sha256, model$provenance$input$sha256),
    interpretation = "Identifier collisions can occur between independently named cohorts; overlap is a warning requiring review, not proof of shared patients. Unsalted identifier hashes are not anonymization.")
  if (isTRUE(overlap$identical_development_input)) warnings <- c(warnings, "Evaluation input is byte-identical to the development input: these are in-sample results, not independent external validation.")
  if (!is.null(hashes) && (overlap$samples > 0 || overlap$groups > 0)) warnings <- c(warnings, sprintf("Identifiers overlap development: %d sample IDs and %d patient/group IDs. Confirm cohort independence.", overlap$samples, overlap$groups))
  if (is.null(hashes)) warnings <- c(warnings, "This model has no stored training identifier hashes; cohort overlap cannot be checked by identifier.")
  list(schema_version = 1L, method = "Frozen training summary comparison; numeric mean differences divided by training SD, missingness, observed ranges and category proportions. No reconstructed KS statistic.",
    coverage = list(scope = if (is.null(model$training$distribution_scope)) "Stored training predictor summaries" else model$training$distribution_scope,
      required_predictors = length(features), stored_predictors = length(distributions),
      considered_training_genes = model$training$considered_gene_count,
      required_training_genes = length(unlist(model$selected_genes)),
      omitted_training_genes = if (is.null(model$training$considered_gene_count)) NULL else model$training$considered_gene_count - length(unlist(model$selected_genes)),
      note = "Predictors omitted from the portable model have no external distribution comparison; this is not a whole-transcriptome drift test."),
    required_missing_columns = I(absent), numeric_and_missingness = bmp_bind_frames(records), categorical = bmp_bind_frames(categories), overlap = overlap,
    warnings = unique(warnings), limitation = "Distribution shifts do not establish model validity. Training censoring weights assume an applicable independent censoring process in the external cohort.")
}
bmp_evaluation_provenance <- function(model, model_path, data_path) {
  packages <- c("jsonlite", "yaml", "digest", "survival", "glmnet", "pROC")
  list(input = list(path = data_path, sha256 = if (file.exists(data_path)) bmp_sha256(data_path) else NULL),
    model = list(path = model_path, sha256 = bmp_sha256(model_path), development_run_id = model$run_id),
    evaluation_engine = list(r_version = R.version.string, platform = R.version$platform,
      packages = stats::setNames(lapply(packages, function(package) if (requireNamespace(package, quietly = TRUE)) as.character(utils::packageVersion(package)) else "unavailable"), packages),
      docker_image_digest = Sys.getenv("BMP_IMAGE_DIGEST", unset = NA_character_),
      module_sha256 = bmp_hash_object(lapply(file.path(bmp_repo_root, "R", c("metrics.R", "evaluate.R", "models.R", "preprocess.R")), bmp_sha256))))
}
bmp_new_evaluation_run <- function(model, model_path, data_path, output_dir, config) {
  parent <- file.path(output_dir, "runs"); dir.create(parent, recursive = TRUE, showWarnings = FALSE)
  repeat {
    id <- paste0(format(Sys.time(), "%Y%m%dT%H%M%S", tz = "UTC"), "-eval-", basename(tempfile(pattern = "")))
    directory <- file.path(parent, id)
    if (dir.create(directory, showWarnings = FALSE)) break
    if (!dir.exists(parent) || file.access(parent, 2L) != 0L) stop("Evaluation output directory is not writable.", call. = FALSE)
  }
  directory <- normalizePath(directory, winslash = "/", mustWork = TRUE)
  provenance <- bmp_evaluation_provenance(model, model_path, data_path)
  manifest <- list(schema_version = 1L, run_id = id, run_dir = directory, operation = "evaluate", analysis_type = model$analysis_type,
    status = "created", stage = "external_input_validation", created_at = bmp_now(), updated_at = bmp_now(),
    fingerprint = bmp_hash_object(list(provenance = provenance, config = config)), provenance = provenance,
    validation = "Frozen-model cohort evaluation; no refitting or threshold selection", warnings = character(), errors = character(),
    required_artifacts = c("config.json", "qc.json", "input.json", "model.bmpmodel", "predictions.csv", "metrics.json", "drift.json", "report.html", "report.pdf"))
  run <- list(id = id, run_id = id, dir = directory, output_dir = directory, root_output_dir = output_dir, config = config, manifest = manifest)
  bmp_atomic_json(config, file.path(directory, "config.json")); bmp_atomic_json(manifest, file.path(directory, "manifest.json"))
  bmp_atomic_json(provenance$input, file.path(directory, "input.json"))
  bmp_atomic_json(list(run_id = id, run_dir = directory, status = "created"), file.path(output_dir, "latest.json"))
  run
}
bmp_evaluate <- function(model_path, data_path, output_dir, bootstrap_samples = 200L, seed = 1L, time_unit = NULL, resume_run = NULL, run_ready = NULL) {
  if (length(bootstrap_samples) != 1L || !is.finite(bootstrap_samples) || bootstrap_samples < 0 || bootstrap_samples != as.integer(bootstrap_samples)) stop("bootstrap_samples must be a nonnegative integer.", call. = FALSE)
  if (length(seed) != 1L || !is.finite(seed) || seed < 0 || seed > 2147483646 || seed != as.integer(seed)) stop("seed must be an integer in [0,2147483646].", call. = FALSE)
  model_path <- normalizePath(model_path, winslash = "/", mustWork = TRUE)
  data_path <- normalizePath(data_path, winslash = "/", mustWork = FALSE)
  model <- bmp_load_model(model_path); before <- bmp_sha256(model_path)
  config <- list(config_version = 1L, operation = "evaluate", analysis_type = model$analysis_type, data_file = data_path, output_dir = normalizePath(output_dir, winslash = "/", mustWork = FALSE),
    model_path = model_path, sample_id = model$sample_id, group_column = model$group_column, outcome = model$outcome$column,
    positive_class = model$outcome$positive_class, negative_class = model$outcome$negative_class,
    positive_label = model$outcome$positive_label, negative_label = model$outcome$negative_label,
    time_variable = model$outcome$time_variable, event = model$outcome$event, horizon = model$horizon, time_unit = model$time_unit,
    declared_external_time_unit = time_unit, bootstrap_samples = as.integer(bootstrap_samples), seed = as.integer(seed))
  run <- if (is.null(resume_run)) bmp_new_evaluation_run(model, model_path, data_path, output_dir, config) else resume_run
  if (!is.null(run_ready)) run_ready(run)
  bmp_engine_event("evaluation_start", run_id = run$id, run_dir = run$dir, status = "running")
  tryCatch({
    if (!file.exists(file.path(run$dir, "model.bmpmodel")) && !file.copy(model_path, file.path(run$dir, "model.bmpmodel"), overwrite = FALSE)) stop("Unable to preserve immutable model snapshot in evaluation run.", call. = FALSE)
    if (!identical(before, bmp_sha256(file.path(run$dir, "model.bmpmodel")))) stop("Evaluation model snapshot differs from source model.", call. = FALSE)
    data <- bmp_read_csv(data_path)
    cohort_hash <- bmp_sha256(data_path)
    if (!identical(cohort_hash, run$manifest$provenance$input$sha256)) stop("External input changed while evaluation was starting; retry with an unchanged input file.", call. = FALSE)
    drift <- bmp_distribution_drift(model, data, cohort_hash)
    bmp_atomic_json(drift, file.path(run$dir, "drift.json"))
    validated <- bmp_validate_prediction_data(model, data, require_outcomes = TRUE, time_unit = time_unit)
    qc <- validated$qc; qc$warnings <- unique(c(qc$warnings, drift$warnings))
    bmp_atomic_json(qc, file.path(run$dir, "qc.json"))
    predictions <- bmp_predict_model(model, validated$data)
    predictions$group_id <- validated$groups; predictions$repeat_id <- 1L; predictions$fold <- 1L; predictions$split_id <- "external"
    predictions$role <- "external"; predictions$arm_id <- model$arm_id; predictions$algorithm <- model$algorithm
    predictions$feature_set <- model$feature_set; predictions$panel_size <- model$panel_size; predictions$actual_gene_count <- model$actual_gene_count
    predictions$observed <- if (model$analysis_type == "binary") as.character(validated$data[[model$outcome$column]]) else as.character(validated$data[[model$outcome$event]])
    predictions$outcome_binary <- if (model$analysis_type == "binary") as.integer(predictions$observed == model$outcome$positive_class) else NA_integer_
    predictions$event <- if (model$analysis_type == "survival") validated$data[[model$outcome$event]] else NA_integer_
    predictions$time <- if (model$analysis_type == "survival") validated$data[[model$outcome$time_variable]] else NA_real_
    attr(predictions, "survival_probabilities") <- NULL; attr(predictions, "horizons") <- NULL
    bmp_atomic_csv(predictions, file.path(run$dir, "predictions.csv"))
    run <- bmp_update_manifest(run, "running", stage = "external_metrics", cohort = list(rows = nrow(data), unique_samples = qc$unique_samples, groups = qc$groups, class_counts = qc$class_counts, events = qc$events, censored = qc$censored),
      fixed_threshold = model$threshold, threshold_method = model$threshold_method, time_unit = model$time_unit,
      model_path = file.path(run$dir, "model.bmpmodel"), source_model_sha256 = before, warnings = qc$warnings,
      independence = drift$overlap, interpretation = if (isTRUE(drift$overlap$identical_development_input)) "In-sample frozen-model evaluation: identical development input" else "External cohort scoring; verify independence and censoring assumptions")
    metrics <- bmp_metrics_for_run(run$dir)
    after <- bmp_sha256(model_path)
    if (!identical(before, after) || !identical(before, bmp_sha256(file.path(run$dir, "model.bmpmodel")))) stop("Source model or frozen snapshot changed during external evaluation.", call. = FALSE)
    if (!identical(cohort_hash, bmp_sha256(data_path))) stop("External input changed during evaluation; results cannot be attributed to the recorded cohort.", call. = FALSE)
    verification <- bmp_verify_artifacts(run$dir, c("config.json", "qc.json", "input.json", "model.bmpmodel", "predictions.csv", "metrics.json", "drift.json"))
    if (!verification$ok) stop("External evaluation artifact verification failed.", call. = FALSE)
    run <- bmp_update_manifest(run, "running", stage = "metrics_ready", model_unchanged = TRUE, evaluation_artifact_verification = verification,
      metrics_path = file.path(run$dir, "metrics.json"), report_status = "pending")
    bmp_engine_event("evaluation_metrics_ready", run_id = run$id, run_dir = run$dir, status = "metrics_ready")
    list(run = run, run_id = run$id, run_dir = run$dir, status = "metrics_ready", model_sha256 = before, model_unchanged = TRUE,
      paths = list(predictions = file.path(run$dir, "predictions.csv"), metrics = file.path(run$dir, "metrics.json"), drift = file.path(run$dir, "drift.json"), model = file.path(run$dir, "model.bmpmodel"), qc = file.path(run$dir, "qc.json"), manifest = file.path(run$dir, "manifest.json")),
      metrics = metrics, drift = drift, qc = qc, predictions = predictions)
  }, interrupt = function(error) {
    bmp_update_manifest(run, "cancelled", stage = "external_evaluation", errors = "External evaluation interrupted.")
    stop(error)
  }, error = function(error) {
    qc <- if (!is.null(error$qc)) error$qc else list(schema_version = 1L, status = "failed", errors = conditionMessage(error), warnings = character())
    bmp_atomic_json(qc, file.path(run$dir, "qc.json"))
    unchanged <- tryCatch(file.exists(model_path) && identical(before, bmp_sha256(model_path)), error = function(error) FALSE)
    bmp_update_manifest(run, "failed", stage = "external_evaluation", errors = conditionMessage(error), model_unchanged = unchanged)
    stop(structure(list(message = conditionMessage(error), call = NULL, run_id = run$id, run_dir = run$dir, qc = qc), class = c("bmp_evaluation_error", "error", "condition")))
  })
}
