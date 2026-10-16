# Run from any directory: Rscript /repo/tests/test_foundation.R
script <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())][1L])
repo <- dirname(dirname(normalizePath(script, mustWork = TRUE)))
source(file.path(repo, "R", "load.R"))
fixtures <- file.path(repo, "tests", "fixtures")
temporary <- tempfile("bmp-foundation-")
dir.create(temporary)

expect_error <- function(expression, pattern) {
  error <- tryCatch({ force(expression); NULL }, error = identity)
  stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error), ignore.case = TRUE))
  invisible(error)
}

binary <- bmp_load_config(file.path(fixtures, "binary.json"))
binary$output_dir <- file.path(temporary, "results")
stopifnot(binary$config_version == 1L, binary$selection_frequency == 0.5,
  identical(binary$feature_sets, c("genes", "clinical", "combined")),
  binary$bootstrap_samples == 0L, identical(binary$positive_class, "1"))
schema <- bmp_read_json(file.path(repo, "config", "schema.json"))
stopifnot(binary$seed == schema[["$defs"]]$analysis$properties$seed$default)

# Legacy migration and flat GUI configuration are semantically equivalent.
legacy <- list(workdir = repo, binary = list(data_file = "tests/fixtures/binary.csv",
  sample_id = "sample", outcome = "response", group_column = "patient",
  clinical_columns = c("age", "sex"), num_seed = 10, freq = 5,
  outer_folds = 3, inner_folds = 2, max_features = 3, panel_sizes = c(1, 3), bootstrap_samples = 0))
gui <- list(type = "binary", dataFile = file.path(fixtures, "binary.csv"), sampleId = "sample",
  outcome = "response", groupColumn = "patient", clinicalColumns = c("age", "sex"),
  selectionFrequency = 0.5, outerFolds = 3, innerFolds = 2, maxFeatures = 3,
  panelSizes = c(1, 3), bootstrapSamples = 0)
stopifnot(identical(bmp_semantic_config(bmp_load_config(legacy)), bmp_semantic_config(bmp_load_config(gui))))
bad_legacy <- legacy
bad_legacy$binary$freq <- 11
expect_error(bmp_load_config(bad_legacy), "freq")
bad_config <- binary
bad_config$selection_frequency <- 0
expect_error(bmp_load_config(bad_config), "selection_frequency")
bad_config <- binary
bad_config$include <- "gene A"
bad_config$exclude <- "gene A"
expect_error(bmp_load_config(bad_config), "both include and exclude")
extension <- binary
extension$future_option <- "visible"
stopifnot(bmp_load_config(extension)$future_option == "visible",
  any(grepl("future_option", bmp_load_config(extension)$normalization_warnings)))

quoted <- bmp_read_csv(file.path(fixtures, "quoted.csv"))
stopifnot(identical(quoted$sample, c("0001", "0002")), "gene,quoted" %in% names(quoted), "gene with space" %in% names(quoted))
malformed <- file.path(temporary, "malformed.csv")
writeLines(c("sample,response,gene", "001,0,1,extra"), malformed)
expect_error(bmp_read_csv(malformed), "inconsistent field counts")
multiline <- file.path(temporary, "multiline.csv")
writeLines(c('sample,response,note', '001,0,"first', 'second"'), multiline)
stopifnot(bmp_read_csv(multiline)$note == "first\nsecond")
checked <- bmp_validate_data(binary)
stopifnot(checked$qc$status == "passed", checked$qc$groups == 40L, checked$qc$repeated_groups == 40L,
  checked$data$sample[1] == "0001", is.numeric(checked$data[["gene A"]]),
  "constant" %in% checked$config$gene_columns, "constant" %in% checked$qc$constant_columns,
  "mostly_missing" %in% checked$config$gene_columns, "mostly_missing" %in% checked$qc$high_missing_columns,
  checked$config$clinical_types$sex == "categorical", anyNA(checked$data[["gene,quoted"]]))
stopifnot(identical(bmp_semantic_config(binary), bmp_semantic_config(checked$config)))
stopifnot(identical(bmp_load_config(checked$config), bmp_load_config(bmp_load_config(checked$config))))
bmp_atomic_json(checked$config, file.path(temporary, "roundtrip.json"))
stopifnot(identical(bmp_hash_object(bmp_semantic_config(checked$config)),
  bmp_hash_object(bmp_semantic_config(bmp_read_json(file.path(temporary, "roundtrip.json"))))))
bmp_atomic_json(list(models = "stepwise", include = character(), panel_sizes = 1L), file.path(temporary, "arrays.json"))
arrays <- bmp_read_json(file.path(temporary, "arrays.json"))
stopifnot(is.list(arrays$models), length(arrays$models) == 1L, is.list(arrays$include), length(arrays$include) == 0L,
  is.list(arrays$panel_sizes))
maps <- list(models = list(arm_one = list(models = "stepwise", coefficients = list(models = 0.2))),
  missing_fraction = list(models = 0.25, warnings = 0),
  distribution = list(models = list(counts = list(models = 5, warnings = 3))))
bmp_atomic_json(maps, file.path(temporary, "maps.json"))
restored_maps <- bmp_read_json(file.path(temporary, "maps.json"))
stopifnot(identical(names(restored_maps$models), "arm_one"),
  restored_maps$models$arm_one$coefficients$models == 0.2,
  is.list(restored_maps$models$arm_one$models),
  restored_maps$missing_fraction$models == 0.25,
  restored_maps$distribution$models$counts$models == 5,
  !is.list(restored_maps$missing_fraction$warnings))

