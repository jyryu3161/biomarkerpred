# Portable model artifact v1. Numeric design names are internal; raw predictor
# names/category levels are carried in recipe.design and never parsed as formulas.
bmp_fit_design <- function(x, data, config, algorithm = "stepwise", alpha = 1, lambda_ratio = .1, forced_columns = character()) {
  warnings <- character()
  capture <- function(expr) withCallingHandlers(expr, warning = function(w) { warnings <<- unique(c(warnings, conditionMessage(w))); invokeRestart("muffleWarning") })
  binary <- config$analysis_type == "binary"
  y <- if (binary) as.integer(as.character(data[[config$outcome]]) == config$positive_class) else survival::Surv(data[[config$time_variable]], data[[config$event]])
  use_penalty <- algorithm == "elastic_net" && ncol(x) && length(setdiff(colnames(x), forced_columns))
  native_x <- x; lambda <- NULL; native_kind <- NULL
  if (use_penalty) {
    bmp_require("glmnet")
    if (ncol(native_x) == 1L) native_x <- cbind(native_x, bmp_padding = 0)
    penalty <- as.numeric(!colnames(native_x) %in% forced_columns)
    family <- if (binary) "binomial" else "cox"
    path <- capture(glmnet::glmnet(native_x, y, family = family, alpha = alpha, standardize = FALSE, penalty.factor = penalty, nlambda = 40, maxit = 100000))
    maximum <- max(path$lambda[is.finite(path$lambda)])
    lambda <- maximum * lambda_ratio
    fit <- capture(glmnet::glmnet(native_x, y, family = family, alpha = alpha, standardize = FALSE, penalty.factor = penalty, lambda = sort(unique(c(maximum, lambda)), decreasing = TRUE), maxit = 100000))
    co <- as.matrix(stats::coef(fit, s = lambda))[, 1]
    intercept <- if (binary) unname(co["(Intercept)"]) else 0
    coefficients <- co[match(colnames(x), names(co))]; names(coefficients) <- colnames(x)
    native_kind <- "glmnet"
    native_lp <- as.numeric(stats::predict(fit, newx = native_x, s = lambda, type = "link"))
    aic <- NA_real_
  } else if (binary) {
    fit <- capture(stats::glm.fit(cbind(`(Intercept)` = 1, x), y, family = stats::binomial()))
    if (!isTRUE(fit$converged)) stop("Logistic fitting did not converge.", call. = FALSE)
    co <- fit$coefficients
    if (anyNA(co)) { co[is.na(co)] <- 0; warnings <- c(warnings, "Aliased design coefficients set to zero; review collinearity.") }
    intercept <- unname(co[1]); coefficients <- co[-1]
    native_lp <- as.numeric(cbind(1, x) %*% co)
    native_kind <- "glm"; aic <- fit$aic
  } else {
    bmp_require("survival")
    frame <- as.data.frame(x)
    frame$.time <- data[[config$time_variable]]; frame$.event <- data[[config$event]]
    formula <- if (ncol(x)) stats::reformulate(colnames(x), response = "survival::Surv(.time, .event)") else stats::as.formula("survival::Surv(.time, .event) ~ 1")
    fit <- capture(survival::coxph(formula, data = frame, ties = "breslow", x = TRUE, y = TRUE, singular.ok = TRUE, control = survival::coxph.control(iter.max = 100)))
    coefficients <- stats::coef(fit)
    if (is.null(coefficients)) coefficients <- stats::setNames(numeric(), character())
    if (anyNA(coefficients)) { coefficients[is.na(coefficients)] <- 0; warnings <- c(warnings, "Aliased design coefficients set to zero; review collinearity.") }
    intercept <- 0; native_lp <- if (ncol(x)) as.numeric(x %*% coefficients) else rep(0, nrow(data))
    native_kind <- "coxph"; aic <- -2 * tail(fit$loglik, 1L) + 2 * length(coefficients)
  }
  if (any(!is.finite(c(intercept, coefficients, native_lp)))) stop("Model fitting produced non-finite coefficients or linear predictors.", call. = FALSE)
  list(coefficients = coefficients, intercept = intercept, native = fit, native_kind = native_kind, native_x = native_x, native_lp = native_lp, lambda = lambda, aic = aic, warnings = warnings)
}
bmp_columns_for <- function(recipe, predictors) as.character(unlist(lapply(predictors, function(name) as.character(unlist(recipe$predictors[[name]]$columns))), use.names = FALSE))
bmp_stepwise_features <- function(data, config, recipe, panel_size) {
  clinical <- as.character(unlist(recipe$clinical_columns)); forced <- as.character(unlist(recipe$forced_genes)); genes <- as.character(unlist(recipe$selected_genes))
  if (length(forced) > panel_size) stop("Forced genes exceed this arm's panel_size; increase panel size.", call. = FALSE)
  selected <- forced
  current <- bmp_fit_design(bmp_apply_recipe(recipe, data, c(clinical, selected)), data, config)
  while (length(selected) < panel_size && length(setdiff(genes, selected))) {
    candidates <- setdiff(genes, selected)
    fits <- lapply(candidates, function(gene) tryCatch(bmp_fit_design(bmp_apply_recipe(recipe, data, c(clinical, selected, gene)), data, config), error = function(e) NULL))
    aics <- vapply(fits, function(fit) if (is.null(fit) || !is.finite(fit$aic)) Inf else fit$aic, numeric(1))
    best <- which.min(aics)
    if (!length(best) || !is.finite(aics[best]) || aics[best] >= current$aic - 1e-8) break
    selected <- c(selected, candidates[best]); current <- fits[[best]]
  }
  list(features = c(clinical, selected), fit = current)
}
bmp_censor_curve <- function(time, event) {
  # Reverse Kaplan-Meier: original events leave the denominator before censor
  # failures at tied times. Event IPCW weights use the left limit G(t-).
  times <- sort(unique(time)); probability <- 1
  values <- vapply(times, function(t) {
    at_risk <- sum(time >= t)
    original_events <- sum(time == t & event == 1)
    censored <- sum(time == t & event == 0)
    denominator <- at_risk - original_events
    if (censored) probability <<- probability * (1 - censored/denominator)
    probability
  }, numeric(1))
  list(time = I(times), survival = I(values), convention = "Reverse Kaplan-Meier; original events removed before censor failures at ties; observed event IPCW uses G(t-)", ties = "original_events_before_censor_failures")
}
bmp_cox_baseline <- function(time, event, lp) {
  reference <- mean(lp); risk <- exp(pmin(700, lp - reference))
  times <- sort(unique(time[event == 1]))
  increments <- vapply(times, function(t) sum(event == 1 & time == t)/sum(risk[time >= t]), numeric(1))
  list(time = I(times), cumulative_hazard = I(cumsum(increments)), reference_lp = reference, ties = "breslow")
}
bmp_compact_recipe <- function(recipe, features) {
  result <- recipe
  result$predictors <- recipe$predictors[features]
  result$design <- Filter(function(term) term$predictor %in% features, recipe$design)
  result$selected_genes <- I(intersect(as.character(unlist(recipe$selected_genes)), features))
  result$clinical_columns <- I(intersect(as.character(unlist(recipe$clinical_columns)), features))
  result$forced_genes <- I(intersect(as.character(unlist(recipe$forced_genes)), features))
  result$screening <- recipe$screening[recipe$screening$gene %in% features, , drop = FALSE]
  result$distribution <- NULL # Stored once in artifact.training for drift checks.
  result$dropped <- NULL
  result$screening_audit$bootstrap_pool <- NULL
  result$screening_audit$candidate_genes <- NULL
  result$storage <- list(version = 1L, scope = "Required deployed predictors only",
    full_screening_location = "Run screening/<partition>.json; full-development ranking in gene_ranking.csv",
    retained_predictors = length(features), fitting_predictors = length(recipe$predictors))
  result
}
bmp_fit_model <- function(data, config, arm, seed = config$seed, recipe = NULL) {
  if (is.null(recipe)) recipe <- bmp_fit_recipe(data, config, arm$feature_set, seed)
  if (arm$algorithm == "stepwise") {
    chosen <- bmp_stepwise_features(data, config, recipe, arm$panel_size)
    features <- chosen$features; fit <- chosen$fit
  } else {
    clinical <- as.character(unlist(recipe$clinical_columns)); forced <- as.character(unlist(recipe$forced_genes))
    if (length(forced) > arm$panel_size) stop("Forced genes exceed this arm's panel_size; increase panel size.", call. = FALSE)
    genes <- unique(c(forced, head(setdiff(as.character(unlist(recipe$selected_genes)), forced), max(0, arm$panel_size - length(forced)))))
    features <- c(clinical, genes)
    fit <- bmp_fit_design(bmp_apply_recipe(recipe, data, features), data, config, algorithm = arm$algorithm, alpha = arm$alpha, lambda_ratio = arm$lambda_ratio, forced_columns = bmp_columns_for(recipe, forced))
  }
  design_columns <- bmp_columns_for(recipe, features)
  coefficients <- as.list(stats::setNames(as.numeric(fit$coefficients), names(fit$coefficients)))
  active <- unique(vapply(Filter(function(term) term$column %in% names(coefficients)[abs(as.numeric(unlist(coefficients))) > 1e-10], recipe$design), function(term) term$predictor, character(1)))
  active_genes <- unique(c(as.character(unlist(recipe$forced_genes)), intersect(active, as.character(unlist(recipe$selected_genes)))))
  # Zero-coefficient optional genes are not required by the deployed assay.
  features <- features[features %in% c(as.character(unlist(recipe$clinical_columns)), active_genes)]
  design_columns <- bmp_columns_for(recipe, features)
  coefficients <- coefficients[design_columns]
  artifact <- list(format = "BioMarkerPred", model_version = 1L, analysis_type = config$analysis_type,
    algorithm = arm$algorithm, arm_id = arm$arm_id, feature_set = arm$feature_set,
    panel_size = arm$panel_size, panel_size_definition = "maximum genes; clinical covariates are separate",
    actual_gene_count = length(active_genes), selected_genes = I(active_genes), clinical_columns = recipe$clinical_columns,
    features = I(features), design_columns = I(design_columns), coefficients = coefficients, intercept = fit$intercept,
    hyperparameters = list(alpha = arm$alpha, lambda_ratio = arm$lambda_ratio, lambda = fit$lambda), recipe = bmp_compact_recipe(recipe, features),
    outcome = list(column = config$outcome, positive_class = config$positive_class, negative_class = config$negative_class, positive_label = config$positive_label, negative_label = config$negative_label, event = config$event, time_variable = config$time_variable),
    sample_id = config$sample_id, group_column = config$group_column, time_unit = config$time_unit, horizon = config$horizon,
    threshold = NULL, threshold_method = NULL,
    training = list(rows = nrow(data), groups = length(unique(bmp_groups(data, config))), distribution = recipe$distribution[features],
      considered_gene_count = length(config$gene_columns),
      distribution_scope = "Required deployed predictors only; unselected training genes are not distribution-audited by this portable model",
      identifier_hashes = list(method = "SHA-256 of UTF-8 identifier string; unsalted overlap audit, not anonymization",
        sample = I(vapply(unique(as.character(data[[config$sample_id]])), function(id) digest::digest(enc2utf8(id), algo = "sha256", serialize = FALSE), character(1), USE.NAMES = FALSE)),
        group = I(vapply(unique(bmp_groups(data, config)), function(id) digest::digest(enc2utf8(id), algo = "sha256", serialize = FALSE), character(1), USE.NAMES = FALSE)))),
    warnings = unique(c(recipe$warnings, fit$warnings)), unknown_category_policy = "error")
  if (config$analysis_type == "survival") {
    time <- data[[config$time_variable]]; event <- data[[config$event]]
    artifact$baseline <- bmp_cox_baseline(time, event, fit$native_lp)
    artifact$training$censor_curve <- bmp_censor_curve(time, event)
    artifact$training$time_range <- I(range(time)); artifact$training$events <- sum(event)
    artifact$threshold <- stats::median(tapply(fit$native_lp, bmp_groups(data, config), mean))
    artifact$threshold_method <- "median of patient mean linear predictors in fitting partition"
  }
  list(artifact = artifact, native = fit$native, native_kind = fit$native_kind, native_lp = fit$native_lp, native_x = fit$native_x)
}
bmp_model_artifact <- function(model) if (!is.null(model$artifact)) model$artifact else model
bmp_step_value <- function(times, values, at, initial = 0) {
  times <- as.numeric(unlist(times)); values <- as.numeric(unlist(values))
  indices <- findInterval(at, times)
  answer <- rep(initial, length(at)); answer[indices > 0] <- values[indices[indices > 0]]
  answer
}
bmp_predict_model <- function(model, data, horizons = NULL) {
  model <- bmp_model_artifact(model)
  x <- bmp_apply_recipe(model$recipe, data, as.character(unlist(model$features)))
  columns <- as.character(unlist(model$design_columns))
  co <- as.numeric(unlist(model$coefficients, use.names = FALSE)); names(co) <- names(model$coefficients)
  lp <- rep(as.numeric(model$intercept), nrow(data))
  if (length(columns)) lp <- lp + as.numeric(x[, columns, drop = FALSE] %*% co[columns])
  if (any(!is.finite(lp))) stop("Prediction produced non-finite linear predictors.", call. = FALSE)
  id <- if (model$sample_id %in% names(data)) as.character(data[[model$sample_id]]) else as.character(seq_len(nrow(data)))
  result <- data.frame(sample_id = id, linear_predictor = lp, stringsAsFactors = FALSE)
  if (model$analysis_type == "binary") {
    result$probability <- stats::plogis(lp)
    result$threshold <- if (is.null(model$threshold)) NA_real_ else model$threshold
    result$predicted_class <- if (is.null(model$threshold)) NA_character_ else ifelse(result$probability >= model$threshold, model$outcome$positive_class, model$outcome$negative_class)
    result$predicted_label <- if (is.null(model$threshold)) NA_character_ else ifelse(result$probability >= model$threshold, model$outcome$positive_label, model$outcome$negative_label)
  } else {
    result$risk <- exp(pmin(700, lp - model$baseline$reference_lp))
    result$threshold <- model$threshold
    result$risk_group <- ifelse(lp >= model$threshold, "High", "Low")
    if (is.null(horizons)) horizons <- model$horizon
    horizons <- as.numeric(horizons)
    if (any(!is.finite(horizons) | horizons < 0)) stop("Prediction horizons must be finite nonnegative times in the model time_unit.", call. = FALSE)
    hazards <- bmp_step_value(model$baseline$time, model$baseline$cumulative_hazard, horizons)
    probabilities <- exp(-outer(result$risk, hazards))
    colnames(probabilities) <- paste0("survival_", format(horizons, scientific = FALSE, trim = TRUE))
    result$survival_probability <- if (length(horizons)) probabilities[, 1] else NA_real_
    attr(result, "survival_probabilities") <- probabilities
    attr(result, "horizons") <- horizons
  }
  result
}
bmp_validate_model <- function(model, require_threshold = TRUE) {
  fail <- function(message) stop(paste("Invalid .bmpmodel:", message), call. = FALSE)
  scalar_number <- function(value) is.numeric(value) && length(value) == 1L && is.finite(value)
  scalar_text <- function(value) is.character(value) && length(value) == 1L && !is.na(value) && nzchar(value)
  array <- function(value) inherits(value, "AsIs") || (is.list(value) && is.null(names(value)))
  if (!is.list(model) || !identical(model$format, "BioMarkerPred") || !identical(as.integer(model$model_version), 1L)) fail("unsupported format/version")
  if (!scalar_text(model$analysis_type) || !model$analysis_type %in% c("binary", "survival")) fail("analysis_type")
  if (!scalar_text(model$sample_id) || (!is.null(model$group_column) && !scalar_text(model$group_column))) fail("identifier columns")
  if (!is.list(model$recipe) || as.integer(model$recipe$recipe_version) != 1L) fail("recipe version")
  for (key in c("features", "design_columns", "selected_genes", "clinical_columns")) {
    value <- model[[key]]
    if (!array(value)) fail(paste(key, "must be a JSON array (including empty and one-item arrays)"))
  }
  columns <- as.character(unlist(model$design_columns)); features <- as.character(unlist(model$features)); co <- unlist(model$coefficients)
  if (anyDuplicated(columns) || anyDuplicated(features) || !setequal(columns, names(co)) || length(co) != length(columns)) fail("design/coefficients mismatch")
  if (!scalar_number(model$intercept) || (length(co) && (!is.numeric(co) || any(!is.finite(co))))) fail("non-finite coefficients/intercept")
  if (!setequal(columns, bmp_columns_for(model$recipe, features))) fail("recipe design mismatch")
  for (name in features) {
    spec <- model$recipe$predictors[[name]]
    if (is.null(spec) || !spec$type %in% c("numeric", "categorical")) fail("missing/invalid predictor encoder")
    if (!array(spec$columns) || anyDuplicated(unlist(spec$columns))) fail("predictor columns array")
    if (spec$type == "numeric" && (!all(vapply(spec[c("median", "center", "scale")], scalar_number, logical(1))) || length(unlist(spec$columns)) != 1L || spec$scale <= 0)) fail("numeric encoder")
    if (spec$type == "categorical" && (!array(spec$levels) || !scalar_text(spec$mode) || !spec$mode %in% unlist(spec$levels) || anyDuplicated(unlist(spec$levels)) || length(unlist(spec$columns)) != length(unlist(spec$levels)) - 1L)) fail("categorical encoder")
  }
  if (require_threshold && !scalar_number(model$threshold)) fail("frozen threshold missing")
  if (model$analysis_type == "binary") {
    if (!is.null(model$threshold) && (model$threshold < 0 || model$threshold > 1)) fail("binary threshold outside [0,1]")
    for (key in c("positive_class", "negative_class", "positive_label", "negative_label")) if (!scalar_text(model$outcome[[key]])) fail("outcome coding/labels")
    if (identical(model$outcome$positive_class, model$outcome$negative_class)) fail("identical outcome classes")
  } else {
    times <- as.numeric(unlist(model$baseline$time)); hazards <- as.numeric(unlist(model$baseline$cumulative_hazard))
    if (!array(model$baseline$time) || !array(model$baseline$cumulative_hazard) || !scalar_number(model$baseline$reference_lp) || !length(times) || length(times) != length(hazards) || any(!is.finite(c(times, hazards))) || any(times <= 0) || any(diff(times) <= 0) || any(diff(hazards) < 0) || any(hazards < 0)) fail("baseline hazard")
    if (!scalar_text(model$time_unit) || !model$time_unit %in% c("days", "months", "years") || !scalar_number(model$horizon) || model$horizon <= 0) fail("survival units/horizon")
    if (!scalar_text(model$outcome$time_variable) || !scalar_text(model$outcome$event)) fail("survival outcome columns")
    support <- as.numeric(unlist(model$training$time_range))
    if (length(support) != 2L || any(!is.finite(support)) || support[1] <= 0 || support[2] < support[1] || !scalar_number(model$training$events) || model$training$events <= 0) fail("training survival support/events")
    censor_time <- as.numeric(unlist(model$training$censor_curve$time)); censor_surv <- as.numeric(unlist(model$training$censor_curve$survival))
    if (!length(censor_time) || length(censor_time) != length(censor_surv) || any(!is.finite(c(censor_time, censor_surv))) || any(diff(censor_time) <= 0) || any(diff(censor_surv) > 0) || any(censor_surv < 0 | censor_surv > 1)) fail("training censor curve")
  }
  invisible(model)
}
bmp_save_model <- function(model, path) {
  artifact <- bmp_model_artifact(model); bmp_validate_model(artifact)
  bmp_atomic_json(artifact, path)
  restored <- bmp_load_model(path)
  invisible(restored)
}
bmp_load_model <- function(path) {
  model <- bmp_read_json(path); bmp_validate_model(model)
  model
}
