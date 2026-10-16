# Assessment-only metrics. No function in this module fits a prediction model,
# chooses its threshold, or reads the original development outcomes.
bmp_metric_cell <- function(estimate = NA_real_, reason = NULL, method = NULL, ...) {
  if (length(estimate) != 1L || !is.finite(estimate)) estimate <- NA_real_
  if (is.na(estimate) && is.null(reason)) reason <- "Estimate unavailable."
  list(estimate = estimate, lower = NA_real_, upper = NA_real_, reason = reason, method = method, ...)
}
bmp_metric_weights <- function(n, weights = NULL) {
  if (is.null(weights)) weights <- rep(1, n)
  if (length(weights) != n || any(!is.finite(weights) | weights <= 0)) stop("Metric weights must be finite and positive for every row.", call. = FALSE)
  weights
}
bmp_metric_ratio <- function(numerator, denominator, method, reason = "No observations in the required denominator.") {
  bmp_metric_cell(if (denominator > 0) numerator/denominator else NA_real_, if (denominator > 0) NULL else reason, method)
}
bmp_metric_methods <- function() list(
  average_precision = "Step-wise recall integration: sum(delta recall * precision); not trapezoidal PR area",
  binary = "Sample-weighted within each held-out repeat; equally averaged over repeats; frozen row-specific classification thresholds",
  survival = "Within-fold Harrell comparable-pair and cumulative/dynamic IPCW AUC aggregation; sample-weighted IPCW Brier",
  censoring = "Training reverse Kaplan-Meier: cases use G(event time-), controls use G(horizon); censoring before/equal horizon contributes neither case nor control",
  uncertainty = "Patient-group percentile bootstrap conditional on stored held-out predictions; no retraining and no adjustment for development model-selection uncertainty",
  references = list(
    brier = "https://scikit-survival.readthedocs.io/en/stable/api/generated/sksurv.metrics.brier_score.html",
    time_auc = "https://scikit-survival.readthedocs.io/en/stable/api/generated/sksurv.metrics.cumulative_dynamic_auc.html",
    concordance = "https://stat.ethz.ch/R-manual/R-devel/library/survival/html/concordance.html",
    reverse_km = "https://scikit-survival.readthedocs.io/en/stable/api/generated/sksurv.nonparametric.kaplan_meier_estimator.html"))

