#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", args[grepl("^--file=", args)])
root <- normalizePath(file.path(dirname(script), ".."), mustWork = TRUE)
source(file.path(root, "R", "load.R"))
assert <- function(value, message) if (!isTRUE(value)) stop(message, call. = FALSE)
expect_error <- function(expr, pattern = NULL) {
  result <- tryCatch({ force(expr); NULL }, error = function(e) e)
  assert(inherits(result, "error"), "Expected an error")
  if (!is.null(pattern)) assert(grepl(pattern, conditionMessage(result), fixed = TRUE), conditionMessage(result))
  invisible(result)
}
fixture <- function(type) {
  config <- bmp_load_config(file.path(root, "tests", "fixtures", paste0(type, ".json")))
  config$output_dir <- tempfile(paste0("bmp-engine-", type, "-"))
  config$alpha_grid <- 1
  config$p_threshold <- 1
  config$p_adjust_method <- "none"
  config$selection_frequency <- .5
  bmp_validate_data(config)
}
curve <- bmp_censor_curve(c(1,1,2,3), c(1,0,1,0))
assert(isTRUE(all.equal(as.numeric(curve$survival), c(2/3,2/3,0), tolerance = 1e-12)), "Reverse KM event/censor tie convention is wrong")
binary <- fixture("binary")
set.seed(170); before <- .Random.seed
splits <- bmp_make_splits(binary$data, binary$config)
assert(identical(.Random.seed, before), "Resampling changed caller RNG")
assert(identical(splits, bmp_make_splits(binary$data, binary$config)), "Splits are not deterministic")
for (split in splits) {
  assert(!length(intersect(split$train_groups, split$assessment_groups)), "Outer groups overlap")
  train <- binary$data[split$train, , drop = FALSE]
  inner <- bmp_make_splits(train, binary$config, folds = binary$config$inner_folds, repeats = 1, seed = split$seed)
  for (fold in inner) assert(!length(intersect(fold$train_groups, fold$assessment_groups)), "Inner groups overlap")
}
# Outer assessment perturbations cannot change preprocessing, chosen algorithm,
# candidate hyperparameters, coefficients or threshold for this fixed split.
original <- bmp_fit_outer_fold(binary$data, binary$config, splits[[1]])
changed <- binary$data
held <- splits[[1]]$assessment
changed[held, binary$config$gene_columns] <- lapply(changed[held, binary$config$gene_columns, drop = FALSE], function(x) ifelse(is.na(x), 99, x * -100 + 23))
changed[[binary$config$outcome]][held] <- ifelse(changed[[binary$config$outcome]][held] == binary$config$positive_class, binary$config$negative_class, binary$config$positive_class)
perturbed <- bmp_fit_outer_fold(changed, binary$config, splits[[1]])
assert(identical(bmp_hash_object(original$models), bmp_hash_object(perturbed$models)), "Outer assessment leaked into model fitting")
assert(identical(original$primary_arm_id, perturbed$primary_arm_id), "Outer assessment changed model choice")
# Clinical typing comes only from training values, ignoring global QC metadata.
typed <- binary$config; typed$clinical_types <- list(age = "categorical", sex = "numeric")
recipe <- bmp_fit_recipe(binary$data[splits[[1]]$train, ], typed, "combined", 3)
assert(recipe$predictors$age$type == "numeric" && recipe$predictors$sex$type == "categorical", "Recipe used global clinical inference")
# Extremely stringent prescreen yields an honest null baseline.
null_config <- binary$config; null_config$p_threshold <- 1e-100; null_config$feature_sets <- "genes"
null_arm <- list(algorithm = "stepwise", feature_set = "genes", panel_size = 1, arm_id = "null", alpha = NULL, lambda_ratio = NULL)
null_fit <- bmp_fit_model(binary$data, null_config, null_arm)
assert(length(unlist(null_fit$artifact$selected_genes)) == 0, "Prescreen silently added a fallback gene")
null_fit$artifact$threshold <- .5
null_path <- tempfile(fileext = ".bmpmodel"); bmp_save_model(null_fit, null_path)
assert(all(abs(bmp_predict_model(bmp_load_model(null_path), binary$data)$probability - .5) < 1e-10), "Null logistic predictions are incorrect")
invalid <- bmp_load_model(null_path); invalid$features <- "scalar"
expect_error(bmp_validate_model(invalid), "must be a JSON array")
# Forced genes have explicit conflicts and cannot silently disappear.
forced <- null_config; forced$include <- "constant"
expect_error(bmp_fit_model(binary$data, forced, null_arm), "Forced gene")
cat("Grouped splits, RNG restoration, perturbation isolation, typing, null/forced-gene checks passed\n")
run <- bmp_new_run(binary$config, binary$qc)
binary_result <- bmp_run_engine(binary, run)
manifest <- bmp_read_json(file.path(run$dir, "manifest.json"))
assert(manifest$status == "running" && manifest$stage == "metrics_and_reports_pending", "Engine falsely completed run")
assert(sum(binary_result$predictions$role == "primary") == nrow(binary$data), "Primary assessment must contain every row once per repeat")
assert(length(unique(binary_result$predictions$arm_id[binary_result$predictions$role == "fixed_arm"])) == 10, "Fixed-arm comparison omitted requested arms")
assert(all(is.finite(binary_result$predictions$probability)), "Nonfinite assessment probability")
final_native <- bmp_fit_final(binary$data, binary$config)$model
final_artifact <- bmp_load_model(file.path(run$dir, "model.bmpmodel"))
assert(max(abs(bmp_predict_model(final_artifact, binary$data)$linear_predictor - final_native$native_lp)) < 1e-10, "Final JSON predictions differ from native fit")
# A changed checkpoint is rejected, never silently recomputed or overwritten.
checkpoint <- file.path(run$dir, "checkpoints", paste0(splits[[1]]$id, ".rds"))
backup <- readBin(checkpoint, "raw", n = file.info(checkpoint)$size)
cat("tamper", file = checkpoint, append = TRUE)
expect_error(bmp_checkpoint_read(run, splits[[1]]), "integrity")
writeBin(backup, checkpoint)
old_hash <- bmp_sha256(file.path(run$dir, "model.bmpmodel"))
resumed <- bmp_run_engine(binary, run, resume = TRUE)
assert(length(resumed$checkpoint_reused) == length(splits), "Resume did not reuse all compatible folds")
assert(identical(old_hash, bmp_sha256(file.path(run$dir, "model.bmpmodel"))), "Compatible resume changed final model bytes")
assert(isTRUE(bmp_read_json(file.path(run$dir, "manifest.json"))$final_checkpoint_reused), "Resume did not reuse the final fitting checkpoint")
original_predictions <- readBin(file.path(run$dir, "predictions.csv"), "raw", n = file.info(file.path(run$dir, "predictions.csv"))$size)
cat("tamper", file = file.path(run$dir, "predictions.csv"), append = TRUE)
expect_error(bmp_run_engine(binary, run, resume = TRUE), "changed or removed")
writeBin(original_predictions, file.path(run$dir, "predictions.csv"))
assert(isTRUE(all.equal(binary_result$predictions, resumed$predictions, tolerance = 1e-12)), "Resume changed predictions")
# Worker scheduling must not change a split, fitted result or output row order.
parallel_data <- binary; parallel_data$config$workers <- 2L; parallel_data$config$output_dir <- tempfile("bmp-engine-parallel-")
parallel_run <- bmp_new_run(parallel_data$config, parallel_data$qc)
parallel_result <- bmp_run_engine(parallel_data, parallel_run)
assert(isTRUE(all.equal(binary_result$predictions, parallel_result$predictions, tolerance = 1e-12)), "Serial/parallel results differ")
assert(identical(bmp_hash_object(binary_result$splits), bmp_hash_object(parallel_result$splits)), "Serial/parallel splits differ")
cat("Binary full engine, artifact, resume integrity and parallel-equivalence checks passed\n")
survival <- fixture("survival")
survival_run <- bmp_new_run(survival$config, survival$qc)
survival_result <- bmp_run_engine(survival, survival_run)
assert(sum(survival_result$predictions$role == "primary") == nrow(survival$data), "Survival assessment omitted rows")
model <- bmp_load_model(file.path(survival_run$dir, "model.bmpmodel"))
invalid <- model; invalid$baseline$reference_lp <- NULL
expect_error(bmp_validate_model(invalid), "baseline hazard")
if (length(unlist(model$features))) {
  numeric_names <- names(Filter(function(spec) spec$type == "numeric", model$recipe$predictors))
  numeric_names <- intersect(numeric_names, unlist(model$features))
  if (length(numeric_names)) {
    invalid <- model; invalid$recipe$predictors[[numeric_names[1]]]$median <- NULL
    expect_error(bmp_validate_model(invalid), "numeric encoder")
  }
}
full <- bmp_predict_model(model, survival$data, horizons = c(0, 1, 3, 10))
probabilities <- attr(full, "survival_probabilities")
assert(all(probabilities >= 0 & probabilities <= 1) && all(probabilities[, 1] == 1), "Invalid survival probability")
assert(all(apply(probabilities, 1, function(row) all(diff(row) <= 0))), "Survival probabilities increase with time")
one <- bmp_predict_model(model, survival$data[1, , drop = FALSE], horizons = c(0, 1, 3, 10))
assert(identical(one$risk_group, full$risk_group[1]) && abs(one$risk - full$risk[1]) < 1e-12, "Survival prediction depends on batch")
assert(max(abs(attr(one, "survival_probabilities") - probabilities[1, , drop = FALSE])) < 1e-12, "Survival probability depends on batch")
fold_models <- bmp_read_json(file.path(survival_run$dir, "fold_models.json"))
for (fold in fold_models) for (model in fold$models) {
  assert(length(unlist(model$training$censor_curve$time)) > 0, "Fold censor curve absent")
  assert(length(unlist(model$training$time_range)) == 2, "Fold support interval absent")
}
ranking <- bmp_read_csv(file.path(survival_run$dir, "gene_ranking.csv"))
assert(setequal(ranking$gene, survival$config$gene_columns), "Full-development gene ranking lost measured eligible genes")
cat("Survival full engine, monotonic survival, batch invariance and fold censor metadata checks passed\n")
cat("All stage-2 engine tests passed.\n")
