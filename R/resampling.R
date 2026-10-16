# All randomized operations restore the caller's RNG and derive independent seeds
# from declared seeds/fold identities. No rejection loop is unbounded.
bmp_partition_valid <- function(data, config, rows) {
  if (!length(rows)) return(FALSE)
  if (config$analysis_type == "binary") length(unique(as.character(data[[config$outcome]][rows]))) == 2L else any(data[[config$event]][rows] == 1)
}
bmp_make_splits <- function(data, config, folds = config$outer_folds, repeats = config$repeats, seed = config$seed) {
  groups <- bmp_groups(data, config); unique_groups <- sort(unique(groups))
  strata <- if (config$analysis_type == "binary") vapply(unique_groups, function(group) as.character(data[[config$outcome]][match(group, groups)]), character(1)) else vapply(unique_groups, function(group) if (any(data[[config$event]][groups == group] == 1)) "event" else "censored", character(1))
  if (length(unique_groups) < folds) stop("Fewer independent groups than requested folds.", call. = FALSE)
  output <- list()
  for (repeat_id in seq_len(repeats)) {
    found <- FALSE
    for (attempt in seq_len(100L)) {
      assigned <- bmp_with_seed(bmp_seed(seed, repeat_id * 1000 + attempt), {
        allocation <- stats::setNames(integer(length(unique_groups)), unique_groups)
        loads <- integer(folds)
        for (stratum in sort(unique(strata))) {
          candidates <- unique_groups[strata == stratum]
          candidates <- candidates[sample.int(length(candidates))]
          # Balanced group counts within each stratum; rotate to balance total rows.
          offset <- which.min(loads) - 1L
          for (j in seq_along(candidates)) {
            fold <- ((j - 1L + offset) %% folds) + 1L
            allocation[candidates[j]] <- fold
            loads[fold] <- loads[fold] + sum(groups == candidates[j])
          }
        }
        allocation
      })
      assessment <- lapply(seq_len(folds), function(fold) which(assigned[groups] == fold))
      valid <- vapply(assessment, function(rows) bmp_partition_valid(data, config, rows) && bmp_partition_valid(data, config, setdiff(seq_len(nrow(data)), rows)), logical(1))
      if (all(valid)) { found <- TRUE; break }
    }
    if (!found) stop("Could not construct valid grouped folds after 100 deterministic attempts. Reduce folds or revise cohort eligibility.", call. = FALSE)
    for (fold in seq_len(folds)) {
      test <- assessment[[fold]]; train <- setdiff(seq_len(nrow(data)), test)
      output[[length(output) + 1L]] <- list(id = sprintf("r%02d_f%02d", repeat_id, fold), repeat_id = repeat_id, fold = fold,
        train = I(train), assessment = I(test), train_groups = I(sort(unique(groups[train]))), assessment_groups = I(sort(unique(groups[test]))), seed = bmp_seed(seed, repeat_id * 100 + fold))
    }
  }
  output
}
bmp_auc_score <- function(y, probability) {
  if (length(unique(y)) != 2L || any(!is.finite(probability))) return(NA_real_)
  positive <- sum(y == 1); negative <- sum(y == 0)
  (sum(rank(probability, ties.method = "average")[y == 1]) - positive * (positive + 1)/2)/(positive * negative)
}
bmp_selection_score <- function(data, prediction, config) {
  if (config$analysis_type == "binary") return(bmp_auc_score(as.integer(as.character(data[[config$outcome]]) == config$positive_class), prediction$probability))
  tryCatch(as.numeric(survival::concordance(survival::Surv(data[[config$time_variable]], data[[config$event]]) ~ prediction$linear_predictor, reverse = TRUE)$concordance), error = function(e) NA_real_)
}
bmp_fit_threshold <- function(y, probability, groups = seq_along(y)) {
  if (length(unique(y)) != 2L || any(!is.finite(probability))) stop("Cannot learn threshold without complete inner held-out predictions from both classes.", call. = FALSE)
  weight <- 1/as.numeric(table(groups)[as.character(groups)])
  thresholds <- sort(unique(c(0, probability, 1)))
  youden <- vapply(thresholds, function(threshold) sum(weight[y == 1] * (probability[y == 1] >= threshold))/sum(weight[y == 1]) + sum(weight[y == 0] * (probability[y == 0] < threshold))/sum(weight[y == 0]) - 1, numeric(1))
  thresholds[order(-youden, abs(thresholds - .5), thresholds)[1L]]
}
bmp_model_arms <- function(config) {
  arms <- list()
  for (feature_set in config$feature_sets) for (algorithm in config$models) {
    panels <- if (feature_set == "clinical") 0L else config$panel_sizes
    for (panel in panels) {
      id <- paste(algorithm, feature_set, paste0("p", panel), sep = "__")
      if (algorithm == "elastic_net") {
        for (alpha in config$alpha_grid) for (ratio in c(1, .1, .01, .001)) arms[[length(arms) + 1L]] <- list(arm_id = id, candidate_id = paste(id, alpha, ratio, sep = "__"), algorithm = algorithm, feature_set = feature_set, panel_size = panel, alpha = alpha, lambda_ratio = ratio)
      } else arms[[length(arms) + 1L]] <- list(arm_id = id, candidate_id = id, algorithm = algorithm, feature_set = feature_set, panel_size = panel, alpha = NULL, lambda_ratio = NULL)
    }
  }
  arms
}
bmp_inner_select <- function(data, config, seed = config$seed) {
  splits <- bmp_make_splits(data, config, folds = config$inner_folds, repeats = 1L, seed = seed)
  candidates <- bmp_model_arms(config)
  scores <- matrix(NA_real_, nrow = length(candidates), ncol = length(splits))
  actual <- scores; failures <- matrix("", nrow = nrow(scores), ncol = ncol(scores))
  oof <- lapply(candidates, function(x) rep(NA_real_, nrow(data)))
  screening <- list()
  for (fold in seq_along(splits)) {
    split <- splits[[fold]]; train <- data[split$train, , drop = FALSE]; assessment <- data[split$assessment, , drop = FALSE]
    recipes <- bmp_fit_recipes(train, config, split$seed)
    screening[[split$id]] <- bmp_recipe_audit(recipes)
    for (candidate in seq_along(candidates)) {
      arm <- candidates[[candidate]]
      tryCatch({
        recipe <- recipes[[arm$feature_set]]
        if (inherits(recipe, "error")) stop(recipe)
        fit <- bmp_fit_model(train, config, arm, split$seed, recipe)
        prediction <- bmp_predict_model(fit, assessment)
        score <- bmp_selection_score(assessment, prediction, config)
        if (!is.finite(score)) stop("Selection metric is unavailable in this inner assessment fold.")
        scores[candidate, fold] <- score
        actual[candidate, fold] <- fit$artifact$actual_gene_count
        oof[[candidate]][split$assessment] <- if (config$analysis_type == "binary") prediction$probability else prediction$linear_predictor
      }, error = function(error) { failures[candidate, fold] <<- conditionMessage(error) })
    }
  }
  complete <- rowSums(is.finite(scores)) == length(splits)
  mean_score <- rowMeans(scores); mean_score[!complete] <- NA_real_
  summary <- do.call(rbind, lapply(seq_along(candidates), function(i) data.frame(candidate_id = candidates[[i]]$candidate_id, arm_id = candidates[[i]]$arm_id, algorithm = candidates[[i]]$algorithm, feature_set = candidates[[i]]$feature_set, panel_size = candidates[[i]]$panel_size, alpha = if (is.null(candidates[[i]]$alpha)) NA_real_ else candidates[[i]]$alpha, lambda_ratio = if (is.null(candidates[[i]]$lambda_ratio)) NA_real_ else candidates[[i]]$lambda_ratio, mean_score = mean_score[i], mean_actual_genes = mean(actual[i, ]), completed_folds = sum(is.finite(scores[i, ])), failures = paste(unique(failures[i, nzchar(failures[i, ])]), collapse = " | "), stringsAsFactors = FALSE)))
  rank <- order(-summary$mean_score, summary$mean_actual_genes, summary$panel_size, summary$candidate_id, na.last = NA)
  if (!length(rank)) stop(paste("Every candidate failed inner validation:", paste(unique(summary$failures), collapse = " | ")), call. = FALSE)
  chosen <- rank[!duplicated(summary$arm_id[rank])]
  thresholds <- lapply(chosen, function(i) if (config$analysis_type == "binary") bmp_fit_threshold(as.integer(as.character(data[[config$outcome]]) == config$positive_class), oof[[i]], bmp_groups(data, config)) else NULL)
  names(thresholds) <- summary$arm_id[chosen]
  list(splits = splits, candidates = candidates, summary = summary, selected_indices = chosen, primary_index = rank[1L], thresholds = thresholds, oof = oof, fold_scores = scores, screening = screening)
}
bmp_prediction_records <- function(model, data, config, split, role) {
  predictions <- bmp_predict_model(model, data)
  artifact <- bmp_model_artifact(model)
  predictions$group_id <- bmp_groups(data, config)
  predictions$repeat_id <- split$repeat_id; predictions$fold <- split$fold; predictions$split_id <- split$id
  predictions$role <- role; predictions$arm_id <- artifact$arm_id; predictions$algorithm <- artifact$algorithm
  predictions$feature_set <- artifact$feature_set; predictions$panel_size <- artifact$panel_size; predictions$actual_gene_count <- artifact$actual_gene_count
  predictions$observed <- if (config$analysis_type == "binary") as.character(data[[config$outcome]]) else as.character(data[[config$event]])
  predictions$outcome_binary <- if (config$analysis_type == "binary") as.integer(predictions$observed == config$positive_class) else NA_integer_
  predictions$time <- if (config$analysis_type == "survival") data[[config$time_variable]] else NA_real_
  predictions$event <- if (config$analysis_type == "survival") data[[config$event]] else NA_integer_
  attr(predictions, "survival_probabilities") <- NULL; attr(predictions, "horizons") <- NULL
  predictions
}
bmp_fit_outer_fold <- function(data, config, split) {
  train <- data[as.integer(unlist(split$train)), , drop = FALSE]; assessment <- data[as.integer(unlist(split$assessment)), , drop = FALSE]
  if (length(intersect(bmp_groups(train, config), bmp_groups(assessment, config)))) stop("Patient groups overlap in outer split.", call. = FALSE)
  selected <- bmp_inner_select(train, config, seed = split$seed)
  recipes <- bmp_fit_recipes(train, config, bmp_seed(split$seed, 999))
  models <- list(); predictions <- list(); failures <- list()
  primary_id <- selected$candidates[[selected$primary_index]]$arm_id
  for (index in selected$selected_indices) {
    arm <- selected$candidates[[index]]
    result <- tryCatch({
      recipe <- recipes[[arm$feature_set]]; if (inherits(recipe, "error")) stop(recipe)
      fitted <- bmp_fit_model(train, config, arm, bmp_seed(split$seed, 999), recipe)
      if (config$analysis_type == "binary") {
        fitted$artifact$threshold <- selected$thresholds[[arm$arm_id]]
        fitted$artifact$threshold_method <- "patient-weighted Youden threshold from inner out-of-fold predictions for the selected candidate"
      }
      fitted$artifact$selection <- list(method = "inner_grouped_cross_validation", metric = if (config$analysis_type == "binary") "roc_auc" else "harrell_c", candidate_id = arm$candidate_id, score = selected$summary$mean_score[index])
      bmp_validate_model(fitted$artifact)
      pred <- bmp_prediction_records(fitted, assessment, config, split, "fixed_arm")
      list(model = fitted$artifact, predictions = pred)
    }, error = function(error) list(error = conditionMessage(error)))
    if (!is.null(result$error)) {
      failures[[arm$arm_id]] <- result$error
      if (identical(arm$arm_id, primary_id)) stop(paste("Primary selected arm failed outer prediction:", result$error), call. = FALSE)
    } else {
      models[[arm$arm_id]] <- result$model
      predictions[[length(predictions) + 1L]] <- result$predictions
      if (identical(arm$arm_id, primary_id)) {
        primary <- result$predictions; primary$role <- "primary"
        predictions[[length(predictions) + 1L]] <- primary
      }
    }
  }
  list(split = split, primary_arm_id = primary_id, models = models, predictions = do.call(rbind, predictions), inner = list(splits = selected$splits, summary = selected$summary, metric = if (config$analysis_type == "binary") "roc_auc" else "harrell_c"), failed_arms = failures,
    screening = list(inner = selected$screening, fitting = bmp_recipe_audit(recipes)))
}