# Read everything as character first: IDs, observed class codes and gene names
# must never be guessed as numbers. This is the one public prediction CSV reader.
bmp_read_predictions <- function(path) {
  data <- bmp_read_csv(path)
  numeric_columns <- c("linear_predictor", "probability", "threshold", "risk", "survival_probability", "repeat_id", "fold", "panel_size", "actual_gene_count", "outcome_binary", "time", "event")
  for (name in intersect(numeric_columns, names(data))) {
    value <- suppressWarnings(as.numeric(data[[name]]))
    if (any(!is.na(data[[name]]) & !is.finite(value))) stop(paste("Invalid numeric prediction field:", name), call. = FALSE)
    data[[name]] <- value
  }
  data
}
bmp_binary_curve <- function(y, probability, weights) {
  order <- order(probability, decreasing = TRUE)
  sorted <- probability[order]
  ends <- c(which(diff(sorted) != 0), length(sorted))
  thresholds <- sorted[ends]
  positive <- sum(weights[y == 1]); negative <- sum(weights[y == 0])
  # One sort and cumulative scan; each tied score enters as one complete block.
  tp <- c(0, cumsum(weights[order] * (y[order] == 1))[ends])
  fp <- c(0, cumsum(weights[order] * (y[order] == 0))[ends])
  data.frame(threshold = c(Inf, thresholds), true_positive = tp, false_positive = fp,
    sensitivity = if (positive > 0) tp/positive else NA_real_,
    false_positive_rate = if (negative > 0) fp/negative else NA_real_,
    precision = ifelse(tp + fp > 0, tp/pmax(tp + fp, .Machine$double.eps), 1))
}
bmp_calibration_fit <- function(y, probability, weights) {
  failure <- function(reason) list(calibration_intercept = bmp_metric_cell(reason = reason, method = "Logistic calibration intercept with offset(logit(p))"),
    calibration_slope = bmp_metric_cell(reason = reason, method = "Logistic calibration slope with freely estimated intercept"))
  if (length(unique(y)) < 2L) return(failure("Calibration regression requires both outcome classes."))
  z <- stats::qlogis(pmin(1 - 1e-12, pmax(1e-12, probability)))
  one <- tryCatch(suppressWarnings(stats::glm.fit(matrix(1, length(y), 1), y, weights = weights, offset = z, family = stats::binomial())), error = function(e) NULL)
  two <- if (length(unique(z)) > 1L) tryCatch(suppressWarnings(stats::glm.fit(cbind(1, z), y, weights = weights, family = stats::binomial())), error = function(e) NULL) else NULL
  okay <- function(fit) !is.null(fit) && isTRUE(fit$converged) && !isTRUE(fit$boundary) && all(is.finite(fit$coefficients))
  list(calibration_intercept = bmp_metric_cell(if (okay(one)) unname(one$coefficients[1]) else NA_real_, if (!okay(one)) "Calibration intercept did not converge or has separation." else NULL, "Logistic intercept with offset(logit(p)); diagnostic only; p clipped to [1e-12,1-1e-12]"),
    calibration_slope = bmp_metric_cell(if (okay(two)) unname(two$coefficients[2]) else NA_real_, if (!okay(two)) "Calibration slope unavailable: constant predictions, nonconvergence or separation." else NULL, "Logistic slope with freely estimated intercept; diagnostic only"))
}
bmp_binary_metrics <- function(y, probability, threshold = .5, groups = NULL, weights = NULL, dca_thresholds = seq(.01, .99, .01), curves = TRUE) {
  n <- length(y); weights <- bmp_metric_weights(n, weights)
  if (!n || length(probability) != n || anyNA(y) || any(!y %in% c(0, 1)) || any(!is.finite(probability) | probability < 0 | probability > 1)) stop("Binary metrics require finite probabilities in [0,1] and observed 0/1 outcomes.", call. = FALSE)
  if (length(threshold) == 1L) threshold <- rep(threshold, n)
  if (length(threshold) != n || any(!is.finite(threshold) | threshold < 0 | threshold > 1)) stop("Every prediction requires its frozen threshold in [0,1].", call. = FALSE)
  if (is.null(groups)) groups <- as.character(seq_len(n))
  if (length(groups) != n || anyNA(groups)) stop("Invalid metric group IDs.", call. = FALSE)
  classified <- probability >= threshold
  tp <- sum(weights[y == 1 & classified]); fn <- sum(weights[y == 1 & !classified])
  tn <- sum(weights[y == 0 & !classified]); fp <- sum(weights[y == 0 & classified]); total <- sum(weights)
  curve <- bmp_binary_curve(y, probability, weights)
  both <- tp + fn > 0 && tn + fp > 0
  auc <- if (both) sum(diff(curve$false_positive_rate) * (head(curve$sensitivity, -1) + tail(curve$sensitivity, -1))/2) else NA_real_
  ap <- if (tp + fn > 0) sum(diff(curve$sensitivity) * tail(curve$precision, -1)) else NA_real_
  pc <- pmin(1 - 1e-15, pmax(1e-15, probability))
  metrics <- c(list(
    roc_auc = bmp_metric_cell(auc, if (!both) "ROC AUC requires both outcome classes." else NULL, "Weighted ROC trapezoidal area; tied scores receive half credit"),
    average_precision = bmp_metric_cell(ap, if (!(tp + fn > 0)) "Average precision requires an observed positive outcome." else NULL, bmp_metric_methods()$average_precision),
    brier = bmp_metric_cell(sum(weights * (y - probability)^2)/total, method = "Mean squared probability error"),
    log_loss = bmp_metric_cell(-sum(weights * (y * log(pc) + (1-y) * log1p(-pc)))/total, method = "Binary log loss; p clipped to [1e-15,1-1e-15]"),
    sensitivity = bmp_metric_ratio(tp, tp + fn, "TP/(TP+FN), frozen prediction thresholds"),
    specificity = bmp_metric_ratio(tn, tn + fp, "TN/(TN+FP), frozen prediction thresholds"),
    ppv = bmp_metric_ratio(tp, tp + fp, "TP/(TP+FP), frozen prediction thresholds"),
    npv = bmp_metric_ratio(tn, tn + fn, "TN/(TN+FN), frozen prediction thresholds"),
    f1 = bmp_metric_ratio(2*tp, 2*tp + fp + fn, "2TP/(2TP+FP+FN), frozen prediction thresholds"),
    accuracy = bmp_metric_cell((tp+tn)/total, method = "Correct classification fraction at frozen prediction thresholds"),
    balanced_accuracy = bmp_metric_cell(if (both) (tp/(tp+fn) + tn/(tn+fp))/2 else NA_real_, if (!both) "Balanced accuracy requires both outcome classes." else NULL, "Mean sensitivity and specificity")),
    bmp_calibration_fit(y, probability, weights))
  output <- list()
  if (curves) {
    bins <- cut(probability, breaks = seq(0, 1, .2), include.lowest = TRUE, labels = FALSE)
    calibration <- do.call(rbind, lapply(sort(unique(bins)), function(bin) {
      use <- bins == bin
      data.frame(bin = bin, lower = (bin-1)/5, upper = bin/5, rows = sum(use), groups = length(unique(groups[use])), mean_probability = weighted.mean(probability[use], weights[use]), observed_fraction = weighted.mean(y[use], weights[use]))
    }))
    if (any(!is.finite(dca_thresholds) | dca_thresholds <= 0 | dca_thresholds >= 1)) stop("Decision-curve thresholds must be strictly between zero and one.", call. = FALSE)
    dca <- do.call(rbind, lapply(dca_thresholds, function(t) {
      selected <- probability >= t
      data.frame(threshold = t, model = (sum(weights[y == 1 & selected]) - sum(weights[y == 0 & selected])*t/(1-t))/total,
        treat_all = ((tp+fn) - (tn+fp)*t/(1-t))/total, treat_none = 0)
    }))
    output <- list(roc = curve, pr = data.frame(threshold = curve$threshold, recall = curve$sensitivity, precision = curve$precision),
      calibration = calibration, dca = dca,
      confusion = data.frame(observed = c(0,0,1,1), predicted = c(0,1,0,1), count = c(tn,fp,fn,tp)))
  }
  list(metrics = metrics, curves = output, counts = list(rows = n, groups = length(unique(groups)), positives = sum(y == 1), negatives = sum(y == 0)), warnings = character())
}

