# Reports consume recorded assessment outputs. No fitting function is called here.
bmp_html_escape <- function(value) {
  value <- as.character(value); value[is.na(value)] <- "Unavailable"
  value <- gsub("&", "&amp;", value, fixed = TRUE)
  value <- gsub("<", "&lt;", value, fixed = TRUE); value <- gsub(">", "&gt;", value, fixed = TRUE)
  value <- gsub('"', "&quot;", value, fixed = TRUE); gsub("'", "&#39;", value, fixed = TRUE)
}
bmp_report_json <- function(value) as.character(jsonlite::toJSON(bmp_json_arrays(value), auto_unbox = TRUE, pretty = TRUE, null = "null", na = "null", digits = 8, dataframe = "rows"))
bmp_report_number <- function(value) if (is.null(value) || !length(value) || !is.finite(as.numeric(value))) "Unavailable" else formatC(as.numeric(value), digits = 5, format = "g")
bmp_report_frame <- function(path) {
  if (!file.exists(path)) return(data.frame())
  utils::read.csv(path, check.names = FALSE, stringsAsFactors = FALSE, na.strings = c("", "NA"), fileEncoding = "UTF-8-BOM")
}
bmp_report_sections <- function(run, metrics, model, qc, drift = NULL) {
  sections <- list()
  add <- function(title, text = character(), table = NULL, appendix = FALSE) sections[[length(sections) + 1L]] <<- list(title = title, text = paste(text, collapse = "\n"), table = table, appendix = appendix)
  counts <- metrics$primary$counts
  external <- identical(run$manifest$operation, "evaluate")
  add("Run identity and interpretation", c(paste("Run ID:", run$id), paste("Analysis:", run$manifest$analysis_type),
    paste("Operation:", if (external) "Frozen-model cohort evaluation" else "Development nested validation"),
    paste("Created:", run$manifest$created_at), metrics$primary$interpretation,
    "This research report is informed by relevant TRIPOD+AI reporting items; it is not a certification or a claim of clinical utility.",
    "The manifest is authoritative: completion requires verification of all required artifacts."))
  add("Cohort and validation", c(paste("Cohort rows:", qc$rows, "; independent patient groups:", qc$groups, "; unique samples:", counts$unique_samples),
    paste("Assessment prediction rows:", counts$prediction_rows, "; repeats:", counts$repeats, "; completed/expected folds:", metrics$primary$coverage$completed_folds, "/", metrics$primary$coverage$expected_folds),
    if (!is.null(counts$events_first_repeat)) paste("Observed event rows in first repeat:", counts$events_first_repeat),
    if (!is.null(counts$positives_first_repeat)) paste("Positive outcome rows in first repeat:", counts$positives_first_repeat),
    if (external) "Validation: independent-cohort scoring of a frozen model; inspect overlap evidence before claiming independence." else
      paste("Validation: nested grouped cross-validation;", run$config$outer_folds, "outer folds,", run$config$inner_folds, "inner folds,", run$config$repeats, "repeats; seed", run$config$seed),
    "All rows/repeats from a patient stay together in resampling. Repeated prediction rows are not independent patient counts."))
  add("Outcome and prediction definitions", c(
    if (model$analysis_type == "binary") c(paste("Outcome column:", model$outcome$column),
      paste("Positive:", model$outcome$positive_class, "=", model$outcome$positive_label), paste("Negative:", model$outcome$negative_class, "=", model$outcome$negative_label)) else
      c(paste("Event column:", model$outcome$event, "(1=event, 0=censored)"), paste("Follow-up:", model$outcome$time_variable, "; horizon:", model$horizon, model$time_unit)),
    paste("Sample ID column:", model$sample_id, "; patient column:", if (is.null(model$group_column)) model$sample_id else model$group_column),
    paste("Frozen final-model threshold:", bmp_report_number(model$threshold), ";", model$threshold_method),
    "Assessment classifications use each row's recorded training-fold threshold. The final threshold applies only to that frozen final model.",
    "Required predictors, learned numeric imputation/scaling, category levels and unknown-category policy are preserved in model.bmpmodel."))
  missing <- unlist(qc$missing_fraction)
  add("Preflight QC and exclusions", c(paste("QC status:", qc$status),
    if (!external) paste("Measured genes:", length(qc$measured_genes), "; eligible genes after declared prior restrictions:", length(qc$eligible_genes)),
    if (length(missing)) paste("Predictor missingness range:", paste(formatC(range(missing), digits = 4, format = "g"), collapse = " to ")),
    paste("Constant/all-missing predictor count:", length(qc$constant_columns), "; high-missing predictor count:", length(qc$high_missing_columns)),
    qc$preprocessing, "No cohort rows are silently discarded. Cohort QC diagnostics do not globally remove genes: training partitions learn their own exclusions.",
    "Full per-column missingness, constant/high-missing names, measured/eligible gene universes and evidence restrictions are in qc.json. Training-partition exclusions and screening are in screening/<partition>.json.",
    paste("QC errors:", if (length(qc$errors)) paste(bmp_strings(qc$errors), collapse = " | ") else "None")))
  add("Methods and interpretation", c(
    if (!external) c("Preprocessing, screening, stability resampling, algorithm/hyperparameter/panel selection and binary thresholds are learned inside training partitions only.",
      "The primary estimate assesses the inner-selected modeling procedure on outer assessment folds. Fixed arms share folds and provide descriptive comparisons; selecting the best outer score introduces optimism.",
      "The final model is refitted on the full development cohort after inner selection. Its training fit is not an independent assessment of that exact model.",
      paste("Screening policy version:", model$recipe$screening_policy$version), model$recipe$screening_policy$pool_rule,
      model$recipe$screening_policy$bootstrap_multiplicity,
      paste("Final fitting partition: eligible gene tests", model$recipe$screening_policy$eligible_test_count, "; bootstrap pool", model$recipe$screening_policy$bootstrap_pool_count,
        "; bootstrap resamples", model$recipe$screening_policy$bootstrap_resamples)) else
      "External data are scored without refitting, feature selection, recalibration or threshold tuning. Identifier/hash overlap diagnostics do not establish independent recruitment.",
    if (model$analysis_type == "binary") bmp_metric_methods()$binary else c(bmp_metric_methods()$survival, bmp_metric_methods()$censoring),
    bmp_metric_methods()$uncertainty,
    "Metric methods are defined once in the appendix and referenced in tables. Missing estimates and confidence intervals retain explicit reasons; zero is never used for unavailable results."))
  scopes <- c(list(primary = metrics$primary), metrics$comparisons)
  method_names <- unique(unlist(lapply(scopes, function(scope) vapply(scope$metrics, function(cell) if (is.null(cell$method)) "Unspecified" else cell$method, character(1))), use.names = FALSE))
  method_ids <- paste0("M", seq_along(method_names))
  for (scope_name in names(scopes)) {
    scope <- scopes[[scope_name]]
    table <- do.call(rbind, lapply(names(scope$metrics), function(metric) {
      cell <- scope$metrics[[metric]]
      reason <- c(cell$reason, if (!is.null(cell$ci_reason)) paste("CI:", cell$ci_reason))
      data.frame(Metric = gsub("_", " ", metric, fixed = TRUE), Estimate = bmp_report_number(cell$estimate),
        `95% CI` = if (is.null(cell$lower) || is.null(cell$upper) || !is.finite(cell$lower) || !is.finite(cell$upper)) "Unavailable" else paste0("[", bmp_report_number(cell$lower), ", ", bmp_report_number(cell$upper), "]"),
        Reason = if (length(reason)) paste(reason, collapse = " ") else "Estimable",
        `Bootstrap n/N (failed)` = paste0(cell$bootstrap_successful, "/", cell$bootstrap_requested, " (", cell$bootstrap_failed, ")"),
        Method = method_ids[match(if (is.null(cell$method)) "Unspecified" else cell$method, method_names)], check.names = FALSE)
    }))
    add(paste("Performance:", scope_name), c(scope$interpretation,
      paste("Patient groups:", scope$counts$patient_groups, "; prediction rows:", scope$counts$prediction_rows, "; completed/expected folds:", scope$coverage$completed_folds, "/", scope$coverage$expected_folds),
      "Confidence intervals: 95% percentile patient-group bootstrap conditional on stored predictions; no retraining. Bootstrap n/N means successful/requested resamples; failed resamples are in parentheses.",
      if (length(scope$warnings)) paste("Warnings:", paste(bmp_strings(scope$warnings), collapse = " | "))), table)
  }
  coefficient <- if (length(model$recipe$design)) do.call(rbind, lapply(model$recipe$design, function(term) data.frame(Predictor = term$predictor,
    Level = if (is.null(term$level)) "numeric" else term$level, Coefficient = bmp_report_number(model$coefficients[[term$column]]), check.names = FALSE))) else NULL
  add("Frozen final model and panel", c(paste("Algorithm:", model$algorithm, "; feature set:", model$feature_set),
    paste("Maximum gene panel:", model$panel_size, "; actual required genes:", model$actual_gene_count),
    paste("Selected genes:", if (length(model$selected_genes)) paste(bmp_strings(model$selected_genes), collapse = ", ") else "None (valid baseline/clinical model)"),
    paste("Clinical covariates:", if (length(model$clinical_columns)) paste(bmp_strings(model$clinical_columns), collapse = ", ") else "None"),
    paste("Intercept:", bmp_report_number(model$intercept)),
    "Clinical covariates are separate from the gene-panel maximum. Coefficients use the recorded scaled/encoded design and are not held-out causal effects. Exact encoders, hyperparameters and survival baseline are in model.bmpmodel."), coefficient)
  stability <- bmp_report_frame(file.path(run$dir, "stability.csv"))
  if (nrow(stability)) {
    selected <- stability[is.finite(stability$selection_frequency) & stability$selection_frequency > 0, , drop = FALSE]
    add("Selection stability and direction", c("Descriptive outer-training-fold stability; not independent biological replication.",
      paste("All", nrow(selected), "positive-frequency gene/arm rows are shown. The", nrow(stability)-nrow(selected), "zero/unavailable rows remain in stability.csv.")),
      selected[, intersect(c("role", "arm_id", "gene", "selection_frequency", "positive_frequency", "negative_frequency", "direction_consistency"), names(selected)), drop = FALSE])
  } else add("Selection stability", "Unavailable for this operation: external evaluation does not refit selection.")
  panel <- bmp_report_frame(file.path(run$dir, "panel_comparison.csv"))
  if (nrow(panel)) add("Panel tradeoff audit", "Fold-specific fixed-arm comparisons are descriptive. Maximum gene counts, actual gene counts and clinical covariates are separate. Complete records are in panel_comparison.csv.",
    panel[, intersect(c("split_id", "role", "arm_id", "panel_size", "actual_gene_count", "clinical_predictor_count", "metric", "value", "reason"), names(panel)), drop = FALSE])
  overlap <- bmp_report_frame(file.path(run$dir, "panel_overlap.csv"))
  if (nrow(overlap)) add("Panel overlap", "Jaccard overlap of selected primary gene panels across outer training fits; complete records in panel_overlap.csv.", overlap)
  if (!is.null(drift)) add("External distribution and overlap audit", c(
    paste("Source model SHA-256:", run$manifest$provenance$model$sha256),
    "Required deployed predictors are compared against frozen training summaries; no distribution adjustment or model modification occurs.",
    paste("Overlap:", bmp_report_json(drift$overlap)), paste("Warnings:", paste(bmp_strings(drift$warnings), collapse = " | ")),
    "Per-predictor missingness/range/standardized-mean/category diagnostics and coverage limits are preserved in drift.json. Identifier hashes are for overlap audit, not anonymization."))
  warnings <- unique(c(bmp_strings(run$manifest$warnings), bmp_strings(run$manifest$errors), bmp_strings(qc$warnings), bmp_strings(model$warnings),
    unlist(lapply(scopes, function(scope) bmp_strings(scope$warnings))), if (!is.null(drift)) bmp_strings(drift$warnings)))
  add("Warnings, failures and limitations", c(if (length(warnings)) paste0("- ", warnings) else "No recorded warnings.",
    if (length(run$manifest$failed_folds)) bmp_report_json(run$manifest$failed_folds),
    "No paired superiority test or clinical-benefit claim is inferred from these results. External transportability, applicable censoring assumptions and outcome ascertainment require independent assessment."))
  curve_reasons <- unique(unlist(lapply(scopes, function(scope) unlist(lapply(scope$curves, function(rows) unlist(lapply(rows, function(row) if (is.list(row)) row$reason else NULL))), use.names = FALSE)), use.names = FALSE))
  curve_reasons <- curve_reasons[!is.na(curve_reasons) & nzchar(curve_reasons)]
  if (length(curve_reasons)) add("Unavailable curve points", curve_reasons)
  add("Metric method definitions", table = data.frame(Method = method_ids, Definition = method_names), appendix = TRUE)
  provenance <- run$manifest$provenance
  add("Provenance and reproducibility", c(paste("Input SHA-256:", provenance$input$sha256), paste("Configuration SHA-256:", provenance$config_sha256),
    paste("Engine SHA-256:", provenance$engine$sha256), paste("Run fingerprint:", run$manifest$fingerprint),
    paste("R runtime:", if (external) provenance$evaluation_engine$r_version else provenance$environment$r_version),
    paste("Model SHA-256:", bmp_sha256(file.path(run$dir, "model.bmpmodel"))),
    "Required artifact SHA-256 hashes, engine file hashes and package versions are retained in manifest.json. Original training provenance is never overwritten by report regeneration.",
    "Detailed QC: qc.json. Complete metrics/curve data: metrics.json and evaluation/*.csv. Screening: screening/*.json. Frozen model: model.bmpmodel.",
    "Reusable SVG/PDF/TIFF figures: figures/index.json. This standalone HTML embeds its SVG figures."), appendix = TRUE)
  add("Detailed provenance appendix", bmp_report_json(provenance), appendix = TRUE)
  sections
}

