#!/usr/bin/env Rscript
script <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())][1L])
root <- dirname(dirname(normalizePath(script, mustWork = TRUE)))
source(file.path(root, "R", "load.R"))
assert <- function(value, message) if (!isTRUE(value)) stop(message, call. = FALSE)
close <- function(a, b, message, tolerance = 1e-9) assert(isTRUE(all.equal(a, b, tolerance = tolerance, check.attributes = FALSE)), message)

# Independent stats::t.test oracle, including patient means, missingness,
# insufficient groups, constant values, large offsets and tied observations.
validated <- bmp_validate_data(file.path(root, "tests", "fixtures", "binary.json"))
data <- validated$data; config <- validated$config
set.seed(713)
genes <- paste0("numerical_", seq_len(100))
for (gene in genes) {
  data[[gene]] <- rnorm(nrow(data))
  data[[gene]][sample.int(nrow(data), sample.int(55, 1))] <- NA_real_
}
data[[genes[1]]] <- rep(1, nrow(data))
data[[genes[2]]] <- rep(NA_real_, nrow(data))
data[[genes[3]]] <- rep(NA_real_, nrow(data)); data[[genes[3]]][1:3] <- 1:3
data[[genes[4]]] <- 1e7 + rnorm(nrow(data), sd = .1)
data[[genes[5]]] <- round(rnorm(nrow(data)))
data[[genes[6]]] <- ifelse(data[[config$outcome]] == config$positive_class, 1, 2)
data[[genes[7]]] <- rnorm(nrow(data), sd = 1e-100)
oracle <- function(gene) {
  x <- data[[gene]]; observed <- !is.na(x)
  tryCatch({
    if (sum(observed) < 3 || length(unique(x[observed])) < 2) stop("Constant or insufficient observed training values.")
    group <- bmp_groups(data, config)
    gx <- tapply(x, group, function(value) if (all(is.na(value))) NA_real_ else mean(value, na.rm = TRUE))
    gy <- data[[config$outcome]][match(names(gx), group)] == config$positive_class
    fit <- stats::t.test(gx[gy], gx[!gy])
    if (!is.finite(fit$statistic) || !is.finite(fit$p.value)) stop("Univariate statistic unavailable.")
    list(statistic = unname(fit$statistic), p_value = fit$p.value, reason = "")
  }, error = function(error) list(statistic = NA_real_, p_value = NA_real_, reason = conditionMessage(error)))
}
expected <- lapply(genes, oracle)
actual <- bmp_screen_statistics(data, config, genes)
actual <- actual[match(genes, actual$gene), ]
close(actual$statistic, vapply(expected, `[[`, numeric(1), "statistic"), "Vectorized Welch statistics differ from t.test", 1e-7)
close(actual$p_value, vapply(expected, `[[`, numeric(1), "p_value"), "Vectorized Welch p values differ from t.test", 1e-8)
assert(identical(actual$reason, vapply(expected, `[[`, character(1), "reason")), "Welch non-estimability reasons differ")
# Unequal repeated samples and extreme numeric offsets exercise the guarded
# compensated-mean fallback; naive double rowsum differs materially here.
set.seed(8)
rows <- rep(seq_len(nrow(data)), sample(1:11, nrow(data), replace = TRUE))
unequal <- data[rows, ]
unequal$offset <- 1e12 + rnorm(nrow(unequal))
gx <- tapply(unequal$offset, bmp_groups(unequal, config), mean)
gy <- unequal[[config$outcome]][match(names(gx), bmp_groups(unequal, config))] == config$positive_class
reference <- stats::t.test(gx[gy], gx[!gy])
guarded <- bmp_screen_statistics(unequal, config, "offset")
close(guarded$statistic, unname(reference$statistic), "Large-offset grouped mean lost numeric stability", 1e-12)
close(guarded$p_value, reference$p.value, "Large-offset Welch p value lost numeric stability", 1e-12)
for (method in c("none", "BH", "holm", "bonferroni", "BY")) {
  config$p_adjust_method <- method
  subset <- bmp_screen_statistics(data, config, genes[10:15], test_count = 100L)
  close(subset$adjusted_p, p.adjust(subset$p_value, method = method, n = 100L), "Bootstrap multiplicity lost the full eligible universe")
}
cat("Vectorized patient-mean Welch statistics and multiplicity oracles passed\n")

# Screening cache exists only within this training call. Shared and independent
# combined recipes must have identical encoders, selection and audit hashes.
config <- validated$config
config$feature_sets <- c("genes", "clinical", "combined")
shared <- bmp_fit_recipes(validated$data, config, 71)
direct <- bmp_fit_recipe(validated$data, config, "combined", 71)
assert(identical(bmp_hash_object(shared$combined), bmp_hash_object(direct)), "Shared screening changed combined recipe")
assert(identical(shared$genes$screening_audit, shared$combined$screening_audit), "Gene and combined arms did not share screening")
assert(length(shared$clinical$selected_genes) == 0 && nrow(shared$clinical$screening) == 0, "Clinical-only recipe ran gene screening")

# A capped pool is an explicit selection-policy change. Frequencies outside it
# remain unavailable; forced genes survive even a stringent prescreen.
config$gene_columns <- genes[10:49]
config$p_threshold <- 1; config$p_adjust_method <- "BH"; config$selection_frequency <- 0
config$missing_threshold <- .99
config$max_candidates_per_step <- 3L; config$include <- genes[49]
recipe <- bmp_fit_recipe(data, config, "genes", 87)
assert(recipe$screening_policy$version == 2L && recipe$screening_policy$eligible_test_count == 40L, "Selection-policy version/universe missing")
assert(sum(recipe$screening$bootstrap_evaluated) == 3L && length(recipe$selected_genes) == 3L, "Bootstrap pool exceeded the cap")
assert(all(is.na(recipe$screening$selection_frequency[!recipe$screening$bootstrap_evaluated])), "Untested bootstrap genes were assigned artificial zero frequencies")
assert(genes[49] %in% recipe$selected_genes, "Forced gene was lost at pool construction")
config$p_threshold <- 1e-100
forced <- bmp_fit_recipe(data, config, "genes", 87)
assert(identical(as.character(forced$selected_genes), genes[49]), "Forced gene was lost at significance filtering")
cat("Partition-scoped sharing and explicit capped-pool policy checks passed\n")