bmp_censor_value <- function(curve, at, left = FALSE) {
  times <- as.numeric(unlist(curve$time)); values <- as.numeric(unlist(curve$survival))
  if (!length(times) || length(times) != length(values) || any(!is.finite(c(times, values))) || any(diff(times) <= 0) || any(diff(values) > 0) || any(values < 0 | values > 1)) stop("Invalid stored training censoring curve.", call. = FALSE)
  index <- if (left) vapply(at, function(t) sum(times < t), integer(1)) else findInterval(at, times)
  answer <- rep(1, length(at)); answer[index > 0] <- values[index[index > 0]]
  answer
}
bmp_concordance_pairs <- function(time, event, lp, weights) {
  numerator <- denominator <- 0
  # Comparable pairs are never formed across separate fitted folds. For tied
  # event/censor times the observed event precedes censoring (survival convention).
  for (i in which(event == 1)) {
    j <- which(time > time[i] | (time == time[i] & event == 0))
    if (!length(j)) next
    w <- weights[i] * weights[j]
    denominator <- denominator + sum(w)
    numerator <- numerator + sum(w * (as.numeric(lp[i] > lp[j]) + .5 * as.numeric(lp[i] == lp[j])))
  }
  list(numerator = numerator, denominator = denominator)
}
bmp_km_table <- function(time, event, weights = rep(1, length(time)), label = "All") {
  times <- sort(unique(time)); probability <- 1
  records <- list(data.frame(group = label, time = 0, survival = 1, at_risk = sum(weights), events = 0, censored = 0))
  for (t in times) {
    risk <- sum(weights[time >= t]); d <- sum(weights[time == t & event == 1]); censor <- sum(weights[time == t & event == 0])
    probability <- probability * (1 - d/risk)
    records[[length(records)+1L]] <- data.frame(group = label, time = t, survival = probability, at_risk = risk, events = d, censored = censor)
  }
  do.call(rbind, records)
}
bmp_survival_metrics <- function(time, event, survival_probability, linear_predictor, horizon, censor_curve, support,
                                 groups = NULL, weights = NULL, risk_group = NULL, curves = TRUE) {
  n <- length(time); weights <- bmp_metric_weights(n, weights)
  if (!n || length(event) != n || length(survival_probability) != n || length(linear_predictor) != n || any(!is.finite(time) | time <= 0) || anyNA(event) || any(!event %in% c(0,1)) || any(!is.finite(linear_predictor)) || any(!is.finite(survival_probability) | survival_probability < 0 | survival_probability > 1)) stop("Survival metrics require positive finite times, 0/1 events, finite linear predictors and probabilities in [0,1].", call. = FALSE)
  if (length(horizon) != 1L || !is.finite(horizon) || horizon <= 0) stop("A positive horizon is required.", call. = FALSE)
  if (is.null(groups)) groups <- as.character(seq_len(n))
  if (length(groups) != n || anyNA(groups)) stop("Invalid metric group IDs.", call. = FALSE)
  support <- as.numeric(unlist(support))
  if (length(support) != 2L || any(!is.finite(support)) || support[2] < support[1]) stop("Training follow-up support is required.", call. = FALSE)
  pairs <- bmp_concordance_pairs(time, event, linear_predictor, weights)
  case <- event == 1 & time <= horizon; control <- time > horizon
  g_case <- bmp_censor_value(censor_curve, time[case], left = TRUE); g_h <- bmp_censor_value(censor_curve, horizon)
  reason <- NULL
  if (horizon < support[1] || horizon > support[2]) reason <- "Horizon is outside training follow-up support."
  if (horizon < min(time) || horizon > max(time)) reason <- "Horizon is outside assessment follow-up support."
  if (any(g_case <= 0) || g_h <= 0) reason <- "Training censoring survival is zero at a required IPCW evaluation time."
  case_weight <- rep(0, n); control_weight <- rep(0, n)
  brier_num <- auc_num <- auc_den <- NA_real_
  if (is.null(reason)) {
    case_weight[case] <- weights[case]/g_case; control_weight[control] <- weights[control]/g_h
    brier_num <- sum(case_weight * survival_probability^2 + control_weight * (1-survival_probability)^2)
    auc_num <- 0; auc_den <- sum(case_weight)*sum(control_weight)
    p <- 1 - survival_probability
    for (i in which(case)) auc_num <- auc_num + sum(case_weight[i]*control_weight[control] * (as.numeric(p[i] > p[control]) + .5*as.numeric(p[i] == p[control])))
  }
  auc_reason <- if (!is.null(reason)) reason else if (!any(case) || !any(control)) "Horizon AUC requires an observed event by the horizon and a subject followed beyond it." else NULL
  metrics <- list(harrell_c = bmp_metric_ratio(pairs$numerator, pairs$denominator, "Harrell C; comparable event/time pairs within this fitted fold; half credit for tied scores", "No comparable observed-event pairs."),
    time_auc = bmp_metric_cell(if (is.null(auc_reason) && auc_den > 0) auc_num/auc_den else NA_real_, auc_reason, "Cumulative/dynamic IPCW AUC at horizon; cases G(T-), controls G(h); tied scores half credit"),
    brier = bmp_metric_cell(if (is.null(reason)) brier_num/sum(weights) else NA_real_, reason, "IPCW Brier: sum of weighted squared errors divided by all assessment row weights, including early-censored rows"))
  output <- list()
  if (curves) {
    p <- 1 - survival_probability
    bins <- cut(p, breaks = seq(0,1,.2), include.lowest = TRUE, labels = FALSE)
    calibration <- do.call(rbind, lapply(sort(unique(bins)), function(bin) {
      use <- bins == bin; km <- bmp_km_table(time[use], event[use], weights[use])
      supported <- horizon <= max(time[use])
      data.frame(bin = bin, lower = (bin-1)/5, upper = bin/5, rows = sum(use), groups = length(unique(groups[use])), mean_probability = weighted.mean(p[use], weights[use]),
        observed_fraction = if (supported) 1-tail(km$survival[km$time <= horizon],1) else NA_real_,
        reason = if (supported) "" else "Bin follow-up does not reach horizon", method = "Kaplan-Meier event risk in fixed probability bins; diagnostic, no model refit")
    }))
    km <- bmp_km_table(time, event, weights)
    if (!is.null(risk_group)) {
      if (length(risk_group) != n || anyNA(risk_group)) stop("Risk groups must be the saved frozen-threshold groups.", call. = FALSE)
      km <- do.call(rbind, lapply(sort(unique(risk_group)), function(group) {
        use <- risk_group == group; bmp_km_table(time[use], event[use], weights[use], group)
      }))
    }
    dca <- do.call(rbind, lapply(seq(.01,.99,.01), function(t) {
      selected <- p >= t
      data.frame(threshold = t,
        model = if (is.null(reason)) (sum(case_weight[selected])-sum(control_weight[selected])*t/(1-t))/sum(weights) else NA_real_,
        treat_all = if (is.null(reason)) (sum(case_weight)-sum(control_weight)*t/(1-t))/sum(weights) else NA_real_, treat_none = 0,
        reason = if (is.null(reason)) "" else reason)
    }))
    output <- list(calibration = calibration, km = km, dca = dca,
      ipcw = data.frame(time = time, event = event, horizon = horizon, case = case, control = control, censored_by_horizon = !case & !control,
        predicted_event_probability = p, case_weight = if (is.null(reason)) case_weight else NA_real_, control_weight = if (is.null(reason)) control_weight else NA_real_),
      time_auc = data.frame(horizon = horizon, estimate = metrics$time_auc$estimate, brier = metrics$brier$estimate, reason = if (is.null(auc_reason)) "" else auc_reason))
  }
  list(metrics = metrics, curves = output, counts = list(rows = n, groups = length(unique(groups)), events = sum(event), cases_by_horizon = sum(case), controls_at_horizon = sum(control), censored_by_horizon = sum(!case & !control)),
    components = list(harrell_numerator = pairs$numerator, harrell_denominator = pairs$denominator, auc_numerator = auc_num, auc_denominator = auc_den, brier_numerator = brier_num, weight = sum(weights), support_reason = reason),
    warnings = if (is.null(reason)) character() else reason)
}

