# Public API: bmp_load_config(path_or_list, analysis_type = NULL) -> flat list.
# Paths are relative to workdir (itself relative to invocation directory), or to
# the configuration file directory when workdir is omitted. Lists use getwd().
# Legacy binary/survival YAML sections and flat GUI camelCase inputs normalize
# to the same schema. All feature preprocessing belongs inside training folds.
bmp_require <- function(package) {
  if (!requireNamespace(package, quietly = TRUE)) {
    stop(sprintf("Required R package '%s' is unavailable. Install the project runtime first.", package), call. = FALSE)
  }
}

bmp_snake <- function(name) tolower(gsub("([a-z0-9])([A-Z])", "\\1_\\2", name))

bmp_normalize_names <- function(x) {
  if (!is.list(x)) return(x)
  if (!is.null(names(x))) names(x) <- bmp_snake(names(x))
  lapply(x, bmp_normalize_names)
}

bmp_scalar <- function(x, name, default = NULL) {
  if (is.null(x) || !length(x)) return(default)
  x <- unlist(x, use.names = FALSE)
  if (length(x) != 1L || is.na(x)) stop(sprintf("%s must contain one non-missing value.", name), call. = FALSE)
  x
}

bmp_strings <- function(x) {
  if (is.null(x)) return(character())
  x <- as.character(unlist(x, use.names = FALSE))
  if (anyNA(x)) stop("Column names and option lists cannot contain missing values.", call. = FALSE)
  unique(x[nzchar(x)])
}

bmp_path <- function(path, base) {
  if (is.null(path) || !nzchar(path)) return(NULL)
  path <- path.expand(path)
  if (!grepl("^(/|[A-Za-z]:[/\\\\])", path)) path <- file.path(base, path)
  normalizePath(path, winslash = "/", mustWork = FALSE)
}

# The schema is the single source of defaults for R, CLI and GUI consumers.
bmp_config_defaults <- function(analysis_type = "binary") {
  bmp_require("jsonlite")
  schema <- jsonlite::fromJSON(file.path(bmp_repo_root, "config", "schema.json"), simplifyVector = FALSE)
  properties <- schema[["$defs"]]$analysis$properties
  values <- lapply(properties, function(property) {
    key <- paste0("x-", analysis_type, "-default")
    if (key %in% names(property)) property[[key]] else property$default
  })
  values$analysis_type <- analysis_type
  values
}

