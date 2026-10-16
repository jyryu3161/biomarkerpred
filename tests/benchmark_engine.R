# Reproducible fitting microbenchmark; excludes nested CV, metrics and reports.
# Rscript tests/benchmark_engine.R --genes=500 --type=binary
# Optional --p-threshold=1 --max-candidates=200 exercises the full capped pool.
# Optional --profile=/tmp/engine.prof records a standard Rprof fitting profile.
script <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())][1L])
repo <- dirname(dirname(normalizePath(script, mustWork = TRUE)))
source(file.path(repo, "R", "load.R"))
args <- commandArgs(trailingOnly = TRUE)
argument <- function(key, default) {
  values <- sub(paste0("^--", key, "="), "", args[startsWith(args, paste0("--", key, "="))])
  if (length(values)) values[1] else default
}
genes <- as.integer(argument("genes", "500"))
type <- argument("type", "binary")
stopifnot(is.finite(genes), genes > 1, type %in% c("binary", "survival"))
validated <- bmp_validate_data(file.path(repo, "tests", "fixtures", paste0(type, ".json")))
data <- validated$data
config <- validated$config
config$p_threshold <- as.numeric(argument("p-threshold", as.character(config$p_threshold)))
config$max_candidates_per_step <- as.integer(argument("max-candidates", as.character(config$max_candidates_per_step)))
stopifnot(is.finite(config$p_threshold), config$p_threshold > 0, config$p_threshold <= 1,
  is.finite(config$max_candidates_per_step), config$max_candidates_per_step >= 1)
set.seed(490)
features <- paste0("marker_", seq_len(genes))
for (name in features) data[[name]] <- rnorm(nrow(data))
signal <- if (type == "binary") as.numeric(data[[config$outcome]] == config$positive_class) else -log(data[[config$time_variable]])
data$marker_1 <- signal + rnorm(nrow(data), sd = .3)
config$gene_columns <- features
config$features <- features
arm <- list(algorithm = "elastic_net", feature_set = "genes", panel_size = 3L,
  alpha = .5, lambda_ratio = .1, arm_id = "benchmark")
profile <- argument("profile", "")
if (nzchar(profile)) utils::Rprof(profile)
elapsed <- system.time(fit <- bmp_fit_model(data, config, arm))
if (nzchar(profile)) utils::Rprof(NULL)
if (type == "binary") {
  fit$artifact$threshold <- .5
  fit$artifact$threshold_method <- "benchmark constant; no performance claim"
}
path <- tempfile(fileext = ".bmpmodel")
bmp_save_model(fit, path)
record <- list(benchmark = "single_fitting_partition_no_nested_assessment", analysis_type = type,
  seed = 490, rows = nrow(data), groups = length(unique(bmp_groups(data, config))), genes = genes,
  elapsed_seconds = unname(elapsed[["elapsed"]]), model_bytes = unname(file.info(path)$size),
  required_predictors = length(unlist(fit$artifact$features)), stored_predictor_encoders = length(fit$artifact$recipe$predictors),
  required_genes = fit$artifact$actual_gene_count, r_version = R.version.string,
  limitation = "One synthetic fitting partition; includes package startup, excludes nested validation, metrics, full screening audit files and reports. Policy versions can select different panels.",
  screening_policy = fit$artifact$recipe$screening_policy)
cat(jsonlite::toJSON(record, auto_unbox = TRUE, null = "null", pretty = TRUE), "\n")
