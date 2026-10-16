#!/usr/bin/env Rscript
# Compatibility entrypoint for the shared, source-run-grounded pathway engine.
# Legacy --genes/--input cannot reconstruct a measured assay universe; migrate
# to --run DEVELOPMENT_RUN --gmt ANNOTATION (or --term-map / optional GO source).
local({
  script <- sub("^--file=", "", commandArgs(FALSE)[grepl("^--file=", commandArgs(FALSE))][1L])
  source(file.path(dirname(normalizePath(script, mustWork = TRUE)), "R", "load.R"), local = .GlobalEnv)
})
args <- commandArgs(TRUE)
bmp_cli_main(if (length(args) && args[1L] == "ora") args else c("ora", args))
