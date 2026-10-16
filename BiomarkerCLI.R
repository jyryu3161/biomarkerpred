#!/usr/bin/env Rscript
# Resolve the installed engine from the script, independently of the data cwd.
local({
  script <- sub("^--file=", "", commandArgs(FALSE)[grepl("^--file=", commandArgs(FALSE))][1L])
  source(file.path(dirname(normalizePath(script, mustWork = TRUE)), "R", "load.R"), local = .GlobalEnv)
})
bmp_cli_main(commandArgs(TRUE))
