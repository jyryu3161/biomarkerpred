# bmp_read_csv(path) preserves exact column names and all string representations
# (especially sample IDs with leading zeroes). Validation converts numeric roles.
bmp_read_csv <- function(path) {
  if (!file.exists(path)) stop(sprintf("Input file does not exist: %s", path), call. = FALSE)
  tryCatch(withCallingHandlers({
    counts <- utils::count.fields(path, sep = ",", quote = "\"", comment.char = "", blank.lines.skip = TRUE)
    # Embedded newlines inside quoted fields produce NA for intermediate lines.
    complete <- counts[!is.na(counts)]
    if (!length(complete) || any(complete != complete[1L])) stop("Rows have inconsistent field counts; check CSV quoting and delimiters.")
    utils::read.csv(path, header = TRUE, check.names = FALSE,
      stringsAsFactors = FALSE, colClasses = "character", row.names = NULL,
      na.strings = c("", "NA", "NaN"), strip.white = TRUE, fill = FALSE,
      comment.char = "", fileEncoding = "UTF-8-BOM")
  }, warning = function(warning) {
    # Missing final newline is harmless; malformed quoting is not.
    if (grepl("incomplete final line", conditionMessage(warning), fixed = TRUE)) invokeRestart("muffleWarning")
    else stop(conditionMessage(warning), call. = FALSE)
  }), error = function(error) {
      stop(sprintf("Cannot parse CSV '%s': %s", path, conditionMessage(error)), call. = FALSE)
    })
}

bmp_qc_error <- function(errors, qc) {
  qc$status <- "failed"
  qc$errors <- unique(errors)
  stop(structure(list(message = paste(c("Data validation failed:", paste0("- ", qc$errors)), collapse = "\n"),
                      call = NULL, qc = qc), class = c("bmp_validation_error", "error", "condition")))
}

