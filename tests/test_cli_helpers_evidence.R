# Focused identity-boundary and exact-ID checks in addition to primary acceptance.
script <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())][1L])
source(file.path(dirname(dirname(normalizePath(script))), "R", "load.R"))
local({
  work <- tempfile("bmp-helper-evidence-"); dir.create(work)
  on.exit(unlink(work, recursive = TRUE), add = TRUE)
  config <- bmp_load_config(file.path(bmp_repo_root, "tests", "fixtures", "binary.json"))
  config$output_dir <- file.path(work, "runs")
  evidence <- file.path(work, "evidence.csv")
  config$evidence <- list(gene_file = evidence, score_threshold = .5, source = "synthetic", sha256 = "untrusted metadata")
  bmp_atomic_csv(data.frame(gene_symbol = c("gene a", "gene A", "ENSG1.1"),
    ensembl_id = c("ENSG1", "GENE-2", "gene,quoted.1"), score = c(.9, .8, .7)), evidence)
  checked <- bmp_validate_data(config)
  stopifnot(setequal(checked$qc$eligible_genes, c("gene A", "GENE-2")),
    checked$qc$evidence$eligible_evidence_rows == 3L,
    checked$qc$evidence$eligible_evidence_identifiers == 6L,
    checked$qc$evidence$matched_gene_symbols == 1L,
    checked$qc$evidence$matched_ensembl_ids == 1L,
    checked$qc$evidence$matched_genes == 2L,
    "gene,quoted" %in% checked$qc$measured_genes)
  bmp_atomic_csv(data.frame(ensembl_id = "GENE-2", score = .9), evidence)
  checked <- bmp_validate_data(config)
  stopifnot(identical(checked$qc$eligible_genes, "GENE-2"))
  original_hash <- bmp_sha256(evidence)
  stopifnot(identical(bmp_evidence_identity(config)$sha256, original_hash))
  expect_error <- function(code) {
    error <- tryCatch({ force(code); NULL }, error = identity)
    stopifnot(inherits(error, "error"), grepl("evidence", conditionMessage(error), ignore.case = TRUE))
    error
  }
  original_provenance <- bmp_provenance
  on.exit(assign("bmp_provenance", original_provenance, envir = .GlobalEnv), add = TRUE)
  assign("bmp_provenance", function(config) {
    value <- original_provenance(config)
    cat("\n", file = evidence, append = TRUE)
    value
  }, envir = .GlobalEnv)
  expect_error(bmp_cli_analyze(config))
  assign("bmp_provenance", original_provenance, envir = .GlobalEnv)
  stopifnot(!dir.exists(config$output_dir))
  bmp_atomic_csv(data.frame(ensembl_id = "GENE-2", score = .9), evidence)
  original_new_run <- bmp_new_run
  on.exit(assign("bmp_new_run", original_new_run, envir = .GlobalEnv), add = TRUE)
  assign("bmp_new_run", function(...) {
    value <- original_new_run(...)
    cat("\n", file = evidence, append = TRUE)
    value
  }, envir = .GlobalEnv)
  error <- expect_error(bmp_cli_analyze(config))
  assign("bmp_new_run", original_new_run, envir = .GlobalEnv)
  manifest <- bmp_read_json(file.path(error$run_dir, "manifest.json"))
  stopifnot(identical(manifest$status, "failed"), identical(manifest$provenance$evidence$sha256, original_hash))

  original_graphics_probe <- bmp_cli_graphics_probe
  on.exit(assign("bmp_cli_graphics_probe", original_graphics_probe, envir = .GlobalEnv), add = TRUE)
  assign("bmp_cli_graphics_probe", function() {
    original_graphics_probe(list(png = function(path) stop("PNG backend unavailable: install Cairo/PNG libraries.", call. = FALSE)))
  }, envir = .GlobalEnv)
  doctor <- bmp_cli_doctor()
  assign("bmp_cli_graphics_probe", original_graphics_probe, envir = .GlobalEnv)
  stopifnot(!doctor$ok, !doctor$graphics$png, grepl("PNG", doctor$error),
    !doctor$graphics_exports$png$ok, grepl("install Cairo/PNG", doctor$graphics_exports$png$error))
  cat("CLI helper R checks passed: exact identifiers, identity races, original failure provenance and graphics readiness.\n")
})
