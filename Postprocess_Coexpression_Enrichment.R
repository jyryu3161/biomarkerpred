# Retired entrypoint; do not install packages or consume obsolete marker outputs.
stop(paste(
  "Postprocess_Coexpression_Enrichment.R is retired and no packages were installed.",
  "Use Rscript BiomarkerCLI.R ora --run DEVELOPMENT_RUN --gmt ANNOTATION.gmt --annotation-version VERSION --network none --json.",
  "The source must be a verified completed development run; see ora help for mapping and optional STRING requests.",
  "The old cohort coexpression network is not equivalent to STRING functional associations.",
  "The current ora workflow does not recreate that legacy correlation network."
), call. = FALSE)