bmp_load_config <- function(path_or_list, analysis_type = NULL) {
  base <- getwd()
  source_path <- NULL
  if (is.character(path_or_list) && length(path_or_list) == 1L) {
    source_path <- normalizePath(path_or_list, mustWork = TRUE)
    base <- dirname(source_path)
    if (tolower(tools::file_ext(source_path)) == "json") {
      bmp_require("jsonlite")
      raw <- jsonlite::fromJSON(source_path, simplifyVector = FALSE)
    } else {
      bmp_require("yaml")
      raw <- yaml::read_yaml(source_path)
    }
  } else raw <- path_or_list
  if (!is.list(raw) || is.null(names(raw))) stop("Configuration must be a named object or YAML/JSON file.", call. = FALSE)
  raw <- bmp_normalize_names(raw)
  if (anyDuplicated(names(raw))) stop("Configuration has duplicate normalized keys.", call. = FALSE)
  if (!is.null(raw$workdir)) base <- bmp_path(bmp_scalar(raw$workdir, "workdir"), getwd())
  type <- analysis_type
  if (is.null(type)) type <- raw$analysis_type
  if (is.null(type)) type <- raw$type
  if (is.null(type)) {
    sections <- intersect(c("binary", "survival"), names(raw))
    if (length(sections) != 1L) stop("Set analysis_type to binary or survival (or supply exactly one corresponding section).", call. = FALSE)
    type <- sections
  }
  type <- bmp_scalar(type, "analysis_type")
  if (!type %in% c("binary", "survival")) stop("analysis_type must be binary or survival.", call. = FALSE)
  section <- raw[[type]]
  raw[c("binary", "survival")] <- NULL
  if (!is.null(section)) {
    if (!is.list(section) || is.null(names(section))) stop("The analysis section must be a named object.", call. = FALSE)
    raw[names(section)] <- section
  }
  aliases <- c(group_id = "group_column", time_column = "time_variable", event_column = "event",
               outcome_column = "outcome", id_column = "sample_id",
               schema_version = "config_version")
  for (alias in names(aliases)) {
    key <- aliases[[alias]]
    if (is.null(raw[[key]]) && !is.null(raw[[alias]])) raw[[key]] <- raw[[alias]]
  }
  defaults <- bmp_config_defaults(type)
  result <- defaults
  # Known legacy keys are retained for audit only; they do not restore legacy
  # train/test selection behavior. Nested CV always controls model assessment.
  for (key in intersect(names(raw), names(defaults))) if (!is.null(raw[[key]])) result[[key]] <- raw[[key]]
  known_metadata <- c("type", "workdir", names(aliases), "split_prop", "num_seed", "freq", "prescreen_seeds",
                      "normalization_warnings", "source_config", "clinical_types", "gene_columns", "unknown_options")
  unknown <- setdiff(names(raw), c(names(defaults), known_metadata))
  for (key in unknown) result[key] <- list(raw[[key]])
  for (key in intersect(c("clinical_types", "gene_columns"), names(raw))) result[key] <- list(raw[[key]])
  if (!is.null(result$gene_columns)) result$gene_columns <- bmp_strings(result$gene_columns)
  result$analysis_type <- type
  for (key in c("data_file", "output_dir", "sample_id", "group_column", "outcome", "event", "time_variable",
                "positive_class", "negative_class", "positive_label", "negative_label", "time_unit", "imputation", "p_adjust_method")) {
    result[key] <- list(bmp_scalar(result[[key]], key))
    if (!is.null(result[[key]])) result[[key]] <- as.character(result[[key]])
  }
  if (is.null(result$data_file)) stop("data_file is required.", call. = FALSE)
  if (is.null(result$sample_id) || !nzchar(result$sample_id)) stop("sample_id is required.", call. = FALSE)
  if (identical(result$positive_class, result$negative_class)) stop("positive_class and negative_class must differ.", call. = FALSE)
  if (!is.null(result$group_column) && !nzchar(result$group_column)) result$group_column <- NULL
  result$data_file <- bmp_path(result$data_file, base)
  result$output_dir <- bmp_path(result$output_dir, base)
  for (key in c("clinical_columns", "features", "include", "exclude", "models", "feature_sets")) result[[key]] <- bmp_strings(result[[key]])
  if (!length(result$feature_sets)) result$feature_sets <- if (length(result$clinical_columns)) c("genes", "clinical", "combined") else "genes"
  integer_keys <- c("config_version", "outer_folds", "inner_folds", "repeats", "seed", "workers", "max_features", "top_k", "max_candidates_per_step", "bootstrap_samples")
  for (key in integer_keys) {
    if (is.null(result[[key]])) next
    value <- suppressWarnings(as.numeric(bmp_scalar(result[[key]], key)))
    minimum <- if (key %in% c("seed", "bootstrap_samples")) 0 else if (key %in% c("outer_folds", "inner_folds")) 2 else 1
    if (!is.finite(value) || value < minimum || value != floor(value) || value > .Machine$integer.max) {
      stop(sprintf("%s must be an integer >= %s.", key, minimum), call. = FALSE)
    }
    result[[key]] <- as.integer(value)
  }
  if (result$config_version != 1L) stop("Unsupported config_version; this engine supports version 1.", call. = FALSE)
  migration <- character()
  if (length(unknown)) migration <- c(migration, paste("Unrecognized extension options retained; verify engine support:", paste(unknown, collapse = ", ")))
  if (!is.null(raw$freq) && is.null(raw$selection_frequency)) {
    count <- suppressWarnings(as.numeric(bmp_scalar(raw$freq, "freq")))
    seeds <- suppressWarnings(as.numeric(bmp_scalar(raw$num_seed, "num_seed")))
    if (length(seeds) != 1L || !is.finite(seeds) || seeds < 1 || seeds != floor(seeds) ||
        !is.finite(count) || count < 1 || count != floor(count) || count > seeds) {
      stop("Legacy freq must be an integer from 1 through num_seed. Prefer selection_frequency in (0, 1].", call. = FALSE)
    }
    result$selection_frequency <- count / seeds
    migration <- c(migration, sprintf("Legacy freq/num_seed converted to selection_frequency=%g; num_seed does not control nested folds.", result$selection_frequency))
  }
  for (key in c("selection_frequency", "missing_threshold", "p_threshold", "horizon")) {
    if (is.null(result[[key]])) next
    value <- suppressWarnings(as.numeric(bmp_scalar(result[[key]], key)))
    min_inclusive <- key == "missing_threshold"
    if (!is.finite(value) || (if (min_inclusive) value < 0 else value <= 0) ||
        (key != "horizon" && value > 1)) stop(sprintf("%s must be %s.", key, if (key == "horizon") "positive" else if (min_inclusive) "between 0 and 1" else "in (0, 1]"), call. = FALSE)
    result[[key]] <- value
  }
  result$panel_sizes <- sort(unique(as.numeric(unlist(result$panel_sizes, use.names = FALSE))))
  if (!length(result$panel_sizes) || any(!is.finite(result$panel_sizes) | result$panel_sizes < 1 | result$panel_sizes != floor(result$panel_sizes))) stop("panel_sizes must contain positive integers.", call. = FALSE)
  result$panel_sizes <- as.integer(result$panel_sizes)
  if (any(result$panel_sizes > result$max_features)) {
    result$panel_sizes <- sort(unique(c(result$panel_sizes[result$panel_sizes <= result$max_features], result$max_features)))
    migration <- c(migration, "panel_sizes capped at max_features.")
  }
  result$alpha_grid <- sort(unique(as.numeric(unlist(result$alpha_grid, use.names = FALSE))))
  if (!length(result$alpha_grid) || any(!is.finite(result$alpha_grid) | result$alpha_grid < 0 | result$alpha_grid > 1)) stop("alpha_grid must contain numbers between 0 and 1.", call. = FALSE)
  if (!length(result$models) || any(!result$models %in% c("stepwise", "elastic_net"))) stop("models must contain stepwise and/or elastic_net.", call. = FALSE)
  if (any(!result$feature_sets %in% c("genes", "clinical", "combined"))) stop("feature_sets must be genes, clinical, and/or combined.", call. = FALSE)
  if (any(result$feature_sets %in% c("clinical", "combined")) && !length(result$clinical_columns)) stop("clinical or combined feature_sets require clinical_columns.", call. = FALSE)
  if (!result$p_adjust_method %in% stats::p.adjust.methods) stop("p_adjust_method is not a supported R p.adjust method.", call. = FALSE)
  if (!identical(result$imputation, "median")) stop("imputation currently supports median only (categorical predictors use the training mode).", call. = FALSE)
  if (!result$time_unit %in% c("days", "months", "years")) stop("time_unit must be days, months, or years; horizon uses that same unit.", call. = FALSE)
  if (length(intersect(result$include, result$exclude))) stop("A column cannot appear in both include and exclude.", call. = FALSE)
  if (!is.null(result$evidence)) {
    evidence <- bmp_normalize_names(result$evidence)
    if (!is.list(evidence)) stop("evidence must be an object.", call. = FALSE)
    evidence$gene_file <- bmp_path(bmp_scalar(evidence$gene_file, "evidence.gene_file"), base)
    if (is.null(evidence$gene_file)) stop("evidence.gene_file is required when evidence is configured.", call. = FALSE)
    evidence$score_threshold <- as.numeric(bmp_scalar(evidence$score_threshold, "evidence.score_threshold", 0))
    if (!is.finite(evidence$score_threshold) || evidence$score_threshold < 0 || evidence$score_threshold > 1) stop("evidence.score_threshold must be between 0 and 1.", call. = FALSE)
    result$evidence <- evidence
  }
  for (key in intersect(c("split_prop", "num_seed", "prescreen_seeds"), names(raw))) {
    migration <- c(migration, sprintf("Legacy %s is recorded but unused: validation uses outer_folds/inner_folds/repeats.", key))
  }
  # Runtime audit keys survive re-normalization without changing modeling inputs.
  result$normalization_warnings <- unique(c(bmp_strings(raw$normalization_warnings), migration))
  result$source_config <- if (!is.null(source_path)) source_path else bmp_scalar(raw$source_config, "source_config")
  result
}
