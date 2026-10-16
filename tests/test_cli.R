# Stateful CLI/report acceptance beyond the independent process-level review.
source("R/load.R")
assert_error <- function(code, pattern) {
  error <- tryCatch({ force(code); NULL }, error = identity)
  stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error), ignore.case = TRUE))
  invisible(error)
}
workspace <- tempfile("bmp-cli-tests-"); dir.create(workspace)

# Option parser is strict; path contents are values, not shell syntax.
stopifnot(identical(bmp_cli_parse(c("compare", "--run", "a,b", "--run=c; d", "--json"))$options$run, c("a,b", "c; d")))
assert_error(bmp_cli_parse(c("predict", "--data=a", "--data", "b")), "Duplicate")
assert_error(bmp_cli_parse(c("analyze", "--workers", "2")), "Unsupported")
assert_error(bmp_cli_parse(c("analyze", "--config")), "Missing value")
# Runtime diagnosis remains machine-readable even if jsonlite itself is absent.
original_require <- requireNamespace
requireNamespace <- function(package, ...) if (identical(package, "jsonlite")) FALSE else original_require(package, ...)
diagnosis <- bmp_cli_doctor(); encoded <- bmp_cli_json(diagnosis)
rm(requireNamespace)
decoded <- jsonlite::fromJSON(encoded)
stopifnot(!decoded$ok, "jsonlite" %in% decoded$missing_packages)
legacy_model <- file.path(workspace, "legacy.bmpmodel")
bmp_atomic_json(list(variables = "old_gene", coefficients = 1), legacy_model)
assert_error(bmp_cli_evaluate(list(model = legacy_model, data = "missing.csv", output = workspace)), "Retrain legacy")

# Real concurrent owner: the child holds an atomic lock until terminated.
lock_dir <- file.path(workspace, "concurrent"); dir.create(lock_dir)
child <- file.path(workspace, "child.R"); ready <- file.path(workspace, "ready")
writeLines(c(sprintf("source(%s)", deparse(file.path(bmp_repo_root, "R", "load.R"))),
  sprintf("lock <- bmp_lock_acquire(%s, 'test-child')", deparse(lock_dir)),
  sprintf("writeLines(as.character(Sys.getpid()), %s)", deparse(ready)), "Sys.sleep(30)"), child)
system2(file.path(R.home("bin"), "Rscript"), shQuote(child), stdout = file.path(workspace, "child.out"), stderr = file.path(workspace, "child.err"), wait = FALSE)
for (i in seq_len(100)) { if (file.exists(ready)) break; Sys.sleep(.05) }
stopifnot(file.exists(ready)); pid <- as.integer(readLines(ready))
owner <- bmp_read_json(file.path(lock_dir, ".mutation.lock", "owner.json"))
assert_error(bmp_lock_acquire(lock_dir, "competing-report", owner$token), "live PID")
tools::pskill(pid, tools::SIGTERM)
for (i in seq_len(100)) { if (!isTRUE(bmp_process_identity(pid)$alive)) break; Sys.sleep(.02) }
lock <- bmp_lock_acquire(lock_dir, "after-known-termination")
stopifnot(length(list.files(lock_dir, pattern = "stale-lock", all.files = TRUE)) == 1L)
bmp_lock_release(lock)
# A different context cannot be inferred stale from a local PID.
lock <- bmp_lock_acquire(lock_dir, "foreign-context")
foreign <- bmp_read_json(file.path(lock$path, "owner.json")); foreign$context$pid_namespace <- "other-container"
bmp_atomic_json(foreign, file.path(lock$path, "owner.json"))
assert_error(bmp_lock_acquire(lock_dir, "without-confirmation"), "Cannot verify termination")
recovered <- bmp_lock_acquire(lock_dir, "verified-foreign-termination", foreign$token)
bmp_lock_release(recovered)

# A genuine completed run supports reports, and report transaction failure
# restores both completed manifest and every existing derived artifact byte.
config <- bmp_load_config("tests/fixtures/binary.json")
config$output_dir <- file.path(workspace, "results"); config$models <- "stepwise"; config$feature_sets <- "clinical"; config$panel_sizes <- 1L
input <- file.path(workspace, "input.csv"); file.copy(config$data_file, input); config$data_file <- input
result <- bmp_cli_analyze(config); run <- bmp_run_open(result$run_dir)
required <- bmp_strings(run$manifest$required_artifacts)
before <- stats::setNames(lapply(file.path(run$dir, c(required, "manifest.json")), bmp_sha256), c(required, "manifest.json"))
original_install <- bmp_report_install_file; installs <- 0L
bmp_report_install_file <- function(from, to) { installs <<- installs + 1L; if (installs == 3L) FALSE else original_install(from, to) }
assert_error(bmp_report_run(run$dir), "transaction restored")
bmp_report_install_file <- original_install
after <- stats::setNames(lapply(file.path(run$dir, names(before)), bmp_sha256), names(before))
stopifnot(identical(before, after), identical(bmp_run_open(run$dir)$manifest$status, "completed"))

