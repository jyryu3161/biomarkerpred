#!/usr/bin/env Rscript
args <- commandArgs(trailingOnly = FALSE)
script <- sub("^--file=", "", args[grepl("^--file=", args)])
root <- normalizePath(file.path(dirname(script), ".."), mustWork = TRUE)
source(file.path(root, "R", "load.R"))
assert <- function(value, message) if (!isTRUE(value)) stop(message, call. = FALSE)
near <- function(actual, expected, message, tolerance = 1e-10) assert(isTRUE(all.equal(as.numeric(actual), as.numeric(expected), tolerance = tolerance)), message)
expect_error <- function(expr, pattern = NULL) {
  value <- tryCatch({ force(expr); NULL }, error = function(error) error)
  assert(inherits(value, "error"), "Expected error")
  if (!is.null(pattern)) assert(grepl(pattern, conditionMessage(value), fixed = TRUE), conditionMessage(value))
  invisible(value)
}
scratch <- tempfile("bmp-metrics-"); dir.create(scratch)
y <- c(0,0,1,1); p <- c(.1,.4,.35,.8)
b <- bmp_binary_metrics(y, p)
near(b$metrics$roc_auc$estimate, .75, "ROC AUC oracle")
near(b$metrics$average_precision$estimate, 5/6, "Average precision oracle")
near(b$metrics$brier$estimate, .158125, "Brier oracle")
near(b$metrics$sensitivity$estimate, .5, "Sensitivity oracle")
near(b$metrics$specificity$estimate, 1, "Specificity oracle")
near(b$curves$dca$model[abs(b$curves$dca$threshold-.2)<1e-10], .4375, "DCA .2 oracle")
near(b$curves$dca$model[abs(b$curves$dca$threshold-.5)<1e-10], .25, "DCA .5 oracle")
assert(all(b$curves$dca$treat_none == 0), "Treat none must be zero")
near(bmp_binary_metrics(y, rep(.5,4))$metrics$roc_auc$estimate, .5, "Tied probability AUC")
near(bmp_binary_metrics(y, rep(.5,4))$metrics$average_precision$estimate, .5, "Tied probability AP")
near(bmp_binary_metrics(y, rep(.5,4))$metrics$brier$estimate, .25, "Constant probability Brier")
near(bmp_binary_metrics(y, p, c(.05,.5,.3,.9))$metrics$sensitivity$estimate, .5, "Per-row frozen thresholds")
assert(is.na(bmp_binary_metrics(rep(0,4), p)$metrics$roc_auc$estimate), "One class must not produce AUC")
assert(nzchar(bmp_binary_metrics(rep(0,4), p)$metrics$roc_auc$reason), "Unavailable AUC requires reason")
assert(is.na(bmp_binary_metrics(y, rep(.5,4))$metrics$calibration_slope$estimate), "Constant score calibration slope is unidentified")
expect_error(bmp_binary_metrics(y, c(p[-1],2)), "probabilities")
curve <- list(time = c(1,2,4,5), survival = rep(1,4))
s <- bmp_survival_metrics(c(1,2,4,5), rep(1,4), 1-c(.8,.6,.3,.1), c(4,3,2,1), 3, curve, c(1,5))
near(s$metrics$brier$estimate, .075, "Uncensored Brier oracle")
near(s$metrics$harrell_c$estimate, 1, "Harrell oracle")
near(s$metrics$time_auc$estimate, 1, "Time AUC oracle")
curve$survival <- c(1,.5,.5,0)
ipcw <- bmp_survival_metrics(c(1,2,4,5), c(1,0,1,0), 1-c(.8,.6,.3,.1), c(4,3,2,1), 3, curve, c(1,5))
near(ipcw$metrics$brier$estimate, .06, "IPCW Brier denominator must include early-censored row")
near(ipcw$curves$ipcw$control_weight[2], 0, "Early censor must not be negative")
near(ipcw$curves$dca$model[abs(ipcw$curves$dca$threshold-.5)<1e-10], .25, "Survival IPCW DCA")
ties <- bmp_censor_curve(c(1,1,2,3), c(1,0,1,0))
near(bmp_censor_value(ties,1,left=TRUE), 1, "Left-limit censor weight")
near(bmp_censor_value(ties,1), 2/3, "Reverse KM tie rule")
zero <- bmp_survival_metrics(c(1,2,4,5), c(1,0,1,0), 1-c(.8,.6,.3,.1), c(4,3,2,1), 5, curve, c(1,5))
assert(is.na(zero$metrics$brier$estimate) && grepl("zero", zero$metrics$brier$reason), "Zero censor support should be unavailable")
outside <- bmp_survival_metrics(c(1,2,4,5), rep(1,4), rep(.5,4), 1:4, 6, list(time=1:6,survival=rep(1,6)), c(1,6))
assert(is.na(outside$metrics$brier$estimate), "Assessment support must be checked")
# Independent Harrell agreement, including event/censor ties.
time <- c(1,1,2,3,4,5); event <- c(1,0,1,1,0,1); lp <- c(.8,.1,.8,-.3,.2,0)
reference <- survival::concordance(survival::Surv(time,event) ~ lp, reverse = TRUE)$concordance
check <- bmp_survival_metrics(time,event,rep(.5,6),lp,3,list(time=1:5,survival=rep(1,5)),c(1,5))
near(check$metrics$harrell_c$estimate, reference, "Harrell comparable pairs disagree with survival package")
cat("Known binary and censor-aware survival metric oracles passed\n")

