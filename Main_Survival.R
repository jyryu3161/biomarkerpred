#!/usr/bin/env Rscript
# Compatibility entrypoint: the shared engine is the only fitting/scoring path.
local({
  script <- sub("^--file=", "", commandArgs(FALSE)[grepl("^--file=", commandArgs(FALSE))][1L])
  source(file.path(dirname(normalizePath(script, mustWork = TRUE)), "R", "load.R"), local = .GlobalEnv)
})
bmp_cli_main(c("survival", commandArgs(TRUE)))
