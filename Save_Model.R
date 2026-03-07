# Save_Model.R
# Exports trained model artifact as .bmpmodel (JSON) for later prediction use.
# Called from Main_Binary.R / Main_Survival.R after stepwise selection completes.

library(jsonlite)

SaveModelArtifact <- function(dat, Result, analysis_type, output_dir,
                               numSeed, SplitProp, config) {

  # 1. Extract variables from Result formula
  if (analysis_type == "binary") {
    vars <- extract_vars(Result[1,1])
  } else {
    vars <- gsub(" ", "", strsplit(as.character(Result[1,1]), "\\+")[[1]])
    vars <- vars[vars != ""]
  }

  if (length(vars) == 0) {
    cat("STEPWISE_LOG:Warning - No variables to save in model artifact\n", file = stderr())
    return(NULL)
  }

  # 2. Compute scaling parameters from FULL dataset
  scaling <- list()
  for (v in vars) {
    col_data <- dat[[v]]
    col_data <- col_data[!is.na(col_data)]
    scaling[[v]] <- list(mean = mean(col_data), sd = sd(col_data))
  }

  # 3. Fit final model on scaled data to get coefficients
  scaled_dat <- dat
  for (v in vars) {
    m <- scaling[[v]]$mean
    s <- scaling[[v]]$sd
    if (!is.null(s) && s > 0) {
      scaled_dat[[v]] <- (scaled_dat[[v]] - m) / s
    }
  }

  opt_threshold <- NULL

  if (analysis_type == "binary") {
    f <- as.formula(paste0('Outcome ~ ', safe_formula_str(vars)))
    model_data <- scaled_dat[complete.cases(scaled_dat[, c('Outcome', vars)]), c('Outcome', vars)]

    if (nrow(model_data) < 4) {
      cat("STEPWISE_LOG:Warning - Insufficient data to save model artifact\n", file = stderr())
      return(NULL)
    }

    model <- glm(f, data = model_data, family = "binomial")
    coefs <- as.list(coef(model))

    # Optimal threshold via pROC
    tryCatch({
      pred_prob <- predict(model, model_data, type = "response")
      roc_obj <- pROC::roc(model_data$Outcome, pred_prob, quiet = TRUE)
      opt_threshold <- pROC::coords(roc_obj, "best", ret = "threshold", transpose = FALSE)$threshold
    }, error = function(e) {
      cat(paste("STEPWISE_LOG:Warning - Could not compute optimal threshold:", e$message, "\n"), file = stderr())
      opt_threshold <<- 0.5
    })

    bin_config <- config$binary
    training_config <- list(
      data_file = basename(ifelse(is.null(bin_config$data_file), "", bin_config$data_file)),
      sample_count = nrow(dat),
      variable_count = ncol(dat) - 2,
      split_prop = SplitProp,
      num_seed = numSeed,
      outcome = ifelse(is.null(bin_config$outcome), "Outcome", bin_config$outcome)
    )
  } else {
    f <- as.formula(paste0('Surv(Survtime,Event) ~ ', paste(vars, collapse = " + ")))
    model_data <- scaled_dat[complete.cases(scaled_dat[, c('Survtime', 'Event', vars)]),
                              c('Survtime', 'Event', vars)]

    if (nrow(model_data) < 4) {
      cat("STEPWISE_LOG:Warning - Insufficient data to save model artifact\n", file = stderr())
      return(NULL)
    }

    model <- survival::coxph(f, data = model_data)
    coefs <- as.list(coef(model))

    surv_config <- config$survival
    training_config <- list(
      data_file = basename(ifelse(is.null(surv_config$data_file), "", surv_config$data_file)),
      sample_count = nrow(dat),
      variable_count = ncol(dat) - 3,
      split_prop = SplitProp,
      num_seed = numSeed,
      event = ifelse(is.null(surv_config$event), "Event", surv_config$event),
      horizon = ifelse(is.null(surv_config$horizon), 5, surv_config$horizon)
    )
  }

  # 4. Build artifact (includes full config for restore on load)
  artifact <- list(
    version = "0.4.0",
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    analysis_type = analysis_type,
    model = list(
      formula = as.character(Result[1,1]),
      variables = vars,
      coefficients = coefs,
      optimal_threshold = opt_threshold
    ),
    scaling = scaling,
    performance = list(
      train_auc = as.numeric(Result[1,2]),
      test_auc = as.numeric(Result[1,3])
    ),
    training_config = training_config,
    config = config
  )

  # 5. Write JSON
  model_path <- file.path(output_dir, "model.bmpmodel")
  write(toJSON(artifact, auto_unbox = TRUE, pretty = TRUE, digits = 8), model_path)
  cat(paste("STEPWISE_LOG:Model artifact saved:", model_path, "\n"), file = stderr())

  return(model_path)
}