# Compare the compact model with its actual complete fitting recipe, then with
# a JSON roundtrip. This tests deployable numeric/category encoders, not merely
# the presence of an arbitrary byte-size target.
for (type in c("binary", "survival")) {
  value <- bmp_validate_data(file.path(root, "tests", "fixtures", paste0(type, ".json")))
  config <- value$config; data <- value$data
  config$p_threshold <- 1; config$p_adjust_method <- "none"; config$selection_frequency <- 0
  set.seed(91)
  extras <- paste0("unused_", seq_len(300))
  for (gene in extras) data[[gene]] <- rnorm(nrow(data))
  config$gene_columns <- c(config$gene_columns, extras)
  config$max_candidates_per_step <- 3L
  recipe <- bmp_fit_recipe(data, config, "combined", 3)
  arm <- list(algorithm = "elastic_net", feature_set = "combined", panel_size = 1L, alpha = .5, lambda_ratio = .1, arm_id = "compact")
  model <- bmp_fit_model(data, config, arm, recipe = recipe)$artifact
  if (type == "binary") model$threshold <- .5
  complete <- model; complete$recipe <- recipe; complete$training$distribution <- recipe$distribution
  close(bmp_predict_model(model, data), bmp_predict_model(complete, data), "Compaction changed predictions", 0)
  features <- as.character(model$features)
  assert(setequal(names(model$recipe$predictors), features) && setequal(names(model$training$distribution), features), "Unused predictors remain in portable model")
  assert(is.null(model$recipe$distribution) && is.null(model$recipe$dropped), "Duplicated training summaries remain in portable model")
  assert(identical(model$recipe$screening_audit$screening_sha256, bmp_hash_object(recipe$screening)), "Compact model lost full screening audit hash")
  path <- tempfile(fileext = ".bmpmodel"); full_path <- tempfile(fileext = ".bmpmodel")
  bmp_save_model(model, path); bmp_save_model(complete, full_path)
  assert(file.info(path)$size < file.info(full_path)$size/3, "Portable artifact still grows with unused predictor encoders")
  loaded <- bmp_load_model(path)
  close(bmp_predict_model(loaded, data), bmp_predict_model(model, data), "Compact JSON model changed predictions", 1e-12)
  subset <- data[1L, features, drop = FALSE]
  close(bmp_predict_model(loaded, subset)$linear_predictor, bmp_predict_model(loaded, data)$linear_predictor[1], "Compact single-row prediction requires unused inputs", 1e-12)
}
cat("Binary/survival compaction, audit preservation and portable predictions passed\n")

# Full screening belongs to one partition audit, outside each arm's compact
# portable model. It remains a required integrity-checked run artifact.
value <- validated
value$config$output_dir <- tempfile("bmp-screening-audit-")
value$config$models <- "stepwise"; value$config$feature_sets <- "genes"
value$config$panel_sizes <- 1L
run <- bmp_new_run(value$config, value$qc)
result <- bmp_run_engine(value, run)
manifest <- bmp_read_json(file.path(run$dir, "manifest.json"))
screening_path <- file.path(run$dir, "screening", "final.json")
audit <- bmp_read_json(screening_path)
assert(length(audit$inner) == value$config$inner_folds, "Inner partition screening audits were lost")
assert(identical(audit$fitting$audit$screening_sha256, result$model$recipe$screening_audit$screening_sha256), "Portable model does not identify its full partition audit")
assert("screening/final.json" %in% unlist(manifest$required_artifacts), "Screening audit is not a required artifact")
assert(identical(bmp_sha256(screening_path), manifest$engine_artifact_verification$sha256[["screening/final.json"]]), "Screening audit has no recorded integrity hash")
cat("Partition screening audit persistence and manifest integrity checks passed\n")

# Exact weighted ROC/PR curve oracle with tied scores and noninteger weights.
reference_curve <- function(y, probability, weights) {
  thresholds <- sort(unique(probability), decreasing = TRUE)
  positive <- sum(weights[y == 1]); negative <- sum(weights[y == 0])
  tp <- c(0, cumsum(vapply(thresholds, function(t) sum(weights[y == 1 & probability == t]), numeric(1))))
  fp <- c(0, cumsum(vapply(thresholds, function(t) sum(weights[y == 0 & probability == t]), numeric(1))))
  data.frame(threshold = c(Inf, thresholds), true_positive = tp, false_positive = fp,
    sensitivity = if (positive > 0) tp/positive else NA_real_, false_positive_rate = if (negative > 0) fp/negative else NA_real_,
    precision = ifelse(tp + fp > 0, tp/pmax(tp + fp, .Machine$double.eps), 1))
}
set.seed(312)
for (iteration in seq_len(100)) {
  n <- sample.int(300, 1); y <- sample(0:1, n, TRUE)
  p <- round(runif(n), sample(0:3, 1)); weights <- rexp(n) + .01
  close(bmp_binary_curve(y, p, weights), reference_curve(y, p, weights), "Cumulative ROC/PR changed weighted ties", 1e-12)
}
cat("Weighted ROC/PR cumulative-scan equivalence passed\nAll performance correctness tests passed.\n")
