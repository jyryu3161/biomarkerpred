# Predict_New.R
# Applies a saved .bmpmodel to new patient data and outputs prediction results.
# Usage: Rscript Predict_New.R --model=<path> --data=<path> --output=<dir>

library(jsonlite)

# 1. Parse CLI args
args <- commandArgs(trailingOnly = TRUE)
model_file <- sub("^--model=", "", grep("^--model=", args, value = TRUE))
data_file  <- sub("^--data=",  "", grep("^--data=",  args, value = TRUE))
output_dir <- sub("^--output=", "", grep("^--output=", args, value = TRUE))

if (length(model_file) == 0 || length(data_file) == 0 || length(output_dir) == 0) {
  stop("Usage: Rscript Predict_New.R --model=<path> --data=<path> --output=<dir>")
}

# 2. Load model
if (!file.exists(model_file)) {
  stop(paste("Model file not found:", model_file))
}
model_json <- fromJSON(model_file, simplifyVector = TRUE)
analysis_type   <- model_json$analysis_type
variables       <- model_json$model$variables
coefficients    <- model_json$model$coefficients
scaling         <- model_json$scaling
opt_threshold   <- model_json$model$optimal_threshold

cat(paste0("PREDICTION_LOG:Model loaded - ", analysis_type, " model with ",
    length(variables), " variables\n"), file = stderr())
cat(paste0("PREDICTION_LOG:Variables: ", paste(variables, collapse = ", "), "\n"), file = stderr())

# 3. Load new data
if (!file.exists(data_file)) {
  stop(paste("Data file not found:", data_file))
}
new_data <- read.csv(data_file, header = TRUE, stringsAsFactors = FALSE)
cat(paste0("PREDICTION_LOG:Data loaded - ", nrow(new_data), " samples, ",
    ncol(new_data), " columns\n"), file = stderr())

# 4. Validate required columns exist
missing_vars <- setdiff(variables, colnames(new_data))
if (length(missing_vars) > 0) {
  msg <- paste("Missing required variables:", paste(missing_vars, collapse = ", "))
  cat(paste0("PREDICTION_LOG:ERROR - ", msg, "\n"), file = stderr())
  stop(msg)
}

# 5. Scale variables using saved parameters
scaled_data <- new_data
for (v in variables) {
  m <- scaling[[v]]$mean
  s <- scaling[[v]]$sd
  if (is.null(m) || is.null(s) || s == 0) {
    cat(paste0("PREDICTION_LOG:WARNING - Invalid scaling for ", v,
        ", using raw values\n"), file = stderr())
    next
  }
  scaled_data[[v]] <- (new_data[[v]] - m) / s
}

# 6. Compute predictions using coefficients directly
if (analysis_type == "binary") {
  # Logistic regression: linear predictor + sigmoid
  intercept <- coefficients[["(Intercept)"]]
  if (is.null(intercept)) intercept <- 0

  lp <- rep(intercept, nrow(scaled_data))
  for (v in variables) {
    coef_val <- coefficients[[v]]
    if (!is.null(coef_val)) {
      lp <- lp + coef_val * scaled_data[[v]]
    }
  }
  probability <- 1 / (1 + exp(-lp))

  # Use optimal threshold, default to 0.5
  threshold <- ifelse(is.null(opt_threshold) || is.na(opt_threshold), 0.5, opt_threshold)
  predicted_class <- ifelse(probability >= threshold, 1, 0)

  results <- data.frame(
    row_index = seq_len(nrow(new_data)),
    risk_probability = round(probability, 6),
    predicted_class = predicted_class,
    risk_group = ifelse(predicted_class == 1, "High", "Low"),
    stringsAsFactors = FALSE
  )

  cat(paste0("PREDICTION_LOG:Threshold used: ", round(threshold, 4), "\n"), file = stderr())

} else {
  # CoxPH: linear predictor (no intercept)
  lp <- rep(0, nrow(scaled_data))
  for (v in variables) {
    coef_val <- coefficients[[v]]
    if (!is.null(coef_val)) {
      lp <- lp + coef_val * scaled_data[[v]]
    }
  }
  risk_score <- exp(lp)
  median_risk <- median(risk_score, na.rm = TRUE)

  results <- data.frame(
    row_index = seq_len(nrow(new_data)),
    risk_score = round(risk_score, 6),
    linear_predictor = round(lp, 6),
    risk_group = ifelse(risk_score >= median_risk, "High", "Low"),
    stringsAsFactors = FALSE
  )

  cat(paste0("PREDICTION_LOG:Median risk score: ", round(median_risk, 4), "\n"), file = stderr())
}

# 7. Attach sample ID (use first column as identifier)
if (ncol(new_data) > 0) {
  results$sample_id <- new_data[[1]]
  results <- results[, c("sample_id", setdiff(names(results), "sample_id"))]
}

# 8. Report NA predictions
if (analysis_type == "binary") {
  na_count <- sum(is.na(results$risk_probability))
} else {
  na_count <- sum(is.na(results$risk_score))
}
if (na_count > 0) {
  cat(paste0("PREDICTION_LOG:WARNING - ", na_count,
      " samples have NA predictions (missing values in input)\n"), file = stderr())
}

# Summary
high_count <- sum(results$risk_group == "High", na.rm = TRUE)
low_count  <- sum(results$risk_group == "Low", na.rm = TRUE)
cat(paste0("PREDICTION_LOG:Summary - ", high_count, " High / ", low_count, " Low\n"), file = stderr())

# 9. Write output
dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
output_path <- file.path(output_dir, "prediction_results.csv")
write.csv(results, output_path, row.names = FALSE)
cat(paste0("PREDICTION_LOG:Results saved - ", nrow(results), " predictions written to ",
    output_path, "\n"), file = stderr())
cat("PREDICTION_LOG:Prediction complete!\n", file = stderr())