# Repeated OOF predictions retain a group sampling unit, not one unit per row.
base <- data.frame(sample_id = sprintf("%04d",1:4), group_id = c("A","A","B","B"), repeat_id = 1,
  split_id = "r1f1", role = "primary", arm_id = "arm", threshold = .5, probability = p,
  outcome_binary = y, event = NA_real_, time = NA_real_)
second <- base; second$repeat_id <- 2; second$split_id <- "r2f1"
repeated <- rbind(base, second)
config <- list(analysis_type="binary",bootstrap_samples=40L,seed=7L)
metrics <- bmp_compute_metrics(repeated,list(r1f1=list(),r2f1=list()),config)
again <- bmp_compute_metrics(repeated,list(r1f1=list(),r2f1=list()),config)
assert(identical(metrics,again), "Bootstrap must be deterministic")
assert(metrics$primary$counts$patient_groups == 2 && metrics$primary$counts$unique_samples == 4 && metrics$primary$counts$prediction_rows == 8 && metrics$primary$counts$repeats == 2, "Repeated predictions inflated independent counts")
near(metrics$primary$metrics$brier$estimate, b$metrics$brier$estimate, "Repeats should preserve point metric")
assert(metrics$primary$metrics$roc_auc$bootstrap_failed > 0, "Degenerate cluster bootstrap failures must be recorded")
draw <- bmp_bootstrap_predictions(repeated,3)
assert(length(unique(draw$group_id)) == 2 && all(table(draw$group_id)==4), "Bootstrap failed to retain all repeated rows or rename duplicate draws")
assert(all(vapply(split(draw,draw$group_id),function(rows) length(unique(rows$repeat_id))==2,logical(1))), "Bootstrap separated repeats")
config$bootstrap_samples <- 0L
no_ci <- bmp_compute_metrics(repeated,list(r1f1=list(),r2f1=list()),config,expected_arms="failed_arm")
assert(is.na(no_ci$primary$metrics$brier$lower) && no_ci$primary$metrics$brier$bootstrap_requested==0, "Bootstrap zero must disable CI")
assert(!no_ci$comparisons$failed_arm$coverage$complete, "Missing arm coverage must be explicit")
invisible(bmp_write_metric_outputs(no_ci, file.path(scratch,"failed-arm-output")))
csv <- file.path(scratch,"predictions.csv"); bmp_atomic_csv(repeated,csv)
restored <- bmp_read_predictions(csv)
assert(identical(restored$sample_id,repeated$sample_id) && identical(restored$group_id,repeated$group_id), "CSV reader lost string identifiers")
assert(is.numeric(restored$probability), "Known numeric result fields were not parsed")
cat("Grouped repeated-prediction bootstrap, coverage and CSV tests passed\n")