bmp_plot_message <- function(title, reason) {
  graphics::plot.new(); graphics::title(main = title)
  graphics::text(.5, .5, paste(strwrap(reason, width = 85), collapse = "\n"), cex = .9)
}
bmp_plot_groups <- function(frame, extra = NULL) {
  columns <- intersect(c("repeat_id", "split_id", extra), names(frame))
  if (!length(columns)) return(rep("assessment", nrow(frame)))
  apply(frame[columns], 1L, paste, collapse = " / ")
}
bmp_plot_lines <- function(frame, x, y, title, xlab, ylab, group = NULL, diagonal = FALSE, limits = NULL, type = "l") {
  valid <- is.finite(frame[[x]]) & is.finite(frame[[y]])
  if (!any(valid)) return(bmp_plot_message(title, "Unavailable: no estimable stored curve points. Consult metric reasons and follow-up support in this report."))
  if (is.null(group)) group <- bmp_plot_groups(frame)
  labels <- unique(group[valid])
  graphics::plot(frame[[x]][valid], frame[[y]][valid], type = "n", xlab = xlab, ylab = ylab, main = title, ylim = limits)
  if (diagonal) graphics::abline(0, 1, lty = 3, col = "gray60")
  colors <- grDevices::hcl.colors(max(3L, length(labels)), "Dark 3")
  for (i in seq_along(labels)) { use <- group == labels[i]; graphics::lines(frame[[x]][use], frame[[y]][use], type = type, col = colors[i], lwd = 2, pch = 16) }
  graphics::legend("bottomright", legend = labels, col = colors[seq_along(labels)], lty = 1, cex = min(.75, 5/length(labels)), bty = "n")
}
bmp_report_plots <- function(run, metrics, model) {
  plots <- list()
  add <- function(kind, title, caption, source, draw, reason = NULL) {
    plots[[length(plots)+1L]] <<- list(kind = kind, title = title, caption = caption, role = "primary_assessment", data_source = source,
      status = if (is.null(reason)) "available" else "unavailable", reason = reason, draw = draw)
  }
  load_curve <- function(kind) {
    relative <- metrics$primary$curve_files[[kind]]
    if (is.null(relative)) return(data.frame())
    frame <- bmp_report_frame(file.path(run$dir, relative))
    if (nrow(frame) && "repeat_id" %in% names(frame)) frame <- frame[frame$repeat_id == min(frame$repeat_id), , drop = FALSE]
    frame
  }
  # Figures show the first recorded repeat for readability; tables retain all repeats.
  caption <- "Stored primary assessment predictions, first recorded repeat. Metric tables use the declared aggregation across all repeats; no refitting for figures."
  mapping <- if (model$analysis_type == "binary") list(roc = c("false_positive_rate", "sensitivity", "ROC", "False positive rate", "Sensitivity"),
    pr = c("recall", "precision", "Precision-recall", "Recall", "Precision")) else list(km = c("time", "survival", "Kaplan-Meier by frozen risk group", paste("Time (", model$time_unit, ")", sep = ""), "Survival probability"),
    time_auc = c("horizon", "estimate", "Time-dependent AUC", paste("Horizon (", model$time_unit, ")", sep = ""), "IPCW AUC"))
  mapping$calibration <- c("mean_probability", "observed_fraction", "Assessment calibration", "Mean predicted event probability", "Observed event fraction / KM risk")
  for (kind in names(mapping)) local({
    key <- kind; spec <- mapping[[key]]; frame <- load_curve(key)
    reason <- if (!nrow(frame) || !any(is.finite(frame[[spec[1L]]]) & is.finite(frame[[spec[2L]]]))) "No estimable stored curve points; inspect metric and support reasons." else NULL
    add(key, spec[3L], paste(caption, if (model$analysis_type == "survival") "Each curve/bin belongs to its fitted fold; unsupported horizons/bins are missing." else "Average precision uses step-wise recall integration."), metrics$primary$curve_files[[key]],
      function() if (!is.null(reason)) bmp_plot_message(spec[3L], reason) else bmp_plot_lines(frame, spec[1L], spec[2L], spec[3L], spec[4L], spec[5L],
        group = bmp_plot_groups(frame, if (key == "km") "group" else NULL), diagonal = key %in% c("roc", "calibration"), limits = c(0,1), type = if (key %in% c("km", "pr")) "s" else if (key == "roc") "l" else "b"), reason)
  })
  local({
    frame <- load_curve("dca"); reason <- if (!nrow(frame) || !any(is.finite(frame$model))) "Decision curve unavailable because horizon support is insufficient." else NULL
    add("dca", "Decision-curve analysis", paste(caption, "Net benefit at stated probability thresholds; model, treat-all and treat-none. Survival curves use stored training IPCW weights."), metrics$primary$curve_files$dca,
      function() {
        if (!is.null(reason)) return(bmp_plot_message("Decision-curve analysis", reason))
        frames <- lapply(c("model", "treat_all", "treat_none"), function(key) data.frame(threshold = frame$threshold, value = frame[[key]], line = paste(bmp_plot_groups(frame), key)))
        combined <- do.call(rbind, frames)
        bmp_plot_lines(combined, "threshold", "value", "Decision-curve analysis", "Probability threshold", "Net benefit", group = combined$line)
      }, reason)
  })
  if (model$analysis_type == "binary") local({
    frame <- load_curve("confusion")
    add("confusion", "Classification at frozen row thresholds", caption, metrics$primary$curve_files$confusion,
      function() if (!nrow(frame)) bmp_plot_message("Confusion counts", "No classification counts available.") else graphics::barplot(frame$count,
        names.arg = paste0("Observed ", frame$observed, " / predicted ", frame$predicted), col = "#327a91", las = 2, ylab = "Assessment rows", main = "Frozen-threshold classification"))
  })
  local({
    frame <- bmp_read_predictions(file.path(run$dir, "predictions.csv")); frame <- frame[frame$role %in% c("primary", "external"), , drop = FALSE]
    frame <- frame[frame$repeat_id == min(frame$repeat_id), , drop = FALSE]
    score <- if (model$analysis_type == "binary") frame$probability else 1-frame$survival_probability
    order <- order(score); score <- score[order]; frame <- frame[order, , drop = FALSE]
    add("probability_waterfall", "Assessment probability distribution", paste(caption,
      if (model$analysis_type == "binary") "Orange crosses show each row's frozen threshold; there is no common 0.5 decision line. Colors show observed class." else paste("Event probability at", model$horizon, model$time_unit, "; raw fold-specific Cox scores are not pooled. Colors show observed event status, not horizon status.")), "predictions.csv",
      function() {
        observed <- if (model$analysis_type == "binary") frame$outcome_binary else frame$event
        graphics::plot(seq_along(score), score, pch = 16, col = ifelse(observed == 1, "#176c84", "#999999"), ylim = c(0,1), xlab = "Assessment rows sorted by probability", ylab = "Predicted event probability", main = "Assessment probability distribution")
        if (model$analysis_type == "binary") graphics::points(seq_along(score), frame$threshold, pch = 4, col = "#cf7421", cex = .7)
      })
  })
  local({
    values <- as.numeric(unlist(model$coefficients)); labels <- vapply(model$recipe$design, function(term) paste(c(term$predictor, term$level), collapse = " / "), character(1))
    add("coefficients", "Frozen final model coefficients", "Full-development frozen fit; these coefficients are not held-out effect estimates. Numeric predictors use training scaling; categorical columns use stored reference levels.", "model.bmpmodel",
      function() {
        if (!length(values)) return(bmp_plot_message("Frozen final model coefficients", "Valid intercept/baseline-only model: no fitted predictor coefficients."))
        graphics::par(mar = c(5, min(18, max(8, max(nchar(labels))*.3)), 4, 2))
        graphics::barplot(values, names.arg = labels, horiz = TRUE, las = 1, col = ifelse(values >= 0, "#176c84", "#cf7421"), main = "Frozen final coefficients", xlab = "Coefficient on encoded/scaled design", cex.names = min(1, 18/length(values)))
      })
    plots[[length(plots)]]$role <<- "final_model"
  })
  if (!identical(run$manifest$operation, "evaluate")) {
    local({
      frame <- bmp_report_frame(file.path(run$dir, "stability.csv")); if (nrow(frame)) frame <- frame[frame$role == "primary" & frame$selection_frequency > 0, , drop = FALSE]
      frame <- frame[order(frame$selection_frequency, decreasing = TRUE), , drop = FALSE]
      shown <- head(frame, 30L)
      add("stability", "Outer-fold gene selection stability", paste("Training-fold selection frequency; positive/negative coefficient direction is tabulated in stability.csv. Plot shows at most the first 30 selected genes;", nrow(frame), "selected genes total."), "stability.csv",
        function() if (!nrow(shown)) bmp_plot_message("Selection stability", "No genes selected in the primary outer-fold models; clinical or null models can be valid.") else {
          graphics::par(mar = c(8,4,4,2)); graphics::barplot(shown$selection_frequency, names.arg = shown$gene, las = 2, ylim = c(0,1), col = "#176c84", ylab = "Selection frequency", main = "Outer-fold selection stability", cex.names = .8)
        })
    })
    local({
      frame <- bmp_report_frame(file.path(run$dir, "panel_comparison.csv")); if (nrow(frame)) frame <- frame[frame$role == "fixed_arm" & is.finite(frame$value), , drop = FALSE]
      add("panel_tradeoff", "Gene panel size and assessment performance", "Descriptive fixed-arm, fold-specific scores on common outer folds. Panel size is a maximum gene count; clinical covariates are separate. This plot does not select a new model.", "panel_comparison.csv",
        function() if (!nrow(frame)) bmp_plot_message("Panel tradeoff", "No successful fixed-arm scores.") else {
          groups <- paste(frame$algorithm, frame$feature_set); labels <- unique(groups); colors <- grDevices::hcl.colors(max(3L,length(labels)), "Dark 3")
          graphics::plot(frame$actual_gene_count, frame$value, pch = 16, col = colors[match(groups, labels)], xlab = "Actual required gene count", ylab = if (model$analysis_type == "binary") "Outer-fold ROC AUC" else "Outer-fold Harrell C", ylim = c(0,1), main = "Panel tradeoff (descriptive)")
          graphics::legend("bottomright", labels, col = colors[seq_along(labels)], pch = 16, cex = .8, bty = "n")
        })
    })
  }
  plots
}

