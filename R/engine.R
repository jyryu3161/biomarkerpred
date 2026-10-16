# Engine persists assessment predictions and fold-specific models. Metrics/report
# generation is a separate consumer; this stage never marks a run completed.
bmp_engine_event <- function(type, ...) {
  value <- c(list(event = type, type = type, timestamp = bmp_now()), list(...))
  cat("BMP_EVENT:", jsonlite::toJSON(value, auto_unbox = TRUE, null = "null", na = "null"), "\n", sep = "", file = stderr())
}
bmp_atomic_csv <- function(value, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  temporary <- tempfile(pattern = ".csv-", tmpdir = dirname(path)); on.exit(unlink(temporary), add = TRUE)
  utils::write.csv(value, temporary, row.names = FALSE, na = "")
  if (!file.rename(temporary, path)) stop(paste("Cannot atomically write", path), call. = FALSE)
  invisible(path)
}
bmp_checkpoint_read <- function(run, split) {
  directory <- file.path(run$dir, "checkpoints")
  meta_path <- file.path(directory, paste0(split$id, ".json")); data_path <- file.path(directory, paste0(split$id, ".rds"))
  if (!file.exists(meta_path) && !file.exists(data_path)) return(NULL)
  # An interrupted RDS write before the atomic metadata commit is not completed.
  if (!file.exists(meta_path)) return(NULL)
  metadata <- bmp_read_json(meta_path)
  if (!identical(metadata$fingerprint, run$manifest$fingerprint) || !identical(metadata$split_hash, bmp_hash_object(split))) stop(paste("Incompatible checkpoint:", split$id), call. = FALSE)
  if (!file.exists(data_path) || !identical(metadata$sha256, bmp_sha256(data_path))) stop(paste("Checkpoint integrity check failed:", split$id), call. = FALSE)
  result <- readRDS(data_path)
  if (!is.list(result) || !identical(result$split$id, split$id) || is.null(result$models[[result$primary_arm_id]])) stop(paste("Invalid checkpoint:", split$id), call. = FALSE)
  lapply(result$models, bmp_validate_model)
  result
}
bmp_checkpoint_write <- function(result, run) {
  directory <- file.path(run$dir, "checkpoints"); dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(directory, paste0(result$split$id, ".rds")); temporary <- tempfile(pattern = ".checkpoint-", tmpdir = directory)
  on.exit(unlink(temporary), add = TRUE)
  saveRDS(result, temporary, version = 3)
  if (!file.rename(temporary, path)) stop("Cannot commit checkpoint.", call. = FALSE)
  bmp_atomic_json(list(schema_version = 1L, split_id = result$split$id, fingerprint = run$manifest$fingerprint, split_hash = bmp_hash_object(result$split), sha256 = bmp_sha256(path), status = "completed"), file.path(directory, paste0(result$split$id, ".json")))
  invisible(path)
}
bmp_fold_task <- function(split, data, config, run) {
  tryCatch({
    result <- bmp_fit_outer_fold(data, config, split)
    bmp_checkpoint_write(result, run)
    result
  }, error = function(error) list(split = split, error = conditionMessage(error)))
}
bmp_stability_records <- function(folds, genes) {
  rows <- list()
  scopes <- c("primary", sort(unique(unlist(lapply(folds, function(fold) names(fold$models))))))
  for (scope in scopes) {
    models <- lapply(folds, function(fold) if (scope == "primary") fold$models[[fold$primary_arm_id]] else fold$models[[scope]])
    models <- Filter(Negate(is.null), models)
    if (!length(models)) next
    for (gene in genes) {
      effects <- vapply(models, function(model) {
        if (!gene %in% unlist(model$selected_genes)) return(0)
        columns <- bmp_columns_for(model$recipe, gene)
        sum(as.numeric(unlist(model$coefficients[columns])))
      }, numeric(1))
      selected <- vapply(models, function(model) gene %in% unlist(model$selected_genes), logical(1))
      nonzero <- abs(effects) > 1e-10
      rows[[length(rows) + 1L]] <- data.frame(role = if (scope == "primary") "primary" else "fixed_arm", arm_id = scope, gene = gene, selected_folds = sum(selected), completed_folds = length(models), selection_frequency = mean(selected), positive_frequency = mean(effects > 1e-10), negative_frequency = mean(effects < -1e-10), direction_consistency = if (any(nonzero)) max(sum(effects > 1e-10), sum(effects < -1e-10))/sum(nonzero) else NA_real_, mean_standardized_coefficient = if (any(selected)) mean(effects[selected]) else 0, stringsAsFactors = FALSE)
    }
  }
  if (!length(rows)) return(data.frame(role = character(), arm_id = character(), gene = character(), selected_folds = integer(), completed_folds = integer(), selection_frequency = numeric(), positive_frequency = numeric(), negative_frequency = numeric(), direction_consistency = numeric(), mean_standardized_coefficient = numeric()))
  do.call(rbind, rows)
}
bmp_panel_overlap <- function(folds) {
  rows <- list()
  if (length(folds) > 1L) for (i in seq_len(length(folds) - 1L)) for (j in seq.int(i + 1L, length(folds))) {
    left <- unlist(folds[[i]]$models[[folds[[i]]$primary_arm_id]]$selected_genes)
    right <- unlist(folds[[j]]$models[[folds[[j]]$primary_arm_id]]$selected_genes)
    union <- union(left, right)
    rows[[length(rows) + 1L]] <- data.frame(split_a = folds[[i]]$split$id, split_b = folds[[j]]$split$id, intersection = length(intersect(left, right)), union = length(union), jaccard = if (length(union)) length(intersect(left, right))/length(union) else 1)
  }
  if (!length(rows)) return(data.frame(split_a = character(), split_b = character(), intersection = integer(), union = integer(), jaccard = numeric()))
  do.call(rbind, rows)
}
bmp_comparison_records <- function(folds, data, config) {
  rows <- list()
  for (fold in folds) {
    predictions <- fold$predictions
    for (role in unique(predictions$role)) for (id in unique(predictions$arm_id[predictions$role == role])) {
      pred <- predictions[predictions$role == role & predictions$arm_id == id, , drop = FALSE]
      assessment <- data[as.integer(unlist(fold$split$assessment)), , drop = FALSE]
      artifact <- fold$models[[id]]
      rows[[length(rows) + 1L]] <- data.frame(split_id = fold$split$id, repeat_id = fold$split$repeat_id, fold = fold$split$fold, role = role, arm_id = id, algorithm = artifact$algorithm, feature_set = artifact$feature_set, panel_size = artifact$panel_size, actual_gene_count = artifact$actual_gene_count, clinical_predictor_count = length(unlist(artifact$clinical_columns)), assessment_rows = nrow(pred), assessment_groups = length(unique(pred$group_id)), metric = if (config$analysis_type == "binary") "roc_auc" else "harrell_c", value = bmp_selection_score(assessment, pred, config), status = "completed", reason = "", interpretation = if (role == "primary") "Nested estimate of the inner-selected modeling procedure" else "Descriptive fixed-arm comparison; selecting the best outer result is optimistic", stringsAsFactors = FALSE)
    }
    missing <- setdiff(unique(fold$inner$summary$arm_id), names(fold$models))
    for (id in missing) {
      inner <- fold$inner$summary[fold$inner$summary$arm_id == id, , drop = FALSE]
      reason <- if (!is.null(fold$failed_arms[[id]])) fold$failed_arms[[id]] else paste(unique(inner$failures[nzchar(inner$failures)]), collapse = " | ")
      rows[[length(rows) + 1L]] <- data.frame(split_id = fold$split$id, repeat_id = fold$split$repeat_id, fold = fold$split$fold, role = "fixed_arm", arm_id = id, algorithm = inner$algorithm[1], feature_set = inner$feature_set[1], panel_size = inner$panel_size[1], actual_gene_count = NA_integer_, clinical_predictor_count = NA_integer_, assessment_rows = 0L, assessment_groups = 0L, metric = if (config$analysis_type == "binary") "roc_auc" else "harrell_c", value = NA_real_, status = "failed", reason = reason, interpretation = "Unavailable; never replaced with zero", stringsAsFactors = FALSE)
    }
  }
  do.call(rbind, rows)
}
bmp_fit_final <- function(data, config) {
  inner <- bmp_inner_select(data, config, seed = bmp_seed(config$seed, 900000))
  arm <- inner$candidates[[inner$primary_index]]
  recipe <- bmp_fit_recipe(data, config, arm$feature_set, seed = bmp_seed(config$seed, 900001))
  model <- bmp_fit_model(data, config, arm, seed = bmp_seed(config$seed, 900001), recipe = recipe)
  if (config$analysis_type == "binary") {
    model$artifact$threshold <- inner$thresholds[[arm$arm_id]]
    model$artifact$threshold_method <- "patient-weighted Youden threshold from full-development inner out-of-fold predictions"
  }
  model$artifact$selection <- list(method = "inner_grouped_cross_validation_on_full_development_cohort", candidate_id = arm$candidate_id, metric = if (config$analysis_type == "binary") "roc_auc" else "harrell_c", score = inner$summary$mean_score[inner$primary_index], performance_claim = "Final refitted model has no independent performance estimate; primary nested assessment estimates the selection procedure.")
  bmp_validate_model(model$artifact)
  screening <- list(inner = inner$screening, fitting = bmp_recipe_audit(list(recipe)))
  inner$screening <- NULL
  list(model = model, inner = inner, screening = screening)
}
bmp_run_engine <- function(validated, run, resume = FALSE) {
  config <- validated$config; data <- validated$data
  if (!identical(validated$qc$status, "passed")) stop("Preflight validation must pass before analysis.", call. = FALSE)
  if (resume) {
    run <- bmp_resume_run(run$dir, config)
    hashes <- run$manifest$engine_artifact_verification$sha256
    if (length(hashes)) {
      verification <- bmp_verify_artifacts(run$dir, names(hashes), hashes)
      if (!verification$ok) stop("Completed engine artifacts were changed or removed; refuse resume. Start a new run.", call. = FALSE)
    }
  }
  run <- bmp_update_manifest(run, "running", stage = "nested_validation", resume_count = as.integer(run$manifest$resume_count) + as.integer(resume), required_artifacts = unique(c(bmp_strings(run$manifest$required_artifacts), "fold_models.json", "final_selection.json", "panel_overlap.csv", "gene_ranking.csv")))
  tryCatch({
    splits <- bmp_make_splits(data, config)
    bmp_atomic_json(list(schema_version = 1L, method = "repeated_nested_grouped_cross_validation", seed = config$seed, outer = splits), file.path(run$dir, "splits.json"))
    results <- vector("list", length(splits)); pending <- integer(); reused <- character()
    for (i in seq_along(splits)) {
      saved <- if (resume) bmp_checkpoint_read(run, splits[[i]]) else NULL
      if (is.null(saved)) pending <- c(pending, i) else { results[[i]] <- saved; reused <- c(reused, splits[[i]]$id) }
    }
    cores <- parallel::detectCores(logical = FALSE); if (is.na(cores)) cores <- 1L
    workers <- min(config$workers, max(1L, cores), max(1L, length(pending)), 32L)
    bmp_engine_event("engine_start", run_id = run$id, run_dir = run$dir, folds = length(splits), reused = length(reused), workers = workers)
    if (length(pending)) {
      if (workers == 1L) {
        for (index in pending) {
          results[[index]] <- bmp_fold_task(splits[[index]], data, config, run)
          bmp_engine_event("fold_finished", run_id = run$id, run_dir = run$dir, current = sum(!vapply(results, is.null, logical(1))), total = length(splits), split_id = splits[[index]]$id, status = if (is.null(results[[index]]$error)) "completed" else "failed")
        }
      } else {
        cluster <- parallel::makePSOCKcluster(workers)
        on.exit(parallel::stopCluster(cluster), add = TRUE)
        parallel::clusterCall(cluster, function(loader) { Sys.setenv(OMP_NUM_THREADS = "1", OPENBLAS_NUM_THREADS = "1", MKL_NUM_THREADS = "1"); source(loader, local = .GlobalEnv); NULL }, file.path(bmp_repo_root, "R", "load.R"))
        calculated <- parallel::parLapply(cluster, splits[pending], function(split, data, config, run) bmp_fold_task(split, data, config, run), data, config, run)
        for (j in seq_along(pending)) results[[pending[j]]] <- calculated[[j]]
      }
    }
    failed <- Filter(function(result) !is.null(result$error), results)
    good <- Filter(function(result) is.null(result$error), results)
    failure_records <- lapply(failed, function(result) list(split_id = result$split$id, reason = result$error))
    bmp_atomic_json(list(schema_version = 1L, method = "repeated_nested_grouped_cross_validation", outer = splits, inner = stats::setNames(lapply(good, function(fold) fold$inner$splits), vapply(good, function(fold) fold$split$id, character(1)))), file.path(run$dir, "splits.json"))
    if (length(good)) {
      predictions <- do.call(rbind, lapply(good, function(fold) fold$predictions))
      bmp_atomic_csv(predictions, file.path(run$dir, "predictions.csv"))
      bmp_atomic_json(stats::setNames(lapply(good, function(fold) list(primary_arm_id = fold$primary_arm_id, models = fold$models, inner_summary = fold$inner$summary, failed_arms = fold$failed_arms)), vapply(good, function(fold) fold$split$id, character(1))), file.path(run$dir, "fold_models.json"))
      for (fold in good) bmp_atomic_json(fold$screening, file.path(run$dir, "screening", paste0(fold$split$id, ".json")))
      stability <- bmp_stability_records(good, config$gene_columns)
      comparison <- bmp_comparison_records(good, data, config)
      overlap <- bmp_panel_overlap(good)
      bmp_atomic_csv(stability, file.path(run$dir, "stability.csv"))
      bmp_atomic_csv(comparison, file.path(run$dir, "model_comparison.csv"))
      bmp_atomic_csv(comparison, file.path(run$dir, "panel_comparison.csv"))
      bmp_atomic_csv(overlap, file.path(run$dir, "panel_overlap.csv"))
    }
    if (length(failed)) {
      run <- bmp_update_manifest(run, "partial", stage = "nested_validation", failed_folds = failure_records, checkpoint_reused = reused, completed_folds = length(good), errors = "One or more primary outer folds failed; incomplete assessment cannot be reported as a successful run.")
      stop(structure(list(message = "Nested validation failed in one or more outer folds; see manifest.failed_folds.", call = NULL), class = c("bmp_partial_engine_error", "error", "condition")))
    }
    final_split <- list(id = "final", train = I(seq_len(nrow(data))), seed = bmp_seed(config$seed, 900000))
    final_checkpoint <- if (resume) bmp_checkpoint_read(run, final_split) else NULL
    bmp_engine_event("final_fit", run_id = run$id, run_dir = run$dir, reused = !is.null(final_checkpoint))
    if (is.null(final_checkpoint)) {
      final <- bmp_fit_final(data, config)
      portable_final <- list(model = list(artifact = final$model$artifact), inner = final$inner, screening = final$screening)
      bmp_checkpoint_write(list(split = final_split, primary_arm_id = "final", models = list(final = final$model$artifact), payload = portable_final), run)
    } else final <- final_checkpoint$payload
    final$model$artifact$run_id <- run$id
    final$model$artifact$created_at <- run$manifest$created_at
    final$model$artifact$config_version <- config$config_version
    final$model$artifact$config_sha256 <- run$manifest$provenance$config_sha256
    final$model$artifact$provenance <- run$manifest$provenance
    bmp_save_model(final$model, file.path(run$dir, "model.bmpmodel"))
    bmp_atomic_json(final$screening, file.path(run$dir, "screening", "final.json"))
    bmp_atomic_json(list(metric = if (config$analysis_type == "binary") "roc_auc" else "harrell_c", interpretation = "Exploratory development selection; no independent final-model estimate", summary = final$inner$summary, splits = final$inner$splits, selected_candidate = final$inner$candidates[[final$inner$primary_index]]), file.path(run$dir, "final_selection.json"))
    ranking <- bmp_screen_statistics(data, config, config$gene_columns)
    ranking$statistic_method <- rep(if (config$analysis_type == "binary") "Welch t on patient means: positive minus negative class" else "Cluster-robust univariate Cox Wald z statistic", nrow(ranking))
    ranking$interpretation <- rep("Exploratory full-development training statistic; never used for outer assessment", nrow(ranking))
    bmp_atomic_csv(ranking, file.path(run$dir, "gene_ranking.csv"))
    warnings <- unique(c(validated$qc$warnings, final$model$artifact$warnings, unlist(lapply(good, function(fold) unlist(lapply(fold$models, function(model) model$warnings))))))
    engine_paths <- c("config.json", "qc.json", "splits.json", "predictions.csv", "model.bmpmodel", "stability.csv", "model_comparison.csv", "panel_comparison.csv", "fold_models.json", "final_selection.json", "panel_overlap.csv", "gene_ranking.csv")
    screening_paths <- c(file.path("screening", paste0(vapply(good, function(fold) fold$split$id, character(1)), ".json")), "screening/final.json")
    engine_paths <- c(engine_paths, screening_paths)
    engine_verification <- bmp_verify_artifacts(run$dir, engine_paths)
    if (!engine_verification$ok) stop("Engine artifact verification failed before reporting.", call. = FALSE)
    run <- bmp_update_manifest(run, "running", stage = "metrics_and_reports_pending", required_artifacts = unique(c(bmp_strings(run$manifest$required_artifacts), screening_paths)), engine_artifact_verification = engine_verification, final_checkpoint_reused = !is.null(final_checkpoint), completed_folds = length(good), failed_folds = failure_records, checkpoint_reused = reused, workers_used = workers, warnings = warnings, model_path = file.path(run$dir, "model.bmpmodel"), primary_estimate = "Nested assessment of inner-selected modeling procedure", comparison_interpretation = "Fixed-arm comparisons are descriptive; best outer arm is not an unbiased selected-model estimate")
    bmp_engine_event("engine_finished", run_id = run$id, run_dir = run$dir, current = length(good), total = length(splits), status = "metrics_and_reports_pending")
    list(run = run, predictions = predictions, splits = splits, folds = good, model = final$model$artifact, final_inner = final$inner, stability = stability, panel_comparison = comparison, model_comparison = comparison, panel_overlap = overlap, checkpoint_reused = reused)
  }, interrupt = function(error) {
    bmp_update_manifest(run, "cancelled", stage = "engine", errors = "Analysis interrupted; completed compatible fold checkpoints can be resumed.")
    stop(error)
  }, error = function(error) {
    if (!inherits(error, "bmp_partial_engine_error")) bmp_update_manifest(run, "failed", stage = "engine", errors = conditionMessage(error))
    stop(error)
  })
}
