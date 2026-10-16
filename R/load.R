# Source this file from any working directory. Modules define functions only.
# bmp_repo_root records the code location, independently of data/work directories.
local({
  frames <- sys.frames()
  source_files <- vapply(frames, function(frame) {
    value <- if (!is.null(frame$ofile)) frame$ofile else frame$file
    if (!is.character(value) || length(value) != 1L) "" else value
  }, character(1))
  loader <- tail(source_files[basename(source_files) == "load.R"], 1L)
  if (!length(loader)) stop("Load the engine with source('/path/to/R/load.R').", call. = FALSE)
  module_dir <- dirname(normalizePath(loader, mustWork = TRUE))
  target <- parent.env(environment())
  assign("bmp_repo_root", dirname(module_dir), envir = target)
  modules <- list.files(module_dir, pattern = "\\.R$", full.names = TRUE)
  first <- file.path(module_dir, c("config.R", "data.R", "runs.R"))
  modules <- c(first[file.exists(first)], setdiff(modules, c(first, file.path(module_dir, "load.R"))))
  for (module in modules) sys.source(module, envir = target)
})