bad <- checked$data
bad$sample[2] <- bad$sample[1]
expect_error(bmp_validate_data(binary, bad), "Duplicate sample IDs")
bad <- checked$data
bad$response[1] <- "missing-class"
expect_error(bmp_validate_data(binary, bad), "positive_class")
bad <- checked$data
bad$response[2] <- "1"
expect_error(bmp_validate_data(binary, bad), "conflicting binary outcomes")
bad <- checked$data
bad[["gene A"]][1] <- "oops"
expect_error(bmp_validate_data(binary, bad), "numeric and finite")
bad <- checked$data
bad$patient[1] <- NA_character_
expect_error(bmp_validate_data(binary, bad), "missing/blank")
bad_config <- binary
bad_config$features <- c("response", "gene A")
expect_error(bmp_validate_data(bad_config), "gene columns only")
bad_config <- binary
bad_config$outer_folds <- 30L
error <- expect_error(bmp_validate_data(bad_config), "Insufficient independent")
stopifnot(inherits(error, "bmp_validation_error"), error$qc$status == "failed")

survival <- bmp_load_config(file.path(fixtures, "survival.json"))
surv_checked <- bmp_validate_data(survival)
stopifnot(surv_checked$qc$events > 0, surv_checked$qc$censored > 0,
  surv_checked$config$time_unit == "years", surv_checked$config$horizon == 3)
uncensored <- surv_checked$data
uncensored$OS <- 1L
stopifnot(bmp_validate_data(survival, uncensored)$qc$censored == 0)
bad <- surv_checked$data
bad$OS[1] <- 2
expect_error(bmp_validate_data(survival, bad), "0=censored")
bad <- surv_checked$data
bad$OS.year[1] <- 0
expect_error(bmp_validate_data(survival, bad), "positive numbers")
bad_config <- survival
bad_config$time_unit <- "fortnights"
expect_error(bmp_load_config(bad_config), "time_unit")

# Evidence is a fixed prior and is included in provenance.
evidence_file <- file.path(temporary, "evidence.csv")
utils::write.csv(data.frame(gene_symbol = c("gene A", "GENE-2"), score = c(0.9, 0.2)), evidence_file, row.names = FALSE)
evidence_config <- binary
evidence_config$evidence <- list(gene_file = evidence_file, score_threshold = 0.5, source = "synthetic", version = "1")
evidence_checked <- bmp_validate_data(evidence_config)
stopifnot(identical(evidence_checked$config$gene_columns, "gene A"),
  bmp_provenance(evidence_checked$config)$evidence$sha256 == bmp_sha256(evidence_file))

# New runs never share a directory or consume another run's files.
set.seed(765)
before_rng <- .Random.seed
first <- bmp_new_run(checked$config, checked$qc)
second <- bmp_new_run(checked$config, checked$qc)
stopifnot(identical(before_rng, .Random.seed), first$dir != second$dir,
  length(bmp_list_runs(binary$output_dir)) == 2L,
  file.exists(file.path(first$dir, "qc.json")), file.exists(file.path(first$dir, "config.json")))
resumed <- bmp_resume_run(first$dir, checked$config)
stopifnot(resumed$id == first$id)
changed_output <- checked$config
changed_output$output_dir <- file.path(temporary, "other-output")
stopifnot(bmp_resume_run(first$dir, changed_output)$id == first$id)
changed <- checked$config
changed$seed <- changed$seed + 1L
expect_error(bmp_resume_run(first$dir, changed), "incompatible")
copy_config <- checked$config
copy_config$data_file <- file.path(temporary, "copied-input.csv")
stopifnot(file.copy(binary$data_file, copy_config$data_file))
copy_run <- bmp_new_run(copy_config, checked$qc)
cat("\n", file = copy_config$data_file, append = TRUE)
expect_error(bmp_resume_run(copy_run$dir, copy_config), "incompatible")
expect_error(bmp_update_manifest(first, "completed"), "partial")
stopifnot(bmp_read_json(file.path(first$dir, "manifest.json"))$status == "partial")
second <- bmp_update_manifest(second, "failed", errors = "Synthetic failure")
stopifnot(second$manifest$status == "failed", unlist(second$manifest$errors) == "Synthetic failure")
writeLines("synthetic required result", file.path(first$dir, "result.txt"))
first <- bmp_update_manifest(first, "completed", required_artifacts = "result.txt", errors = character())
stopifnot(first$manifest$status == "completed", bmp_resume_run(first$dir, checked$config)$id == first$id)
writeLines("changed result", file.path(first$dir, "result.txt"))
expect_error(bmp_resume_run(first$dir, checked$config), "artifacts are missing or changed")
expect_error(bmp_verify_artifacts(first$dir, "../outside.txt"), "inside the run")

# Loading from elsewhere must never look for modules in a data directory.
original_directory <- getwd()
setwd(temporary)
loaded <- new.env(parent = globalenv())
sys.source(file.path(repo, "R", "load.R"), envir = loaded)
stopifnot(exists("bmp_load_config", envir = loaded, inherits = FALSE), identical(loaded$bmp_repo_root, repo))
setwd(original_directory)
unlink(temporary, recursive = TRUE)
cat("Foundation checks passed: normalization, quoted CSV, grouped QC, provenance, run isolation, artifact checks and resume compatibility.\n")
