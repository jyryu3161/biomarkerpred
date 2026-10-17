#!/usr/bin/env Rscript
# Run from the repository root with Rscript tests/test_survival_bugfixes.R.
# Requires jsonlite and survival. Also exercises the real AUC estimator when
# nsROC is installed; controlled estimator failures remain deterministic.
suppressPackageStartupMessages(library(jsonlite))
suppressPackageStartupMessages(library(survival))
root <- normalizePath(getwd())
stopifnot(file.exists(file.path(root, "Predict_New.R")))
work <- tempfile("bmp-survival-regression-")
dir.create(work)
expect <- function(value, message) {
  if (!isTRUE(value)) stop(message, call. = FALSE)
}
expect_error <- function(expr, pattern) {
  error <- tryCatch({ force(expr); NULL }, error = identity)
  expect(inherits(error, "error") && grepl(pattern, conditionMessage(error)),
         paste("Expected error matching", pattern))
}

# Read the actual production functions without loading unrelated plotting
# packages. This permits core regression checks with the existing locked R.
engine <- new.env(parent = globalenv())
for (expr in parse(file.path(root, "Survival_TrainAUC_StepwiseSelection.R"))) {
  if (is.call(expr) && identical(expr[[1]], as.name("<-")) &&
      (is.call(expr[[3]]) && identical(expr[[3]][[1]], as.name("function")) ||
       identical(expr[[2]], as.name("surv_auc_columns")))) {
    eval(expr, envir = engine)
  }
}
source(file.path(root, "Save_Model.R"))

# A nonzero mean in the complete outcome subset catches accidental Cox
# centering when deriving a threshold for the uncentered prediction score.
set.seed(43)
dat <- data.frame(sample = paste0("synthetic-", seq_len(100)),
                  Survtime = rexp(100), Event = rbinom(100, 1, 0.7),
                  GENE = sort(rnorm(100, mean = 3)))
dat$Survtime <- dat$Survtime / exp(0.8 * dat$GENE) * 50
dat$Event[1:15] <- NA_integer_
result <- matrix(c("GENE", "0.75", NA_character_, "", "prediction horizon exceeds observed follow-up"), nrow = 1,
                 dimnames = list(NULL, engine$surv_auc_columns))
config <- list(survival = list(data_file = "synthetic.csv", event = "Event", horizon = 5))
model_path <- SaveModelArtifact(dat, result, "survival", work, 1, 0.7, config)
artifact <- fromJSON(model_path)
expect(is.list(fromJSON(model_path, simplifyVector = FALSE)$model$variables),
       "Even a one-gene model must serialize its variables as a JSON array")
scaled <- (dat$GENE - artifact$scaling$GENE$mean) / artifact$scaling$GENE$sd
complete <- complete.cases(dat[, c("Survtime", "Event", "GENE")])
training_risk <- exp(scaled[complete] * artifact$model$coefficients$GENE)
expect(abs(artifact$model$risk_threshold - median(training_risk)) < 1e-12,
       "Threshold must use training scores in the serialized prediction units")
centered_cutoff <- median(exp((scaled[complete] - mean(scaled[complete])) * artifact$model$coefficients$GENE))
expect(abs(centered_cutoff - artifact$model$risk_threshold) > 1e-4,
       "Fixture must distinguish centered and uncentered Cox score units")
expect(is.null(artifact$performance$test_auc), "Unavailable saved AUC must be JSON null")
expect(identical(artifact$performance$test_auc_reason, unname(result[1,5])), "Saved model must preserve the missing-AUC reason")

ordered <- which(complete)[order(training_risk)]
new_data <- dat[ordered[c(1, length(ordered)-1, length(ordered))], c("sample", "GENE")]
old_scores <- exp(((new_data$GENE - artifact$scaling$GENE$mean) / artifact$scaling$GENE$sd) * artifact$model$coefficients$GENE)
expect(ifelse(old_scores[1] >= median(old_scores[1]), "High", "Low") == "High" &&
       ifelse(old_scores[1] >= median(old_scores), "High", "Low") == "Low",
       "Fixture must reproduce the old single-versus-batch High/Low bug")
rscript <- Sys.getenv("BMP_RSCRIPT", file.path(R.home("bin"), "Rscript"))
run_prediction <- function(data, model = model_path, name) {
  input <- file.path(work, paste0(name, ".csv"))
  output <- file.path(work, name)
  log <- file.path(work, paste0(name, ".log"))
  write.csv(data, input, row.names = FALSE)
  status <- suppressWarnings(system2(rscript, shQuote(c(file.path(root, "Predict_New.R"),
      paste0("--model=", model), paste0("--data=", input), paste0("--output=", output))),
      stdout = log, stderr = log))
  list(status = status, path = file.path(output, "prediction_results.csv"), log = readLines(log))
}
single <- run_prediction(new_data[1, , drop = FALSE], name = "single")
batch <- run_prediction(new_data, name = "batch")
expect(single$status == 0 && batch$status == 0, "Frozen-model prediction CLI must succeed")
a <- read.csv(single$path)
b <- read.csv(batch$path)
expect(identical(a$risk_score, b$risk_score[1]) && identical(a$linear_predictor, b$linear_predictor[1]),
       "The same patient must retain identical scores")
