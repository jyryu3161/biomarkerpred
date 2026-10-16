# Independent evidence-prior acceptance for the final CLI integration stage.
# Synthetic assay identifiers and deliberate input changes; no network requests.
source("R/load.R")
local({
  workspace <- tempfile("bmp-evidence-review-"); dir.create(workspace)
  on.exit(unlink(workspace, recursive = TRUE), add = TRUE)
  input <- file.path(workspace, "assay.csv")
  evidence_path <- file.path(workspace, "evidence.csv")
  data <- bmp_read_csv(file.path(bmp_repo_root, "tests", "fixtures", "binary.csv"))
  names(data)[names(data) == "gene A"] <- "ENSG00000012048"
  names(data)[names(data) == "GENE-2"] <- "BRCA2"
  bmp_atomic_csv(data, input)
  evidence <- data.frame(gene_symbol = c("BRCA1", "BRCA2"),
    ensembl_id = c("ENSG00000012048", "ENSG00000139618"), score = c(.9, .4))
  bmp_atomic_csv(evidence, evidence_path)
  config <- bmp_load_config(file.path(bmp_repo_root, "tests", "fixtures", "binary.json"))
  config$data_file <- input; config$output_dir <- file.path(workspace, "results")
  config$models <- "stepwise"; config$feature_sets <- "genes"
  config$panel_sizes <- 1L; config$max_features <- 1L
  config$evidence <- list(gene_file = evidence_path, score_threshold = .5,
    source = "Synthetic Open Targets-shaped evidence", disease_id = "SYNTHETIC_1")

  # Exact Ensembl IDs and symbols are both supported, without case/version guesses.
  checked <- bmp_validate_data(config)
  stopifnot(identical(bmp_strings(checked$qc$eligible_genes), "ENSG00000012048"),
    "BRCA2" %in% checked$qc$measured_genes, checked$qc$evidence$matched_genes == 1L)
  config$evidence$score_threshold <- .3
  checked <- bmp_validate_data(config)
  stopifnot(setequal(bmp_strings(checked$qc$eligible_genes), c("ENSG00000012048", "BRCA2")))
  config$evidence$score_threshold <- .5

  assert_evidence_change <- function(code) {
    error <- tryCatch({ force(code); NULL }, error = identity)
    stopifnot(inherits(error, "error"),
      grepl("evidence", conditionMessage(error), ignore.case = TRUE),
      grepl("chang|identity|hash", conditionMessage(error), ignore.case = TRUE))
    error
  }
  original_validate <- bmp_validate_data
  on.exit(assign("bmp_validate_data", original_validate, envir = .GlobalEnv), add = TRUE)
  assign("bmp_validate_data", function(config, data = NULL) {
    result <- original_validate(config, data)
    cat("\n", file = config$evidence$gene_file, append = TRUE)
    result
  }, envir = .GlobalEnv)
  assert_evidence_change(bmp_cli_analyze(config))
  assign("bmp_validate_data", original_validate, envir = .GlobalEnv)
  stopifnot(!length(bmp_list_runs(config$output_dir)))
  bmp_atomic_csv(evidence, evidence_path)

  # A source mutation after fitting must not be reported as a verified completion.
  before <- bmp_sha256(evidence_path)
  original_engine <- bmp_run_engine
  on.exit(assign("bmp_run_engine", original_engine, envir = .GlobalEnv), add = TRUE)
  assign("bmp_run_engine", function(...) {
    result <- original_engine(...)
    cat("\n", file = evidence_path, append = TRUE)
    result
  }, envir = .GlobalEnv)
  error <- assert_evidence_change(bmp_cli_analyze(config))
  assign("bmp_run_engine", original_engine, envir = .GlobalEnv)
  stopifnot(!is.null(error$run_dir))
  manifest <- bmp_read_json(file.path(error$run_dir, "manifest.json"))
  stopifnot(identical(manifest$status, "failed"),
    identical(manifest$provenance$evidence$sha256, before))
  cat("Independent evidence review passed: exact identifier matching and evidence identity across QC/fitting/completion.\n")
})