# bmp_validate_data(config, data=NULL) -> list(config, data, qc).
# The returned data keeps its original row order/column names and has numeric
# genes, times and events; ID/group columns are character. No imputation,
# learned feature exclusion or outcome-dependent selection is performed here.
# Missing/constant diagnostics describe the cohort, while engine preprocessing
# must learn all such decisions independently within each training partition.
bmp_validate_data <- function(config, data = NULL) {
  config <- bmp_load_config(config)
  if (is.null(data)) data <- bmp_read_csv(config$data_file)
  if (!is.data.frame(data)) stop("data must be a data.frame.", call. = FALSE)
  qc <- list(schema_version = 1L, status = "passed", analysis_type = config$analysis_type,
    rows = nrow(data), columns = ncol(data), errors = character(),
    warnings = config$normalization_warnings,
    preprocessing = "Diagnostics only; missingness/constant filtering and imputation are learned inside training folds.")
  errors <- character()
  if (!nrow(data)) errors <- c(errors, "The dataset has no rows.")
  if (anyDuplicated(names(data))) errors <- c(errors, "CSV column names must be unique.")
  if (anyNA(names(data)) || any(!nzchar(names(data)))) errors <- c(errors, "CSV column names cannot be empty.")
  outcome_roles <- if (config$analysis_type == "binary") config$outcome else c(config$time_variable, config$event)
  if (length(outcome_roles) != if (config$analysis_type == "binary") 1L else 2L) errors <- c(errors, "Required outcome/time/event column roles are missing.")
  primary_roles <- c(config$sample_id, outcome_roles)
  if (anyDuplicated(primary_roles)) errors <- c(errors, "Sample ID, outcome, time and event roles must name different columns.")
  if (length(intersect(config$clinical_columns, c(primary_roles, config$group_column)))) errors <- c(errors, "Clinical columns cannot also be identifiers or outcomes.")
  if (!is.null(config$group_column) && config$group_column %in% outcome_roles) errors <- c(errors, "group_column cannot be an outcome, event or time column.")
  required <- unique(c(primary_roles, config$group_column, config$clinical_columns, config$features, config$include, config$exclude))
  absent <- setdiff(required, names(data))
  if (length(absent)) errors <- c(errors, paste("Columns not found:", paste(absent, collapse = ", ")))
  if (length(errors)) bmp_qc_error(errors, qc)
  for (column in unique(c(config$sample_id, config$group_column))) {
    data[[column]] <- as.character(data[[column]])
    if (anyNA(data[[column]]) || any(!nzchar(trimws(data[[column]])))) errors <- c(errors, sprintf("Identifier column '%s' has missing/blank values.", column))
  }
  duplicated_ids <- unique(data[[config$sample_id]][duplicated(data[[config$sample_id]])])
  qc$duplicate_sample_ids <- duplicated_ids
  if (length(duplicated_ids) && !identical(config$group_column, config$sample_id)) errors <- c(errors, "Duplicate sample IDs found. Use unique sample IDs and a patient group_column, or explicitly use sample_id as group_column for repeated measures.")
  if (length(duplicated_ids) && identical(config$group_column, config$sample_id)) qc$warnings <- c(qc$warnings, "Repeated sample IDs explicitly grouped by sample_id; each group must remain entirely within one fold.")
  group <- if (is.null(config$group_column)) data[[config$sample_id]] else data[[config$group_column]]
  qc$groups <- length(unique(group))
  qc$repeated_groups <- sum(table(group) > 1)
  qc$largest_group <- if (length(group)) max(table(group)) else 0L
  role_columns <- unique(c(primary_roles, config$group_column, config$clinical_columns))
  if (length(intersect(config$include, c(role_columns, config$exclude)))) errors <- c(errors, "Forced include genes cannot be outcome/identifier/clinical/excluded columns.")
  genes <- if (length(config$features)) config$features else setdiff(names(data), role_columns)
  if (length(intersect(genes, role_columns))) errors <- c(errors, "features must contain gene columns only, not outcome/identifier/clinical columns.")
  genes <- setdiff(unique(c(genes, config$include)), config$exclude)
  # Evidence filtering is a fixed external-prior restriction, independent of
  # cohort outcome values; preserve both measured and eligible universes.
  qc$measured_genes <- genes
  if (!is.null(config$evidence)) {
    evidence <- bmp_read_csv(config$evidence$gene_file)
    identifiers <- intersect(c("gene_symbol", "ensembl_id"), names(evidence))
    if (!"score" %in% names(evidence) || !length(identifiers)) errors <- c(errors, "Evidence CSV requires score and gene_symbol and/or ensembl_id columns.")
    else {
      scores <- suppressWarnings(as.numeric(evidence$score))
      if (any(!is.finite(scores)) || any(scores < 0 | scores > 1)) errors <- c(errors, "Evidence scores must be finite numbers between 0 and 1.")
      else {
        passed <- scores >= config$evidence$score_threshold
        values <- lapply(identifiers, function(column) {
          value <- evidence[[column]][passed]
          unique(value[!is.na(value) & nzchar(value)])
        })
        names(values) <- identifiers
        eligible <- unique(unlist(values, use.names = FALSE))
        matched <- lapply(values, function(value) intersect(genes, value))
        genes <- intersect(genes, eligible)
        if (length(setdiff(config$include, genes))) errors <- c(errors, "Forced include genes do not pass the configured evidence filter.")
        qc$evidence <- list(source = config$evidence$source, gene_file = config$evidence$gene_file,
          score_threshold = config$evidence$score_threshold, evidence_rows = nrow(evidence),
          eligible_evidence_rows = sum(passed), eligible_evidence_identifiers = length(eligible),
          matched_gene_symbols = length(matched$gene_symbol), matched_ensembl_ids = length(matched$ensembl_id),
          matched_genes = length(genes), unmatched_measured_genes = length(setdiff(qc$measured_genes, genes)),
          matching_policy = "Exact gene_symbol or ensembl_id equality; no case conversion, version stripping or inferred aliases. Counts refer to unique assay columns; a column matching both identifiers is counted once in matched_genes.")
      }
    }
  }
  if (any(config$feature_sets %in% c("genes", "combined")) && !length(genes)) errors <- c(errors, "No gene columns remain. Check features, column roles, exclusions and evidence settings.")
  nonnumeric <- character()
  for (column in genes) {
    original <- data[[column]]
    if (is.factor(original)) original <- as.character(original)
    parsed <- suppressWarnings(as.numeric(original))
    if (any(!is.na(original) & (!is.finite(parsed)))) nonnumeric <- c(nonnumeric, column)
    data[[column]] <- parsed
  }
  if (length(nonnumeric)) errors <- c(errors, paste("Gene columns must be numeric and finite (missing is allowed):", paste(nonnumeric, collapse = ", ")))
  clinical_types <- list()
  for (column in config$clinical_columns) {
    original <- as.character(data[[column]])
    parsed <- suppressWarnings(as.numeric(original))
    numeric <- all(is.na(original) | is.finite(parsed)) && any(!is.na(original))
    data[[column]] <- if (numeric) parsed else original
    clinical_types[[column]] <- if (numeric) "numeric" else "categorical"
    if (!numeric && length(unique(original[!is.na(original)])) > max(20, nrow(data) / 2)) qc$warnings <- c(qc$warnings, sprintf("Clinical column '%s' has many categories; verify it is not an identifier.", column))
  }
  qc$clinical_types <- clinical_types
  predictor_columns <- unique(c(genes, config$clinical_columns))
  qc$missing_fraction <- as.list(vapply(data[predictor_columns], function(x) mean(is.na(x)), numeric(1)))
  qc$constant_columns <- predictor_columns[vapply(data[predictor_columns], function(x) length(unique(x[!is.na(x)])) <= 1L, logical(1))]
  qc$high_missing_columns <- names(qc$missing_fraction)[unlist(qc$missing_fraction) > config$missing_threshold]
  if (length(qc$constant_columns)) qc$warnings <- c(qc$warnings, paste("Cohort-level constant/all-missing predictors (training folds will decide exclusions):", paste(qc$constant_columns, collapse = ", ")))
  if (length(qc$high_missing_columns)) qc$warnings <- c(qc$warnings, paste("Predictors exceed missing_threshold in this cohort (training folds will decide exclusions):", paste(qc$high_missing_columns, collapse = ", ")))
  if (config$analysis_type == "binary") {
    outcome <- as.character(data[[config$outcome]])
    data[[config$outcome]] <- outcome
    if (anyNA(outcome) || any(!outcome %in% c(config$negative_class, config$positive_class))) errors <- c(errors, sprintf("Outcome '%s' must have non-missing values matching negative_class='%s' and positive_class='%s'.", config$outcome, config$negative_class, config$positive_class))
    mixed <- tapply(outcome, group, function(values) length(unique(values)))
    if (any(mixed > 1L)) errors <- c(errors, "A patient group has conflicting binary outcomes. Reconcile outcomes before grouped validation.")
    qc$class_counts <- as.list(table(factor(outcome, levels = c(config$negative_class, config$positive_class))))
    group_counts <- vapply(c(config$negative_class, config$positive_class), function(value) length(unique(group[!is.na(outcome) & outcome == value])), integer(1))
    names(group_counts) <- c(config$negative_class, config$positive_class)
    qc$class_group_counts <- as.list(group_counts)
    if (min(unlist(qc$class_counts)) / nrow(data) < 0.1) qc$warnings <- c(qc$warnings, "The minority class is below 10%; use precision-recall metrics and report uncertainty.")
    if (any(group_counts < config$outer_folds) || any(group_counts - ceiling(group_counts / config$outer_folds) < config$inner_folds)) errors <- c(errors, sprintf("Insufficient independent patient groups per class for %s outer and %s inner folds. Lower fold counts or add samples; at least one group per class must remain in every assessment fold.", config$outer_folds, config$inner_folds))
  } else {
    time <- suppressWarnings(as.numeric(as.character(data[[config$time_variable]])))
    event <- suppressWarnings(as.numeric(as.character(data[[config$event]])))
    data[[config$time_variable]] <- time
    data[[config$event]] <- event
    if (any(!is.finite(time) | time <= 0)) errors <- c(errors, "Survival times must be finite positive numbers in the configured time_unit.")
    if (anyNA(event) || any(!event %in% c(0, 1))) errors <- c(errors, "Survival event must use 0=censored and 1=event without missing values.")
    event_groups <- length(unique(group[!is.na(event) & event == 1]))
    qc$events <- sum(event == 1, na.rm = TRUE)
    qc$censored <- sum(event == 0, na.rm = TRUE)
    qc$event_groups <- event_groups
    qc$time_unit <- config$time_unit
    qc$horizon <- config$horizon
    qc$time_range <- if (any(is.finite(time))) range(time[is.finite(time)]) else NULL
    if (event_groups < config$outer_folds || event_groups - ceiling(event_groups / config$outer_folds) < config$inner_folds) errors <- c(errors, sprintf("Insufficient event-bearing patient groups for %s outer and %s inner folds. Lower fold counts or add observed events.", config$outer_folds, config$inner_folds))
    if (!is.null(qc$time_range) && config$horizon >= max(qc$time_range)) qc$warnings <- c(qc$warnings, "horizon is at or beyond maximum follow-up; time-dependent metrics may be unavailable. Do not tune horizon on external outcomes.")
    if (!any(event == 1 & time <= config$horizon, na.rm = TRUE)) qc$warnings <- c(qc$warnings, "No observed events occur before horizon; horizon-specific discrimination may be unavailable.")
  }
  config$gene_columns <- genes
  config$clinical_types <- clinical_types
  qc$eligible_genes <- genes
  qc$gene_count <- length(genes)
  qc$clinical_count <- length(config$clinical_columns)
  qc$validation <- list(method = "nested_grouped_cross_validation", outer_folds = config$outer_folds,
    inner_folds = config$inner_folds, repeats = config$repeats, group_column = config$group_column,
    split_feasibility = "Count-based preflight; engine additionally verifies every realized partition.")
  qc$warnings <- unique(qc$warnings)
  if (length(errors)) bmp_qc_error(errors, qc)
  list(config = config, data = data, qc = qc)
}
