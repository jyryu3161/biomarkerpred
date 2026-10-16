# Compatibility helper. No legacy Result object is silently refitted or upgraded.
local({
  files <- vapply(sys.frames(), function(frame) if (is.character(frame$ofile) && length(frame$ofile) == 1L) frame$ofile else "", character(1))
  path <- tail(files[basename(files) == "Save_Model.R"], 1L)
  if (!exists("bmp_save_model", mode = "function") && length(path)) source(file.path(dirname(normalizePath(path, mustWork = TRUE)), "R", "load.R"), local = .GlobalEnv)
})
SaveModelArtifact <- function(dat = NULL, Result = NULL, analysis_type = NULL, output_dir = NULL,
                              numSeed = NULL, SplitProp = NULL, config = NULL, model = NULL, path = NULL) {
  if (is.null(model)) stop("Legacy Result objects lack a validated frozen encoder/threshold/baseline. Retrain using BiomarkerCLI.R analyze. To save an already validated model, pass model= and path= (or output_dir=).", call. = FALSE)
  if (is.null(path)) {
    if (is.null(output_dir)) stop("Provide path or output_dir for the validated artifact.", call. = FALSE)
    path <- file.path(output_dir, "model.bmpmodel")
  }
  bmp_save_model(model, path)
  invisible(path)
}
