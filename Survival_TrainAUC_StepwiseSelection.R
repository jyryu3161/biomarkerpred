# Retired scientific API. Main_Survival.R remains the shared CLI wrapper.
stop(paste(
  "Survival_TrainAUC_StepwiseSelection.R is retired: old train-AUC/seed selection is not nested validation.",
  "Use Rscript BiomarkerCLI.R validate --config CONFIG --json, then analyze --config CONFIG --json,",
  "or Rscript Main_Survival.R --config CONFIG --json. Set time_unit and horizon explicitly.",
  "Retrain legacy models; missing encoders, thresholds and survival baselines cannot be invented."
), call. = FALSE)