fixture <- function(type) {
  config <- bmp_load_config(file.path(root,"tests","fixtures",paste0(type,".json")))
  config$output_dir <- file.path(scratch,paste0("engine-",type)); config$models <- "stepwise"; config$feature_sets <- "clinical"; config$panel_sizes <- 1L
  config$p_threshold <- 1; config$p_adjust_method <- "none"; config$bootstrap_samples <- 0L
  bmp_validate_data(config)
}
for (type in c("binary","survival")) {
  validated <- fixture(type); run <- bmp_new_run(validated$config,validated$qc)
  fitted <- bmp_run_engine(validated,run)
  result <- bmp_metrics_for_run(run$dir)
  assert(result$primary$counts$patient_groups==40 && result$primary$coverage$complete, "Run metrics cohort/coverage wrong")
  assert(length(result$primary$curve_files)>0 && file.exists(file.path(run$dir,"evaluation","metrics_table.csv")), "Reusable curves missing")
  model_path <- file.path(run$dir,"model.bmpmodel"); model <- bmp_load_model(model_path); before <- bmp_sha256(model_path)
  assert(length(unlist(model$training$identifier_hashes$sample))==80 && length(unlist(model$training$identifier_hashes$group))==40, "Training identifier hash counts wrong")
  assert(!"0001" %in% unlist(model$training$identifier_hashes), "Raw training identifiers stored")
  # Input corruption is refused before any derived metrics are overwritten.
  prediction_path <- file.path(run$dir,"predictions.csv")
  raw <- readBin(prediction_path,"raw",n=file.info(prediction_path)$size)
  cat("tamper",file=prediction_path,append=TRUE)
  expect_error(bmp_metrics_for_run(run$dir),"integrity")
  writeBin(raw,prediction_path)
  external <- validated$data[1:8,,drop=FALSE]
  external$sample <- paste0("E",external$sample); external$patient <- paste0("E",external$patient)
  if (type=="binary") external$response <- "0" else { external$OS <- 0; external$OS.year <- rep(c(1,2,4,5),2) }
  external_path <- file.path(scratch,paste0(type,"-external.csv")); bmp_atomic_csv(external,external_path)
  scored <- bmp_evaluate(model_path,external_path,file.path(scratch,"evaluations"),bootstrap_samples=0, time_unit=if(type=="survival") "years" else NULL)
  assert(identical(before,bmp_sha256(model_path)) && scored$model_unchanged, "External evaluation changed source model")
  assert(scored$run$manifest$status=="running" && scored$status=="metrics_ready", "Evaluation falsely completed before reports")
  assert(scored$qc$groups==4, "Small external cohort incorrectly required development CV counts")
  discrimination <- if(type=="binary") "roc_auc" else "harrell_c"
  assert(is.na(scored$metrics$primary$metrics[[discrimination]]$estimate), "One-class/no-event discrimination must be unavailable")
  assert(is.finite(scored$metrics$primary$metrics$brier$estimate), "One-class/no-event Brier should remain available within support")
  # Same model bytes, and independent prediction entry supports absent outcomes.
  outcome_columns <- if(type=="binary") "response" else c("OS","OS.year")
  unlabeled <- external[setdiff(names(external),outcome_columns)]
  accepted <- bmp_validate_prediction_data(model,unlabeled,require_outcomes=FALSE)
  prediction <- bmp_predict_model(model,accepted$data)
  near(prediction$linear_predictor,scored$predictions$linear_predictor,"Evaluation did not use frozen model predictions")
  expect_error(bmp_validate_prediction_data(model,unlabeled,require_outcomes=TRUE),"not found")
  if(type=="survival") expect_error(bmp_evaluate(model_path,external_path,file.path(scratch,"evaluations"),0,time_unit="months"),"Time-unit mismatch")
  bad <- external; bad$sex <- "unseen"
  bad_path <- file.path(scratch,paste0(type,"-unknown.csv")); bmp_atomic_csv(bad,bad_path)
  error <- expect_error(bmp_evaluate(model_path,bad_path,file.path(scratch,"evaluations"),0),"Unseen category")
  failed <- bmp_read_json(file.path(error$run_dir,"manifest.json")); failed_qc <- bmp_read_json(file.path(error$run_dir,"qc.json"))
  assert(failed$status=="failed" && failed_qc$status=="failed" && !is.null(failed_qc$unknown_categories$sex),"Failed evaluation did not preserve diagnostic manifest/QC")
  assert(identical(before,bmp_sha256(model_path)),"Failed evaluation changed model")
  missing <- external; missing$age <- NULL
  expect_error(bmp_validate_prediction_data(model,missing,TRUE),"not found")
  malformed <- external
  if(type=="binary") malformed$response[1] <- "invalid" else malformed$OS[1] <- 2
  expect_error(bmp_validate_prediction_data(model,malformed,TRUE),if(type=="binary") "declared" else "event codes")
  overlap <- bmp_distribution_drift(model,validated$data,bmp_sha256(validated$config$data_file))
  assert(overlap$overlap$identical_development_input && overlap$overlap$samples==80 && overlap$overlap$groups==40,"Development overlap audit failed")
  shifted <- external; shifted$age <- shifted$age+100
  drift <- bmp_distribution_drift(model,shifted)
  age <- drift$numeric_and_missingness[drift$numeric_and_missingness$predictor=="age",]
  assert(age$outside_training_range==8 && age$mean_difference_standardized>1,"Frozen training distribution comparison failed")
  # Within-fold concordance must be invariant to arbitrary LP origin per fold.
  if(type=="survival") {
    pred <- bmp_read_predictions(file.path(run$dir,"predictions.csv")); models <- bmp_read_json(file.path(run$dir,"fold_models.json"))
    original <- bmp_compute_metrics(pred,models,validated$config)
    target <- unique(pred$split_id)[1]; pred$linear_predictor[pred$split_id==target] <- pred$linear_predictor[pred$split_id==target]+100
    for(arm in names(models[[target]]$models)) models[[target]]$models[[arm]]$baseline$reference_lp <- models[[target]]$models[[arm]]$baseline$reference_lp+100
    changed <- bmp_compute_metrics(pred,models,validated$config)
    near(changed$primary$metrics$harrell_c$estimate,original$primary$metrics$harrell_c$estimate,"Concordance pooled incompatible LP origins")
  }
  cat(type,"engine metrics and immutable external evaluation checks passed\n")
}
manifests <- bmp_list_runs(file.path(scratch,"evaluations"))
assert(length(manifests)>=5 && all(vapply(manifests,function(m) identical(m$operation,"evaluate"),logical(1))),"External evaluations absent from run history")
unlink(scratch,recursive=TRUE)
cat("All stage-3a metrics/evaluation tests passed.\n")
