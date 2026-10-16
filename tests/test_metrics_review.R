# Independent numerical oracles, kept separate from implementation-owned tests.
script <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())][1L])
repo <- dirname(dirname(normalizePath(script, mustWork = TRUE)))
source(file.path(repo, "R", "load.R"))
close_to <- function(actual, expected, tolerance = 1e-10) {
  stopifnot(length(actual) == length(expected), all(is.finite(actual)),
    isTRUE(all.equal(as.numeric(actual), as.numeric(expected), tolerance = tolerance)))
}
unavailable <- function(cell) {
  stopifnot(is.null(cell$estimate) || (length(cell$estimate) == 1L && is.na(cell$estimate)),
    length(cell$reason) == 1L, nzchar(cell$reason))
}
y <- c(0, 0, 1, 1)
p <- c(.1, .4, .35, .8)
binary <- bmp_binary_metrics(y, p, threshold = .5, groups = c("a", "a", "b", "b"))
close_to(binary$metrics$roc_auc$estimate, .75)
close_to(binary$metrics$average_precision$estimate, 5/6)
close_to(binary$metrics$brier$estimate, .158125)
close_to(binary$metrics$sensitivity$estimate, .5)
close_to(binary$metrics$specificity$estimate, 1)
dca <- binary$curves$dca
close_to(dca$model[which.min(abs(dca$threshold - .2))], .4375)
close_to(dca$model[which.min(abs(dca$threshold - .5))], .25)
close_to(dca$treat_none, rep(0, nrow(dca)))
per_row <- bmp_binary_metrics(y, p, threshold = c(.05, .5, .3, .9))
close_to(per_row$metrics$sensitivity$estimate, .5)
close_to(per_row$metrics$specificity$estimate, .5)
ties <- bmp_binary_metrics(y, rep(.5, 4))
close_to(ties$metrics$roc_auc$estimate, .5)
close_to(ties$metrics$average_precision$estimate, .5)
close_to(ties$metrics$brier$estimate, .25)
one_class <- bmp_binary_metrics(rep(0, 4), p)
unavailable(one_class$metrics$roc_auc)
close_to(one_class$metrics$brier$estimate, mean(p^2))

time <- c(1, 2, 4, 5)
event_probability <- c(.8, .6, .3, .1)
no_censor <- list(time = I(c(1, 2, 4, 6)), survival = I(rep(1, 4)))
survival <- bmp_survival_metrics(time, rep(1, 4), 1 - event_probability,
  stats::qlogis(event_probability), horizon = 3, censor_curve = no_censor,
  support = c(1, 6), groups = letters[1:4], risk_group = c("High", "High", "Low", "Low"))
close_to(survival$metrics$brier$estimate, .075)
close_to(survival$metrics$time_auc$estimate, 1)
close_to(survival$metrics$harrell_c$estimate, 1)
constant_risk <- bmp_survival_metrics(time, rep(1, 4), rep(.5, 4), rep(0, 4),
  horizon = 3, censor_curve = no_censor, support = c(1, 6), groups = letters[1:4])
close_to(constant_risk$metrics$harrell_c$estimate, .5)
close_to(constant_risk$metrics$time_auc$estimate, .5)
ordinary <- bmp_binary_metrics(as.integer(time <= 3), event_probability)
close_to(survival$metrics$brier$estimate, ordinary$metrics$brier$estimate)

# Row 2 is censored at time 2: its Brier contribution is zero, not an
# observed non-event with squared error .6^2.
censor <- list(time = I(c(1, 2, 3, 6)), survival = I(c(1, .5, .5, .5)))
weighted <- bmp_survival_metrics(time, c(1, 0, 1, 0), 1 - event_probability,
  stats::qlogis(event_probability), horizon = 3, censor_curve = censor,
  support = c(1, 6), groups = letters[1:4], risk_group = c("High", "High", "Low", "Low"))
close_to(weighted$metrics$brier$estimate, .06)
unsupported <- bmp_survival_metrics(time, rep(1, 4), 1 - event_probability,
  stats::qlogis(event_probability), horizon = 10, censor_curve = no_censor,
  support = c(1, 6), groups = letters[1:4])
unavailable(unsupported$metrics$brier)
unavailable(unsupported$metrics$time_auc)
zero_support <- list(time = I(c(1, 2, 3, 6)), survival = I(c(1, 0, 0, 0)))
undefined <- bmp_survival_metrics(time, c(1, 0, 1, 0), 1 - event_probability,
  stats::qlogis(event_probability), horizon = 3, censor_curve = zero_support,
  support = c(1, 6), groups = letters[1:4])
unavailable(undefined$metrics$brier)
unavailable(undefined$metrics$time_auc)

# Independent package reference also exercises tied event/censor times and
# tied risk scores, not just perfectly ordered toy examples.
set.seed(809)
for (iteration in seq_len(100)) {
  tied_time <- sample(1:8, 30, replace = TRUE)
  tied_event <- rbinom(30, 1, .6)
  tied_lp <- sample(0:4, 30, replace = TRUE)
  pairs <- bmp_concordance_pairs(tied_time, tied_event, tied_lp, rep(1, 30))
  reference <- survival::concordance(survival::Surv(tied_time, tied_event) ~ tied_lp,
    reverse = TRUE)$concordance
  close_to(pairs$numerator/pairs$denominator, reference)
}
cat("Primary-session binary, threshold, tie, IPCW and support oracles passed.\n")

validated <- bmp_validate_data(file.path(repo, "tests", "fixtures", "binary.json"))
arm <- list(algorithm = "stepwise", feature_set = "combined", panel_size = 1L,
  alpha = NULL, lambda_ratio = NULL, arm_id = "external-review")
fit <- bmp_fit_model(validated$data, validated$config, arm)
fit$artifact$threshold <- .5
fit$artifact$threshold_method <- "Unit-test fixed threshold"
temporary <- tempfile("bmp-external-review-")
dir.create(temporary)
model_path <- file.path(temporary, "frozen.bmpmodel")
bmp_save_model(fit, model_path)
before <- bmp_sha256(model_path)
external <- validated$data[1:4, , drop = FALSE]
external$sample <- paste0("external-", external$sample)
external$patient <- paste0("external-", external$patient)
external$response <- "0"
input_path <- file.path(temporary, "one-class.csv")
write.csv(external, input_path, row.names = FALSE, na = "")
evaluation <- bmp_evaluate(model_path, input_path, temporary, bootstrap_samples = 0)
stopifnot(identical(before, bmp_sha256(model_path)), evaluation$model_unchanged,
  is.finite(evaluation$metrics$primary$metrics$brier$estimate),
  bmp_read_json(file.path(evaluation$run_dir, "manifest.json"))$status == "running")
unavailable(evaluation$metrics$primary$metrics$roc_auc)
bad <- external
bad$age <- "invalid-numeric"
bad_path <- file.path(temporary, "bad.csv")
write.csv(bad, bad_path, row.names = FALSE, na = "")
error <- tryCatch(bmp_evaluate(model_path, bad_path, temporary, bootstrap_samples = 0), error = identity)
stopifnot(inherits(error, "bmp_evaluation_error"),
  bmp_read_json(file.path(error$run_dir, "manifest.json"))$status == "failed",
  bmp_read_json(file.path(error$run_dir, "qc.json"))$status == "failed",
  identical(before, bmp_sha256(model_path)))
cat("Primary-session one-class external evaluation, frozen model and failed-QC persistence passed.\n")