# Tampering must be detected before regenerating derived files or resuming.
predictions_path <- file.path(run$dir, "predictions.csv"); original <- readBin(predictions_path, "raw", file.info(predictions_path)$size)
cat("tampered", file = predictions_path, append = TRUE)
assert_error(bmp_report_run(run$dir), "integrity")
assert_error(bmp_cli_analyze(run$config, run_dir = run$dir), "missing or changed|integrity")
writeBin(original, predictions_path)
stopifnot(!dir.exists(file.path(run$dir, ".mutation.lock")))

# Report-only never upgrades a deliberately partial/failed run to completed.
run <- bmp_update_manifest(run, "partial", errors = "Deliberate interrupted-stage test")
bmp_report_run(run$dir)
stopifnot(identical(bmp_run_open(run$dir)$manifest$status, "partial"))
# Compatible resume reuses final/fold checkpoints and clears only active errors.
model_hash <- bmp_sha256(file.path(run$dir, "model.bmpmodel")); prediction_hash <- bmp_sha256(predictions_path)
resumed <- bmp_cli_analyze(run$config, run_dir = run$dir)
manifest <- bmp_read_json(file.path(run$dir, "manifest.json"))
stopifnot(resumed$ok, identical(manifest$status, "completed"), isTRUE(manifest$final_checkpoint_reused), length(manifest$attempts) == 1L,
  !length(manifest$errors), identical(model_hash, bmp_sha256(file.path(run$dir, "model.bmpmodel"))), identical(prediction_hash, bmp_sha256(predictions_path)))

# Loaded data and the immutable input fingerprint must refer to the same bytes.
original_validate <- bmp_validate_data
bmp_validate_data <- function(config, data = NULL) { value <- original_validate(config, data); cat("\n", file = config$data_file, append = TRUE); value }
count_before <- length(bmp_list_runs(config$output_dir))
assert_error(bmp_cli_analyze(config), "input changed during validation")
bmp_validate_data <- original_validate
stopifnot(length(bmp_list_runs(config$output_dir)) == count_before)
file.copy(file.path(bmp_repo_root, "tests", "fixtures", "binary.csv"), input, overwrite = TRUE)

# External resume never invokes development fitting and includes package/runtime
# compatibility. Single-class evaluation is valid; frozen hashes remain equal.
external <- bmp_read_csv(input)[1:4, ]; external$sample <- paste0("external_", external$sample); external$patient <- paste0("external_", external$patient); external$response <- "0"
external_path <- file.path(workspace, "external.csv"); bmp_atomic_csv(external, external_path)
evaluation <- bmp_cli_evaluate(list(model = file.path(run$dir, "model.bmpmodel"), data = external_path, output = config$output_dir, `bootstrap-samples` = "0"))
evaluation_run <- bmp_run_open(evaluation$run_dir)
stopifnot(length(evaluation_run$manifest$provenance$evaluation_engine$packages) >= 6L)
evaluation_run <- bmp_update_manifest(evaluation_run, "partial", errors = "Simulated interruption after reporting")
original_engine <- bmp_run_engine
bmp_run_engine <- function(...) stop("Development fit must never run during external resume")
evaluated <- bmp_resume_evaluation(evaluation_run)
bmp_run_engine <- original_engine
stopifnot(evaluated$ok, identical(model_hash, bmp_sha256(evaluated$paths$model)))

# Portable null models: no clinical design columns and no selected genes.
for (type in c("binary", "survival")) {
  cfg <- bmp_load_config(file.path("tests", "fixtures", paste0(type, ".json")))
  data <- bmp_read_csv(cfg$data_file); data$constant_only <- "1"
  cfg$clinical_columns <- character(); cfg$feature_sets <- "genes"; cfg$features <- "constant_only"
  value <- bmp_validate_data(cfg, data)
  fitted <- bmp_fit_model(value$data, value$config, list(algorithm = "stepwise", feature_set = "genes", panel_size = 1L, arm_id = "null"))
  stopifnot(length(fitted$artifact$features) == 0L, length(fitted$artifact$recipe$clinical_columns) == 0L)
}
unlink(workspace, recursive = TRUE)
cat("CLI state, locks, rollback, tamper, resume, input identity and null-model tests passed.\n")