bmp_report_draw <- function(plot) {
  graphics::par(mar = c(5,5,4,2), family = "sans")
  plot$draw()
}
bmp_report_pdf <- function(path, run_id, sections, plots) {
  if (!isTRUE(capabilities("cairo"))) stop("Searchable Unicode reports require an R build with Cairo support.", call. = FALSE)
  grDevices::cairo_pdf(path, width = 8.27, height = 11.69, family = "sans", onefile = TRUE)
  on.exit(grDevices::dev.off(), add = TRUE)
  page <- 0L; y <- 0
  new_page <- function() {
    page <<- page + 1L; graphics::par(mar = c(0,0,0,0)); graphics::plot.new(); graphics::plot.window(xlim = c(0,1), ylim = c(0,1))
    graphics::text(.05,.97, "BioMarkerPred research report", adj = c(0,1), cex = 1.1, font = 2)
    graphics::text(.05,.945, paste("Run ID:", run_id), adj = c(0,1), cex = .76)
    graphics::text(.95,.025, paste("Page", page), adj = 1, cex = .7); y <<- .90
  }
  new_page()
  for (section in sections) {
    if (y < .15) new_page()
    graphics::text(.05,y, section$title, adj = c(0,1), font = 2, cex = .94); y <- y-.028
    lines <- unlist(lapply(strsplit(section$text, "\n", fixed = TRUE)[[1]], function(line) {
      if (!nzchar(line)) return("")
      # Long hashes/paths must wrap too; strwrap alone leaves unbroken strings intact.
      chunks <- strwrap(line, width = 104)
      unlist(lapply(chunks, function(chunk) if (nchar(chunk) <= 108) chunk else substring(chunk, seq(1, nchar(chunk), 108), pmin(nchar(chunk), seq(1,nchar(chunk),108)+107))), use.names = FALSE)
    }), use.names = FALSE)
    for (line in lines) {
      if (y < .065) new_page()
      graphics::text(.05,y, line, adj = c(0,1), cex = .74); y <- y-.016
    }
    table <- section$table
    if (is.data.frame(table) && nrow(table)) {
      values <- lapply(table, function(column) { value <- as.character(column); value[is.na(value)] <- "Unavailable"; value })
      widths <- pmax(8, pmin(30, vapply(seq_along(values), function(i) max(nchar(names(table)[i]), stats::median(nchar(values[[i]]))), numeric(1))))
      if (identical(names(table), c("Metric", "Estimate", "95% CI", "Reason", "Bootstrap n/N (failed)", "Method"))) widths <- c(20, 13, 20, 29, 16, 8)
      widths <- widths/sum(widths); positions <- .05 + c(0, cumsum(widths)*.90)
      wrap_cell <- function(value, width) {
        pieces <- strwrap(value, width = max(7, floor(width*115)))
        if (!length(pieces)) pieces <- ""
        unlist(lapply(pieces, function(piece) if (nchar(piece) <= max(7, floor(width*115))) piece else {
          size <- max(7, floor(width*115)); substring(piece, seq(1,nchar(piece),size), pmin(nchar(piece),seq(1,nchar(piece),size)+size-1))
        }), use.names = FALSE)
      }
      draw_row <- function(row, header = FALSE) {
        cells <- lapply(seq_along(row), function(j) wrap_cell(row[j], widths[j])); height <- max(lengths(cells))*.014+.012
        if (y-height < .06) new_page()
        for (j in seq_along(cells)) {
          graphics::rect(positions[j], y-height, positions[j+1], y, col = if (header) "#e0edf1" else "white", border = "#cbd7dc")
          for (k in seq_along(cells[[j]])) graphics::text(positions[j]+.004, y-.006-(k-1)*.014, cells[[j]][k], adj = c(0,1), cex = .64, font = if (header) 2 else 1)
        }
        y <<- y-height
      }
      draw_row(names(table), TRUE)
      for (i in seq_len(nrow(table))) {
        if (y < .13) { new_page(); draw_row(names(table), TRUE) }
        draw_row(vapply(values, `[`, character(1), i))
      }
    }
    y <- y-.022
  }
  for (plot in plots) {
    bmp_report_draw(plot)
    graphics::mtext(paste("Run ID:", run_id), side = 1, line = 3.5, cex = .65)
  }
  invisible(path)
}
bmp_report_install_file <- function(from, to) file.rename(from, to)
bmp_report_commit <- function(staging, run, generated, finalize) {
  backup <- file.path(staging, "backup"); dir.create(backup)
  originals <- c(stats::setNames(file.path(run$dir, generated), generated),
    manifest = file.path(run$dir, "manifest.json"), latest = file.path(run$root_output_dir, "latest.json"))
  existed <- file.exists(originals); backup_paths <- file.path(backup, as.character(seq_along(originals)))
  for (i in which(existed)) if (!file.copy(originals[i], backup_paths[i], overwrite = FALSE)) stop("Cannot back up report targets before replacement; existing run is unchanged.", call. = FALSE)
  changed <- integer(); finished <- FALSE
  on.exit({
    if (!finished && length(changed)) {
      # Include metadata because finalization may have written it before failing.
      restore <- unique(c(changed, length(originals)-1L, length(originals)))
      restored <- vapply(restore, function(i) {
        if (existed[i]) file.copy(backup_paths[i], originals[i], overwrite = TRUE) else { unlink(originals[i]); !file.exists(originals[i]) }
      }, logical(1))
      if (!all(restored)) {
        manifest <- tryCatch(bmp_read_json(file.path(run$dir, "manifest.json")), error = function(error) run$manifest)
        manifest$status <- "partial"; manifest$errors <- c(bmp_strings(manifest$errors), "Report transaction rollback failed; required derived artifacts must be restored before trusting this run.")
        try(bmp_atomic_json(manifest, file.path(run$dir, "manifest.json")), silent = TRUE)
      }
    }
  }, add = TRUE)
  dir.create(file.path(run$dir, "figures"), showWarnings = FALSE)
  for (i in seq_along(generated)) {
    if (!bmp_report_install_file(file.path(staging, generated[i]), originals[i])) stop(paste("Unable to commit report artifact; previous report transaction restored:", generated[i]), call. = FALSE)
    changed <- c(changed, i)
  }
  result <- finalize(); finished <- TRUE
  result
}
bmp_report_run <- function(run_dir) {
  run <- bmp_run_open(run_dir); bmp_verify_recorded(run)
  model <- bmp_cli_load_model(file.path(run$dir, "model.bmpmodel"))
  metrics <- bmp_read_json(file.path(run$dir, "metrics.json")); qc <- bmp_read_json(file.path(run$dir, "qc.json"))
  if (!identical(metrics$run_id, run$id)) stop("Metrics run identity does not match the manifest.", call. = FALSE)
  # Check all metric and curve bytes before deriving reports. Future calls verify
  # the recorded hashes even when the run was interrupted before completion.
  metric_paths <- unique(c("metrics.json", metrics$files$metrics_table, unlist(metrics$files$curves, use.names = FALSE)))
  metric_verification <- bmp_verify_artifacts(run$dir, metric_paths)
  if (!metric_verification$ok) stop("Metric source artifacts are missing; cannot generate a research report.", call. = FALSE)
  drift <- if (file.exists(file.path(run$dir, "drift.json"))) bmp_read_json(file.path(run$dir, "drift.json")) else NULL
  sections <- bmp_report_sections(run, metrics, model, qc, drift); plots <- bmp_report_plots(run, metrics, model)
  staging <- tempfile(".report-", tmpdir = run$dir); dir.create(staging); dir.create(file.path(staging, "figures"))
  on.exit(unlink(staging, recursive = TRUE), add = TRUE)
  bmp_engine_event("report_start", run_id = run$id, run_dir = run$dir, status = run$manifest$status)
  figures <- list()
  for (i in seq_along(plots)) {
    plot <- plots[[i]]; files <- list()
    for (format in c("svg", "pdf", if (isTRUE(capabilities("tiff"))) "tiff")) {
      relative <- file.path("figures", paste0(plot$kind, ".", format)); target <- file.path(staging, relative)
      if (format == "svg") grDevices::svg(target, width = 9, height = 6, family = "sans")
      else if (format == "pdf") grDevices::cairo_pdf(target, width = 9, height = 6, family = "sans")
      else grDevices::tiff(target, width = 9, height = 6, units = "in", res = 150, compression = "lzw", type = "cairo")
      tryCatch(bmp_report_draw(plot), finally = grDevices::dev.off())
      files[[format]] <- relative
    }
    figures[[i]] <- c(plot[setdiff(names(plot), "draw")], list(id = plot$kind, files = files))
  }
  bmp_atomic_json(list(schema_version = 1L, run_id = run$id, source = "Recorded assessment curves, predictions and model artifacts; no fitting", figures = figures), file.path(staging, "figures", "index.json"))
  figure_sections <- lapply(figures, function(figure) list(title = paste("Figure:", figure$title), text = paste(c(figure$caption, if (!is.null(figure$reason)) paste("Unavailable:", figure$reason)), collapse = "\n")))
  sections <- c(sections, figure_sections)
  bmp_report_pdf(file.path(staging, "report.pdf"), run$id, sections, plots)
  html <- c('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">',
    paste0("<title>BioMarkerPred ", bmp_html_escape(run$id), "</title>"),
    '<style>body{font:16px/1.55 system-ui,sans-serif;max-width:1120px;margin:2rem auto;padding:0 1.4rem;color:#183142}h1,h2{color:#14566b}section,details{margin:2rem 0}p{overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:13px/1.5 ui-monospace,monospace;background:#f1f6f7;padding:1rem}table{border-collapse:collapse;width:100%;font-size:13px}td,th{border:1px solid #ccd8dc;padding:.5rem;text-align:left;overflow-wrap:anywhere}th{background:#e0edf1}summary{font-weight:700;cursor:pointer}img{max-width:100%;height:auto}figure{margin:2rem 0;border-top:1px solid #ccd8dc}figcaption{padding:.7rem 0}@media print{section,figure{break-inside:auto}}</style></head><body>',
    paste0("<h1>BioMarkerPred research report</h1><p>Run ID: ", bmp_html_escape(run$id), "</p>"))
  for (section in sections) {
    appendix <- isTRUE(section$appendix)
    html <- c(html, if (appendix) paste0("<details><summary>", bmp_html_escape(section$title), "</summary>") else paste0("<section><h2>", bmp_html_escape(section$title), "</h2>"))
    if (identical(section$title, "Detailed provenance appendix")) html <- c(html, paste0("<pre>", bmp_html_escape(section$text), "</pre>"))
    else html <- c(html, paste0("<p>", bmp_html_escape(strsplit(section$text, "\n", fixed = TRUE)[[1]]), "</p>"))
    if (is.data.frame(section$table) && nrow(section$table)) {
      html <- c(html, paste0("<table><thead><tr>", paste0("<th>", bmp_html_escape(names(section$table)), "</th>", collapse = ""), "</tr></thead><tbody>"))
      for (i in seq_len(nrow(section$table))) html <- c(html, paste0("<tr>", paste0("<td>", bmp_html_escape(as.character(section$table[i, ])), "</td>", collapse = ""), "</tr>"))
      html <- c(html, "</tbody></table>")
    }
    html <- c(html, if (appendix) "</details>" else "</section>")
  }
  for (figure in figures) {
    svg <- readBin(file.path(staging, figure$files$svg), "raw", n = file.info(file.path(staging, figure$files$svg))$size)
    html <- c(html, paste0('<figure><img alt="', bmp_html_escape(figure$title), '" src="data:image/svg+xml;base64,', jsonlite::base64_enc(svg), '"><figcaption>', bmp_html_escape(figure$caption), "</figcaption></figure>"))
  }
  html <- c(html, "</body></html>"); writeLines(enc2utf8(html), file.path(staging, "report.html"), useBytes = TRUE)
  generated <- c("report.html", "report.pdf", "figures/index.json", unlist(lapply(figures, function(figure) figure$files), use.names = FALSE))
  verification <- bmp_verify_artifacts(staging, generated)
  if (!verification$ok) stop("Required report export failed verification.", call. = FALSE)
  # Only commit derived files after every export succeeded. Model, predictions,
  # splits, input and screening audits are never rewritten by this operation.
  report_provenance <- list(generated_at = bmp_now(), r_version = R.version.string, modules = stats::setNames(lapply(file.path(bmp_repo_root, "R", c("reports.R", "cli.R")), bmp_sha256), c("R/reports.R", "R/cli.R")),
    source_sha256 = metric_verification$sha256, graphics = as.list(capabilities(c("cairo", "tiff"))))
  # Preserve failure/partial/cancelled states; only the analysis/evaluation
  # orchestrator can finalize a successful unfinished run.
  run <- bmp_report_commit(staging, run, generated, function() bmp_update_manifest(run, run$manifest$status,
    required_artifacts = unique(c(bmp_strings(run$manifest$required_artifacts), metric_paths, generated)), report_status = "completed",
    report_provenance = report_provenance, metrics_artifact_verification = metric_verification,
    report_artifact_verification = bmp_verify_artifacts(run$dir, generated)))
  bmp_engine_event("report_ready", run_id = run$id, run_dir = run$dir, status = run$manifest$status, paths = list(html = file.path(run$dir, "report.html"), pdf = file.path(run$dir, "report.pdf")))
  invisible(list(run = run, figures = figures, paths = list(html = file.path(run$dir, "report.html"), pdf = file.path(run$dir, "report.pdf"))))
}