expect(identical(a$risk_group, b$risk_group[1]) && identical(a$risk_group, "Low"),
       "The same patient must retain its training-cutoff risk group")
legacy <- artifact
legacy$model$risk_threshold <- NULL
legacy_path <- file.path(work, "legacy.bmpmodel")
write(toJSON(legacy, auto_unbox = TRUE, digits = NA), legacy_path)
rejected <- run_prediction(new_data, legacy_path, "legacy")
expect(rejected$status != 0 && !file.exists(rejected$path) && any(grepl("Retrain", rejected$log)),
       "A legacy artifact without a training cutoff must fail clearly before writing predictions")

# Unavailable support, estimator errors, and estimator NA must retain reasons.
auc_data <- data.frame(Survtime = c(1, 2, 3, 5, 7, 9), Event = c(1, 0, 1, 0, 1, 0))
marker <- seq_len(nrow(auc_data))
engine$cdROC <- function(...) stop("estimator must not be called without support")
for (horizon in c(0, 9, 10)) {
  value <- engine$surv_auc(auc_data, marker, horizon, "unsupported fixture")
  expect(is.na(value$value) && nzchar(value$reason), "Unsupported AUC must remain NA with a reason")
}
engine$cdROC <- function(...) stop("controlled estimator failure")
value <- engine$surv_auc(auc_data, marker, 4)
expect(is.na(value$value) && grepl("controlled estimator failure", value$reason), "Estimator errors must be explicit")
engine$cdROC <- function(...) list(auc = NA_real_)
value <- engine$surv_auc(auc_data, marker, 4)
expect(is.na(value$value) && grepl("unavailable", value$reason), "Estimator NA must never become zero")
engine$cdROC <- function(...) list(auc = 0)
expect(identical(engine$surv_auc(auc_data, marker, 4)$value, 0), "A genuinely measured zero AUC must remain zero")
expect(is.na(engine$surv_auc_mean(c(NA, NA))), "All-unavailable means must be NA, not NaN or zero")
expect(identical(engine$surv_auc_mean(c(NA, 0.8)), 0.8), "Unavailable folds must not depress the mean to zero")

# Use actual Cox fits with a deterministic partition to exercise every
# selection branch's unavailable-horizon behavior reproducibly.
set.seed(9)
selection_data <- data.frame(Survtime = c(seq_len(30), seq_len(10)),
                             Event = rep(c(0, 1), 20), GENE = rnorm(40), OTHER = rnorm(40))
engine$createDataPartition <- function(...) matrix(seq_len(30), ncol = 1)
engine$cdROC <- function(...) list(auc = 0.72, TPR = c(0, 1), TNR = c(1, 0))
all_na <- engine$Survforward_step(selection_data, "GENE", "", 100, 1, 0.75)
expect(is.na(as.numeric(all_na[1,2])) && is.na(as.numeric(all_na[1,3])) &&
       nzchar(all_na[1,4]) && nzchar(all_na[1,5]), "Forward summaries must keep unavailable AUCs and reasons")
backward <- engine$Survbackward_step(selection_data, "OTHER", c("GENE", "OTHER"), 100, 1, 0.75)
expect(is.na(as.numeric(backward[1,2])) && nzchar(backward[1,4]), "Backward summaries must keep unavailable AUCs and reasons")
expect(length(engine$surv_best_auc_row(all_na)) == 0 &&
       length(engine$surv_best_auc_row(engine$surv_auc_summary(NULL))) == 0,
       "All-NA or empty summaries must have no winning candidate")
prescreened <- engine$Survprescreen_candidates(selection_data, c("GENE", "OTHER"), "", 1, 0.75, 1, 100)
expect(identical(prescreened, c("GENE", "OTHER")), "All-NA prescreening must not invent a best score")
failed_dir <- file.path(work, "all-na-selection")
expect_error(engine$SurvTrainAUCStepwise("GENE", selection_data, "", "", 100, 1, 0.75, failed_dir),
             "No candidate has an available training AUC")
failed_csv <- read.csv(file.path(failed_dir, "Forward_AUC_Step1.csv"))
expect(is.na(failed_csv$trainAUC[1]) && nzchar(failed_csv$trainAUC_reason[1]) &&
       !file.exists(file.path(failed_dir, "Final_Stepwise_Total.csv")),
       "All-NA selection must export diagnostics without creating a successful final selection")
partial_dir <- file.path(work, "partial-selection")
selected <- engine$SurvTrainAUCStepwise("GENE", selection_data, "", "", 20, 1, 0.75, partial_dir)
partial_csv <- read.csv(file.path(partial_dir, "Final_Stepwise_Total.csv"))
expect(as.numeric(selected[1,2]) == 0.72 && is.na(as.numeric(selected[1,3])) &&
       is.na(partial_csv$testAUC[1]) && nzchar(partial_csv$testAUC_reason[1]),
       "Valid training AUC must preserve the original selection policy while test AUC stays unavailable")
