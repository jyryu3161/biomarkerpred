# Retired scientific API: neither direct execution nor source() may run the old
# seed/train-AUC selection procedure. Main_Binary.R remains the shared CLI wrapper.
stop(paste(
  "Binary_TrainAUC_StepwiseSelection.R is retired: old train-AUC/seed selection is not nested validation.",
  "Use Rscript BiomarkerCLI.R validate --config CONFIG --json, then analyze --config CONFIG --json,",
  "or Rscript Main_Binary.R --config CONFIG --json. Retrain legacy models; missing encoders/thresholds cannot be invented."
), call. = FALSE)
