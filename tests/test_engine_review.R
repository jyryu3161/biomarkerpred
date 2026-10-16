# Independent primary-session acceptance tests. Run with the locked R runtime.
script <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())][1L])
repo <- dirname(dirname(normalizePath(script, mustWork = TRUE)))
source(file.path(repo, "R", "load.R"))
fail_with <- function(expression, pattern) {
  error <- tryCatch({ force(expression); NULL }, error = identity)
  stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error), ignore.case = TRUE))
}
same <- function(a, b, tolerance = 1e-9) stopifnot(isTRUE(all.equal(a, b, tolerance = tolerance, check.attributes = FALSE)))

for (type in c("binary", "survival")) {
  validated <- bmp_validate_data(file.path(repo, "tests", "fixtures", paste0(type, ".json")))
  config <- validated$config
  data <- validated$data
  config$positive_label <- "Clinical response"
  config$negative_label <- "No clinical response"
  for (algorithm in c("stepwise", "elastic_net")) {
    arm <- list(algorithm = algorithm, feature_set = "combined", panel_size = 3L,
      alpha = .5, lambda_ratio = .1, arm_id = paste(type, algorithm))
    fit <- bmp_fit_model(data, config, arm)
    # This unit check concerns serialization, not threshold estimation. Nested
    # threshold provenance is checked separately in the complete engine tests.
    if (type == "binary") {
      fit$artifact$threshold <- .5
      fit$artifact$threshold_method <- "unit-test constant"
    }
    native <- bmp_predict_model(fit, data)
    same(native$linear_predictor, fit$native_lp)
    path <- tempfile(fileext = ".bmpmodel")
    bmp_save_model(fit, path)
    restored <- bmp_load_model(path)
    predictions <- bmp_predict_model(restored, data)
    same(native, predictions)
    sample <- bmp_predict_model(restored, data[17, , drop = FALSE])
    same(sample$linear_predictor, predictions$linear_predictor[17])
    stopifnot(identical(predictions$sample_id[1], "0001"))
    reordered <- bmp_predict_model(restored, data[rev(seq_len(nrow(data))), rev(names(data)), drop = FALSE])
    same(reordered$linear_predictor, rev(predictions$linear_predictor))
    no_outcomes <- data[, setdiff(names(data), c(config$outcome, config$event, config$time_variable)), drop = FALSE]
    same(bmp_predict_model(restored, no_outcomes)$linear_predictor, predictions$linear_predictor)
    bad <- data
    bad$sex[17] <- "unseen-category"
    fail_with(bmp_predict_model(restored, bad), "unseen category")
    fail_with(bmp_predict_model(restored, data[, setdiff(names(data), "age"), drop = FALSE]), "predictors not found")
    malformed <- restored
    malformed$recipe$predictors$age$scale <- 0
    fail_with(bmp_validate_model(malformed), "numeric encoder")
    if (type == "binary") {
      stopifnot(all(predictions$predicted_label %in% c("Clinical response", "No clinical response")))
      same(sample$probability, predictions$probability[17])
      stopifnot(identical(sample$predicted_class, predictions$predicted_class[17]))
    } else {
      same(sample$survival_probability, predictions$survival_probability[17])
      stopifnot(identical(sample$risk_group, predictions$risk_group[17]))
      survival <- attr(bmp_predict_model(restored, data, horizons = c(0, 1, 3, 5)), "survival_probabilities")
      stopifnot(all(survival >= 0 & survival <= 1), all(apply(survival, 1, diff) <= 0), all(survival[, 1] == 1))
      if (fit$native_kind == "coxph") {
        baseline <- survival::basehaz(fit$native, centered = FALSE)
        h0 <- if (any(baseline$time <= config$horizon)) tail(baseline$hazard[baseline$time <= config$horizon], 1) else 0
        same(predictions$survival_probability, exp(-h0 * exp(fit$native_lp)))
      }
    }
    cat(type, algorithm, "native/JSON/column-order/single-batch checks passed\n")
  }

  # A stringent declared screen yields a real null model, rather than quietly
  # introducing the best available gene after observing a failed screen.
  null_config <- config
  null_config$p_threshold <- 1e-100
  null_arm <- list(algorithm = "stepwise", feature_set = "genes", panel_size = 1L,
    alpha = 1, lambda_ratio = .1, arm_id = paste0(type, "-null"))
  null_model <- bmp_fit_model(data, null_config, null_arm)
  stopifnot(length(null_model$artifact$selected_genes) == 0L, length(null_model$artifact$features) == 0L)
  null_predictions <- bmp_predict_model(null_model, data)
  stopifnot(length(unique(null_predictions$linear_predictor)) == 1L)

  # The fixed split is essential: assessment rows become training rows in
  # other folds, so isolation is asserted only for this particular outer fit.
  nested_config <- config
  nested_config$alpha_grid <- .5
  nested_config$panel_sizes <- 1L
  nested_config$feature_sets <- c("genes", "combined")
  splits <- bmp_make_splits(data, nested_config)
  stopifnot(length(splits) == config$outer_folds * config$repeats)
  for (partition in splits) {
    stopifnot(!length(intersect(partition$train_groups, partition$assessment_groups)),
      !length(intersect(partition$train, partition$assessment)),
      setequal(c(partition$train, partition$assessment), seq_len(nrow(data))))
  }
  split <- splits[[1L]]
  original <- bmp_fit_outer_fold(data, nested_config, split)
  modified <- data
  held_out <- as.integer(split$assessment)
  for (gene in config$gene_columns) modified[[gene]][held_out] <- modified[[gene]][held_out] * -2 + 100
  modified$age[held_out] <- modified$age[held_out] + 20
  if (type == "binary") modified[[config$outcome]][held_out] <- ifelse(
    modified[[config$outcome]][held_out] == config$positive_class, config$negative_class, config$positive_class)
  else {
    modified[[config$time_variable]][held_out] <- modified[[config$time_variable]][held_out] * 1.5
    modified[[config$event]][held_out] <- 1 - modified[[config$event]][held_out]
  }
  perturbed <- bmp_fit_outer_fold(modified, nested_config, split)
  stopifnot(identical(bmp_hash_object(original$models), bmp_hash_object(perturbed$models)),
    identical(bmp_hash_object(original$inner), bmp_hash_object(perturbed$inner)),
    identical(original$primary_arm_id, perturbed$primary_arm_id))
  primary <- original$predictions[original$predictions$role == "primary", , drop = FALSE]
  stopifnot(nrow(primary) == length(held_out), length(unique(primary$arm_id)) == 1L)
  outer_training <- data[as.integer(split$train), , drop = FALSE]
  for (inner in original$inner$splits) {
    train_groups <- bmp_groups(outer_training[inner$train, , drop = FALSE], config)
    assess_groups <- bmp_groups(outer_training[inner$assessment, , drop = FALSE], config)
    stopifnot(!length(intersect(train_groups, assess_groups)),
      !length(intersect(c(train_groups, assess_groups), split$assessment_groups)))
  }
  cat(type, "fixed-outer-split perturbation and inner/outer patient isolation passed\n")
}
cat("Primary-session model acceptance checks passed.\n")
