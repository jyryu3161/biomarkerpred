#!/usr/bin/env Rscript
# Reproducible synthetic-only browser data. STRING transport is explicitly mocked.
script <- sub('^--file=', '', commandArgs(FALSE)[grepl('^--file=', commandArgs(FALSE))][1L])
root <- normalizePath(file.path(dirname(script), '..'), mustWork = TRUE)
source(file.path(root, 'R/load.R'))
args <- commandArgs(TRUE)
if (length(args) != 1L) stop('Usage: Rscript tests/generate_browser_fixtures.R NEW_OUTPUT_DIRECTORY')
if (file.exists(args[1])) stop('Output directory already exists; choose a fresh destination.')
dir.create(args[1], recursive = TRUE)
output <- normalizePath(args[1], mustWork = TRUE)
runs <- list()
for (kind in c('binary', 'survival')) {
  config <- bmp_load_config(file.path(root, 'tests/fixtures', paste0(kind, '.json')))
  config$output_dir <- file.path(output, kind)
  config$models <- 'stepwise'; config$feature_sets <- 'genes'; config$features <- 'GENE-2'
  config$max_features <- 1L; config$panel_sizes <- 1L; config$p_threshold <- 1e-300
  config$bootstrap_samples <- 0L
  result <- bmp_cli_analyze(config)
  stopifnot(result$ok, length(bmp_load_model(result$paths$model)$features) == 0L)
  runs[[kind]] <- result$run_dir
}
config <- bmp_load_config(file.path(root, 'tests/fixtures/binary.json'))
data <- bmp_read_csv(config$data_file)
set.seed(23)
for (gene in LETTERS[1:10]) data[[gene]] <- rnorm(nrow(data)) + if (gene %in% c('A', 'B')) as.numeric(data$response)*.3 else 0
config$data_file <- file.path(output, 'synthetic network input.csv'); bmp_atomic_csv(data, config$data_file)
config$output_dir <- file.path(output, 'network-development')
config$features <- LETTERS[1:10]; config$feature_sets <- 'genes'; config$models <- 'stepwise'
config$include <- c('A','B'); config$max_features <- 2L; config$panel_sizes <- 2L
config$selection_frequency <- .01; config$p_threshold <- 1
source_run <- bmp_cli_analyze(config)
mapping <- file.path(output, 'mapping.csv')
bmp_atomic_csv(data.frame(source_id=LETTERS[1:10], target_id=c('X','X','C','D_ALIAS',LETTERS[5:10])), mapping)
gmt <- file.path(output, 'annotation.gmt')
writeLines(c('signal\tMapped synthetic term\tX\tD_ALIAS', 'all\tMapped universe\tX\tC\tD_ALIAS\tE\tF\tG\tH\tI\tJ', 'outside\tUnmeasured\tK'), gmt)
options(bmp.string.transport=function(endpoint, parameters) {
  if (endsWith(endpoint, 'get_string_ids')) return('[{"queryItem":"A","stringId":"9606.x","preferredName":"OriginalAlias","ncbiTaxonId":9606},{"queryItem":"B","stringId":"9606.x","preferredName":"OriginalAlias","ncbiTaxonId":9606}]')
  '[{"stringId_A":"9606.x","stringId_B":"9606.d","preferredName_A":"OriginalAlias","preferredName_B":"D_ALIAS","score":0.9,"escore":0.7},{"stringId_A":"9606.x","stringId_B":"9606.k","preferredName_A":"OriginalAlias","preferredName_B":"K","score":0.8}]'
})
pathway <- bmp_pathway_analysis(source_run$run_dir, list(gmt=gmt, mapping=mapping, network='string', 'add-nodes'='2', 'annotation-version'='synthetic-browser-v1', 'min-size'='1', permutations='19'))
stopifnot(pathway$ok)
runs$pathway <- pathway$run_dir
runs$network_transport <- 'mock: no network requests'
bmp_atomic_json(runs, file.path(output, 'fixtures.json'))
cat(jsonlite::toJSON(runs, auto_unbox=TRUE), '\n')