intermediate_csv <- read.csv(file.path(partial_dir, "Intermediate_Forward1.csv"))
expect(identical(unname(selected[1,1]), "GENE") && identical(partial_csv$Variable, "GENE") &&
       identical(intermediate_csv$Variable, " + GENE") &&
       identical(partial_csv$trainAUC, intermediate_csv$trainAUC) &&
       identical(partial_csv$testAUC, intermediate_csv$testAUC),
       "Only the final formula should lose its empty term; selected genes and AUCs must stay unchanged")

# Plot preparation must also export unavailable values and reasons.
old_dir <- getwd()
setwd(work)
plot_result <- selected
expect_error(engine$PlotSurvROC(selection_data, 1, 0.75, plot_result, 100), "No available AUC")
roc_csv <- read.csv("Surv_ROC_AUC.csv")
expect(all(is.na(roc_csv$trainAUC)) && all(nzchar(roc_csv$trainAUC_reason)),
       "ROC summary must not fabricate zeros")
engine$PLOT_FONT <- "sans"
engine$nature_colors <- list(blue = "#1f77b4", red = "#d62728")
engine$PlotSurvROC(selection_data, 1, 0.75, plot_result, 20)
partial_roc <- read.csv("Surv_ROC_AUC.csv")
expect(all(partial_roc$trainAUC == 0.72) && all(is.na(partial_roc$testAUC)) &&
       all(nzchar(partial_roc$testAUC_reason)),
       "One cohort's unavailable ROC must not erase the other cohort's available AUC")
engine$cdROC <- function(...) list(auc = NA_real_)
expect_error(engine$PlotSurvTimeAUC(selection_data, 1, 0.75, plot_result), "No available time-dependent AUC")
time_csv <- read.csv("Surv_Time_AUC.csv")
expect(nrow(time_csv) > 0 && all(is.na(time_csv$auc)) && all(nzchar(time_csv$reason)),
       "Time-AUC export must retain unavailable rows and reasons")
setwd(old_dir)

if (requireNamespace("nsROC", quietly = TRUE)) {
  engine$cdROC <- nsROC::cdROC
  actual <- engine$surv_auc(dat[complete, ], log(training_risk), median(dat$Survtime[complete]), "real nsROC")
  expect(is.finite(actual$value) && actual$value >= 0 && actual$value <= 1 && !nzchar(actual$reason),
         "Real nsROC must return an available AUC for supported synthetic data")
  cat("Real nsROC estimator check passed.\n")
} else {
  cat("SKIP: real nsROC estimator unavailable; actual Cox fitting, serialization, CLI prediction and controlled AUC failures were tested.\n")
}

# Exercise all legacy survival plots using a real one-gene stepwise result.
# Each SVG must be created afresh so a swallowed graphics error cannot pass.
plot_packages <- c("nsROC", "caret", "ggplot2", "tiff", "reshape2", "systemfonts")
if (all(vapply(plot_packages, requireNamespace, logical(1), quietly = TRUE))) {
  plotting <- new.env(parent = globalenv())
  sys.source(file.path(root, "Survival_TrainAUC_StepwiseSelection.R"), envir = plotting)
  plot_dir <- file.path(work, "single-gene-plots")
  dir.create(plot_dir)
  setwd(plot_dir)
  plot_data <- dat[complete, ]
  plot_horizon <- median(plot_data$Survtime)
  plot_selection <- plotting$SurvTrainAUCStepwise("GENE", plot_data, "", "", plot_horizon,
                                               1, 0.7, file.path(plot_dir, "selection"))
  expect(identical(unname(plot_selection[1,1]), "GENE"), "Actual stepwise output must have a usable one-gene formula")
  plotting$PlotSurvROC(plot_data, 1, 0.7, plot_selection, plot_horizon)
  plotting$PlotSurVarImp(plot_data, plot_selection)
  plotting$PlotSurvKM(plot_data, 1, 0.7, plot_selection, plot_horizon)
  plotting$PlotSurvTimeAUC(plot_data, 1, 0.7, plot_selection)
  plotting$PlotSurvRiskDist(plot_data, plot_selection)
  plot_names <- c("Surv_ROCcurve", "Surv_Variable_Importance", "Surv_Kaplan_Meier",
                  "Surv_Time_AUC", "Surv_Risk_Distribution", "Surv_Risk_Group_Boxplot")
  paths <- file.path("figures", paste0(plot_names, ".svg"))
  expect(all(file.exists(paths)) && all(file.info(paths)$size > 100),
         "All six SVG artifacts from the five single-gene plotting functions must exist")
  setwd(old_dir)
  cat("Actual single-gene stepwise plotting checks passed.\n")
} else {
  cat("SKIP: full legacy plotting runtime unavailable; single-gene formula and ROC preparation were tested.\n")
}
unlink(work, recursive = TRUE)
cat("Survival v0.4.3 regression checks passed.\n")