bmp_bind_frames <- function(values) {
  values <- Filter(function(value) is.data.frame(value) && nrow(value) > 0L, values)
  if (!length(values)) return(data.frame())
  columns <- unique(unlist(lapply(values, names)))
  values <- lapply(values, function(value) { for (column in setdiff(columns, names(value))) value[[column]] <- NA; value[columns] })
  rownames_out <- do.call(rbind, values); rownames(rownames_out) <- NULL
  rownames_out
}
bmp_scope_counts <- function(predictions) {
  first_repeat <- predictions[predictions$repeat_id == min(predictions$repeat_id), , drop = FALSE]
  list(prediction_rows = nrow(predictions), rows_per_repeat = as.list(table(predictions$repeat_id)), unique_samples = length(unique(predictions$sample_id)),
    patient_groups = length(unique(predictions$group_id)), repeats = length(unique(predictions$repeat_id)), folds = length(unique(predictions$split_id)),
    events_first_repeat = if (all(is.na(first_repeat$event))) NULL else sum(first_repeat$event),
    positives_first_repeat = if (all(is.na(first_repeat$outcome_binary))) NULL else sum(first_repeat$outcome_binary),
    count_note = "Prediction rows across repeats are not independent patients. Event/positive counts refer to rows in the first repeat; repeated samples can share a patient.")
}
bmp_scope_point <- function(predictions, fold_models, config, curves = TRUE) {
  repeats <- sort(unique(predictions$repeat_id)); results <- list(); all_curves <- list(); fold_table <- list()
  for (repeat_id in repeats) {
    rows <- predictions[predictions$repeat_id == repeat_id, , drop = FALSE]
    if (config$analysis_type == "binary") {
      result <- bmp_binary_metrics(rows$outcome_binary, rows$probability, rows$threshold, rows$group_id, curves = curves)
      if (curves) for (kind in names(result$curves)) {
        frame <- result$curves[[kind]]; frame$repeat_id <- repeat_id; frame$split_id <- "pooled_within_repeat"
        all_curves[[kind]] <- c(all_curves[[kind]], list(frame))
      }
    } else {
      pieces <- list()
      for (split in unique(rows$split_id)) {
        p <- rows[rows$split_id == split, , drop = FALSE]
        if (length(unique(p$arm_id)) != 1L) stop("Each scope/split must have one fitted model.", call. = FALSE)
        model <- fold_models[[split]]$models[[p$arm_id[1]]]
        if (is.null(model)) stop(paste("Missing saved fold model:", split, p$arm_id[1]), call. = FALSE)
        piece <- bmp_survival_metrics(p$time, p$event, p$survival_probability, p$linear_predictor, config$horizon,
          model$training$censor_curve, model$training$time_range, p$group_id, risk_group = p$risk_group, curves = curves)
        pieces[[split]] <- piece
        for (metric in names(piece$metrics)) fold_table[[length(fold_table)+1L]] <- data.frame(repeat_id = repeat_id, split_id = split, metric = metric, estimate = piece$metrics[[metric]]$estimate, reason = if (is.null(piece$metrics[[metric]]$reason)) "" else piece$metrics[[metric]]$reason)
        if (curves) {
          # Additional time points reuse stored LP and the stored baseline; no
          # feature transformation or fitting is repeated to create this figure.
          lower <- max(min(p$time), as.numeric(unlist(model$training$time_range))[1])
          upper <- min(max(p$time), as.numeric(unlist(model$training$time_range))[2])
          horizons <- sort(unique(c(config$horizon, if (upper > lower) seq(lower, upper, length.out = 10) else numeric())))
          time_curve <- lapply(horizons, function(h) {
            hazard <- bmp_step_value(model$baseline$time, model$baseline$cumulative_hazard, h)
            probability <- exp(-exp(pmin(700, p$linear_predictor - model$baseline$reference_lp)) * hazard)
            value <- bmp_survival_metrics(p$time, p$event, probability, p$linear_predictor, h, model$training$censor_curve, model$training$time_range, p$group_id, curves = FALSE)
            data.frame(horizon = h, estimate = value$metrics$time_auc$estimate, brier = value$metrics$brier$estimate,
              reason = if (is.null(value$metrics$time_auc$reason)) "" else value$metrics$time_auc$reason)
          })
          piece$curves$time_auc <- bmp_bind_frames(time_curve)
          for (kind in names(piece$curves)) {
            frame <- piece$curves[[kind]]; frame$repeat_id <- repeat_id; frame$split_id <- split
            all_curves[[kind]] <- c(all_curves[[kind]], list(frame))
          }
        }
      }
      sum_component <- function(name) sum(vapply(pieces, function(p) p$components[[name]], numeric(1)))
      support_reasons <- unique(unlist(lapply(pieces, function(p) p$components$support_reason)))
      missing_support <- if (length(support_reasons)) paste("At least one fold has unavailable horizon support:", paste(support_reasons, collapse = " | ")) else NULL
      result <- list(metrics = list(
        harrell_c = bmp_metric_ratio(sum_component("harrell_numerator"), sum_component("harrell_denominator"), "Sum of concordant/half-tied pairs divided by comparable pairs within folds; no cross-model LP comparisons", "No within-fold comparable event pairs."),
        time_auc = if (is.null(missing_support)) bmp_metric_ratio(sum_component("auc_numerator"), sum_component("auc_denominator"), "IPCW concordant case/control pairs aggregated within folds at horizon", "No within-fold horizon case/control pairs.") else bmp_metric_cell(reason = missing_support, method = "Within-fold IPCW AUC"),
        brier = if (is.null(missing_support)) bmp_metric_cell(sum_component("brier_numerator")/sum_component("weight"), method = "IPCW squared-error sum over all assessment rows; censor curve specific to each fitted fold") else bmp_metric_cell(reason = missing_support, method = "IPCW Brier")))
    }
    results[[as.character(repeat_id)]] <- result$metrics
  }
  metrics <- list()
  for (name in names(results[[1]])) {
    cells <- lapply(results, `[[`, name); estimates <- vapply(cells, function(cell) cell$estimate, numeric(1))
    complete <- all(is.finite(estimates)); reasons <- unique(unlist(lapply(cells, function(cell) cell$reason)))
    metrics[[name]] <- bmp_metric_cell(if (complete) mean(estimates) else NA_real_, if (!complete) paste("One or more repeats unavailable:", paste(reasons, collapse = " | ")) else NULL,
      paste(cells[[1]]$method, "Equal mean across held-out repeats."), repeats_available = sum(is.finite(estimates)), repeats_expected = length(repeats))
  }
  list(metrics = metrics, curves = lapply(all_curves, bmp_bind_frames), repeat_metrics = results, fold_metrics = bmp_bind_frames(fold_table))
}
bmp_bootstrap_predictions <- function(predictions, seed) {
  groups <- unique(as.character(predictions$group_id))
  draws <- bmp_with_seed(seed, sample(groups, length(groups), replace = TRUE))
  do.call(rbind, lapply(seq_along(draws), function(i) {
    rows <- predictions[predictions$group_id == draws[i], , drop = FALSE]
    rows$source_group_id <- rows$group_id
    rows$group_id <- paste0("bootstrap_cluster_", i)
    rows
  }))
}
bmp_scope_metrics <- function(predictions, fold_models, config, expected_splits, role, arm_id) {
  expected <- as.character(unlist(expected_splits)); observed <- unique(predictions$split_id)
  missing <- setdiff(expected, observed)
  interpretation <- if (role == "primary") "Nested held-out estimate of the inner-selected modeling procedure; not an independent estimate for the final refitted model" else if (role == "external") "Frozen-model external cohort evaluation; independence requires checking cohort overlap" else "Descriptive fixed-arm comparison on common outer folds; choosing the best outer score is optimistic"
  if (!nrow(predictions)) {
    keys <- if (config$analysis_type == "binary") c("roc_auc", "average_precision", "brier", "log_loss", "sensitivity", "specificity", "ppv", "npv", "f1", "accuracy", "balanced_accuracy", "calibration_intercept", "calibration_slope") else c("harrell_c", "time_auc", "brier")
    missing_metrics <- stats::setNames(lapply(keys, function(key) bmp_metric_cell(reason = "No successful assessment predictions for this arm.", method = "Unavailable fixed-arm comparison")), keys)
    return(list(role = role, arm_id = arm_id, interpretation = interpretation,
      coverage = list(expected_folds = length(expected), completed_folds = 0L, complete = FALSE, missing_splits = I(missing)), metrics = missing_metrics, curves = list(),
      fold_metrics = data.frame(), repeat_metrics = list(), counts = list(prediction_rows = 0L, unique_samples = 0L, patient_groups = 0L, repeats = 0L, folds = 0L), warnings = "No successful assessment predictions for this arm."))
  }
  result <- bmp_scope_point(predictions, fold_models, config)
  requested <- as.integer(config$bootstrap_samples); seed <- as.integer(config$seed)
  if (is.na(requested) || requested < 0L) stop("bootstrap_samples must be nonnegative.", call. = FALSE)
  samples <- matrix(NA_real_, nrow = requested, ncol = length(result$metrics), dimnames = list(NULL, names(result$metrics)))
  if (requested) for (i in seq_len(requested)) {
    drawn <- bmp_bootstrap_predictions(predictions, bmp_seed(seed, 700000 + i))
    sampled <- tryCatch(bmp_scope_point(drawn, fold_models, config, curves = FALSE), error = function(error) NULL)
    if (!is.null(sampled)) samples[i, ] <- vapply(sampled$metrics, function(cell) cell$estimate, numeric(1))
  }
  failures <- list()
  for (name in names(result$metrics)) {
    values <- samples[, name]; values <- values[is.finite(values)]
    cell <- result$metrics[[name]]
    if (requested && length(values) >= 2L && is.finite(cell$estimate)) {
      interval <- stats::quantile(values, c(.025, .975), names = FALSE, type = 7)
      cell$lower <- interval[1]; cell$upper <- interval[2]
    }
    cell$ci_method <- if (requested) "95% percentile patient-group bootstrap conditional on stored predictions; no retraining" else "Disabled (bootstrap_samples=0)"
    cell$bootstrap_requested <- requested; cell$bootstrap_successful <- length(values); cell$bootstrap_failed <- requested - length(values)
    cell$ci_reason <- if (!requested) "Bootstrap disabled." else if (!is.finite(cell$estimate)) "Point estimate unavailable." else if (length(values) < 2L) "Fewer than two estimable bootstrap resamples." else NULL
    result$metrics[[name]] <- cell; failures[[name]] <- requested-length(values)
  }
  result$role <- role; result$arm_id <- arm_id; result$interpretation <- interpretation
  result$counts <- bmp_scope_counts(predictions)
  result$coverage <- list(expected_folds = length(expected), completed_folds = length(observed), complete = !length(missing), missing_splits = I(missing))
  result$bootstrap <- list(requested = requested, seed = seed, sampling_unit = "patient_group", independent_groups = length(unique(predictions$group_id)), retains_all_samples_and_repeats = TRUE, duplicate_draws_have_distinct_cluster_ids = TRUE, failed_by_metric = failures, limitation = bmp_metric_methods()$uncertainty)
  result$warnings <- if (length(missing)) paste("Incomplete arm coverage; estimates use the available folds only:", paste(missing, collapse = ", ")) else character()
  result
}
bmp_compute_metrics <- function(predictions, fold_models, config, expected_splits = NULL, expected_arms = NULL) {
  required <- c("sample_id", "group_id", "repeat_id", "split_id", "role", "arm_id", "threshold", "outcome_binary", "event", "time")
  if (!all(required %in% names(predictions)) || !nrow(predictions)) stop("Assessment predictions are empty or missing required result columns.", call. = FALSE)
  if (anyNA(predictions[required[c(1,2,3,4,5,6)]])) stop("Assessment prediction identities cannot be missing.", call. = FALSE)
  if (is.null(config$bootstrap_samples)) config$bootstrap_samples <- 0L
  if (is.null(config$seed)) config$seed <- 1L
  if (is.null(expected_splits)) expected_splits <- names(fold_models)
  if (is.null(expected_arms)) expected_arms <- unique(predictions$arm_id[predictions$role == "fixed_arm"])
  primary_role <- if (any(predictions$role == "external")) "external" else "primary"
  primary <- predictions[predictions$role == primary_role, , drop = FALSE]
  if (!nrow(primary)) stop("Primary assessment predictions are missing.", call. = FALSE)
  result <- list(schema_version = 1L, analysis_type = config$analysis_type, horizon = if (config$analysis_type == "survival") config$horizon else NULL,
    time_unit = if (config$analysis_type == "survival") config$time_unit else NULL,
    computation = list(method_revision = "assessment-metrics-v1", module_sha256 = bmp_sha256(file.path(bmp_repo_root, "R", "metrics.R")),
      r_version = R.version.string, survival_version = as.character(utils::packageVersion("survival")),
      provenance_note = "Metric computation provenance is distinct from the frozen model's original training provenance; no prediction model is refitted."),
    methods = bmp_metric_methods(), point_weighting = "Equal row/sample weights within each repeat; equal mean across repeats; patient-cluster bootstrap for dependence",
    primary = bmp_scope_metrics(primary, fold_models, config, expected_splits, primary_role, if (primary_role == "external") primary$arm_id[1] else "inner_selected_procedure"), comparisons = list())
  for (arm in as.character(unlist(expected_arms))) {
    rows <- predictions[predictions$role == "fixed_arm" & predictions$arm_id == arm, , drop = FALSE]
    result$comparisons[[arm]] <- bmp_scope_metrics(rows, fold_models, config, expected_splits, "fixed_arm", arm)
  }
  result
}
bmp_write_metric_outputs <- function(result, run_dir) {
  directory <- file.path(run_dir, "evaluation"); dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  paths <- list(); table <- list(); scopes <- c(list(primary = result$primary), result$comparisons)
  for (scope_id in names(scopes)) {
    scope <- scopes[[scope_id]]
    for (name in names(scope$metrics)) {
      cell <- scope$metrics[[name]]
      table[[length(table)+1L]] <- data.frame(scope = scope_id, role = scope$role, arm_id = scope$arm_id, metric = name,
        estimate = cell$estimate, lower = cell$lower, upper = cell$upper, reason = if (is.null(cell$reason)) "" else cell$reason,
        completed_folds = scope$coverage$completed_folds, expected_folds = scope$coverage$expected_folds, interpretation = scope$interpretation)
    }
    # Hashed filenames avoid arbitrary arm IDs becoming paths. Human identity is
    # included in every CSV and in the metrics.json curves/files mapping.
    prefix <- if (scope_id == "primary") "primary" else substr(bmp_hash_object(scope_id), 1, 12)
    files <- list()
    for (kind in names(scope$curves)) {
      frame <- scope$curves[[kind]]
      if (!nrow(frame)) next
      frame$scope <- scope_id; frame$role <- scope$role
      relative <- file.path("evaluation", paste0(prefix, "_", kind, ".csv"))
      bmp_atomic_csv(frame, file.path(run_dir, relative)); files[[kind]] <- relative
    }
    if (is.data.frame(scope$fold_metrics) && nrow(scope$fold_metrics)) {
      relative <- file.path("evaluation", paste0(prefix, "_fold_metrics.csv"))
      bmp_atomic_csv(scope$fold_metrics, file.path(run_dir, relative)); files$fold_metrics <- relative
    }
    scope$curve_files <- files
    if (scope_id == "primary") result$primary <- scope else result$comparisons[[scope_id]] <- scope
    paths[[scope_id]] <- files
  }
  bmp_atomic_csv(bmp_bind_frames(table), file.path(directory, "metrics_table.csv"))
  result$files <- list(metrics_table = "evaluation/metrics_table.csv", curves = paths)
  bmp_atomic_json(result, file.path(run_dir, "metrics.json"))
  result
}
bmp_metrics_for_run <- function(run_dir) {
  run_dir <- normalizePath(run_dir, winslash = "/", mustWork = TRUE)
  config <- bmp_read_json(file.path(run_dir, "config.json")); manifest <- bmp_read_json(file.path(run_dir, "manifest.json"))
  # Check immutable metric inputs, not old derived report/metric bytes. Report
  # regeneration owns refreshing the completion hashes of its derived outputs.
  recorded <- manifest$engine_artifact_verification$sha256
  if (is.null(recorded)) recorded <- manifest$evaluation_artifact_verification$sha256
  if (is.null(recorded)) recorded <- manifest$artifact_verification$sha256
  relevant <- intersect(names(recorded), c("config.json", "qc.json", "input.json", "predictions.csv", "fold_models.json", "splits.json", "model_comparison.csv", "model.bmpmodel", "drift.json"))
  if (length(relevant)) {
    verified <- bmp_verify_artifacts(run_dir, relevant, recorded[relevant])
    if (!verified$ok) stop(paste("Saved metric input integrity check failed:", paste(c(verified$missing, verified$mismatch), collapse = ", ")), call. = FALSE)
  }
  if (identical(manifest$operation, "evaluate")) {
    model <- bmp_load_model(file.path(run_dir, "model.bmpmodel"))
    fold_models <- list(external = list(models = stats::setNames(list(model), model$arm_id)))
    splits <- "external"; arms <- character()
  } else {
    fold_models <- bmp_read_json(file.path(run_dir, "fold_models.json"))
    split_artifact <- bmp_read_json(file.path(run_dir, "splits.json"))
    splits <- vapply(split_artifact$outer, function(split) split$id, character(1))
    comparison <- bmp_read_csv(file.path(run_dir, "model_comparison.csv"))
    arms <- unique(comparison$arm_id[comparison$role == "fixed_arm"])
  }
  result <- bmp_compute_metrics(bmp_read_predictions(file.path(run_dir, "predictions.csv")), fold_models, config, splits, arms)
  result$run_id <- manifest$run_id; result$operation <- if (is.null(manifest$operation)) "analyze" else manifest$operation
  if (identical(manifest$operation, "evaluate")) {
    result$independence <- manifest$independence
    if (isTRUE(manifest$independence$identical_development_input)) result$primary$interpretation <- "In-sample frozen-model evaluation: input is byte-identical to the development cohort. These results are not independent external validation."
  }
  result <- bmp_write_metric_outputs(result, run_dir)
  run <- list(id = manifest$run_id, dir = run_dir, root_output_dir = dirname(dirname(run_dir)), config = config, manifest = manifest)
  # Regeneration of metrics alone never upgrades a failed/incomplete run.
  if (manifest$status %in% c("created", "validated", "running")) bmp_update_manifest(run, "running", stage = "metrics_ready", metrics_path = file.path(run_dir, "metrics.json"))
  result
}
