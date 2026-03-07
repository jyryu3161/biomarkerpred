library(nsROC)
library(caret)
library(survival)
library(pROC)
library(cutpointr)
library(coefplot)
library(yaml)

# === Font detection (shared pattern) ===
available_fonts <- systemfonts::system_fonts()$family
PLOT_FONT <- if ("Arial" %in% available_fonts) {
  "Arial"
} else if ("Helvetica" %in% available_fonts) {
  "Helvetica"
} else {
  "sans"
}

# Parse command line arguments
args <- commandArgs(trailingOnly = TRUE)
config_file <- "config/example_analysis.yaml"  # Default config file

# Find --config argument
if (length(args) > 0) {
  config_idx <- grep("^--config", args)
  if (length(config_idx) > 0) {
    if (args[config_idx] == "--config" && length(args) > config_idx) {
      config_file <- args[config_idx + 1]
    } else if (grepl("^--config=", args[config_idx])) {
      config_file <- sub("^--config=", "", args[config_idx])
    }
  }
}

# Load config
if (!file.exists(config_file)) {
  stop(paste("Config file not found:", config_file))
}

config <- yaml::read_yaml(config_file)

# Source R script (before setwd so source() finds files relative to project root / /app in Docker)
cat(paste("STEPWISE_LOG:Starting Survival Analysis\n"), file = stderr())
source('Survival_TrainAUC_StepwiseSelection.R')
source('Save_Model.R')

# Get working directory
if (!is.null(config$workdir)) {
  setwd(config$workdir)
} else {
  setwd(".")
}

# Get survival config
if (is.null(config$survival)) {
  stop("Survival configuration not found in config file")
}

surv_config <- config$survival

# Load data
data_file <- ifelse(is.null(surv_config$data_file), 
                    ifelse(is.null(config$data_file), "Example_data.csv", config$data_file),
                    surv_config$data_file)

if (!file.exists(data_file)) {
  stop(paste("Data file not found:", data_file))
}

cat(paste("STEPWISE_LOG:Loading data from:", data_file, "\n"), file = stderr())
dat <- read.csv(data_file, header = TRUE, stringsAsFactors = FALSE)
cat(paste("STEPWISE_LOG:Data loaded -", nrow(dat), "samples,", ncol(dat), "columns\n"), file = stderr())

# Extract parameters from config
sample_id <- ifelse(is.null(surv_config$sample_id), "sample", surv_config$sample_id)
Survtime <- ifelse(is.null(surv_config$time_variable), "OS.year", surv_config$time_variable)
Event <- ifelse(is.null(surv_config$event), "OS", surv_config$event)
horizon <- ifelse(is.null(surv_config$horizon), 5, as.numeric(surv_config$horizon))
numSeed <- ifelse(is.null(surv_config$num_seed), 100, as.integer(surv_config$num_seed))
SplitProp <- ifelse(is.null(surv_config$split_prop), 0.7, as.numeric(surv_config$split_prop))
Freq <- ifelse(is.null(surv_config$freq), 80, as.integer(surv_config$freq))
output_dir <- ifelse(is.null(surv_config$output_dir), "results/survival", surv_config$output_dir)
max_candidates_per_step <- if (is.null(surv_config$max_candidates_per_step)) NULL else as.integer(surv_config$max_candidates_per_step)
prescreen_seeds <- if (is.null(surv_config$prescreen_seeds)) NULL else as.integer(surv_config$prescreen_seeds)

# New parameters for p-value adjustment and top-k selection
top_k <- if (is.null(surv_config$top_k)) NULL else as.integer(surv_config$top_k)
p_adjust_method <- if (is.null(surv_config$p_adjust_method)) "fdr" else surv_config$p_adjust_method
p_threshold <- if (is.null(surv_config$p_threshold)) 0.05 else as.numeric(surv_config$p_threshold)

# Handle exclude and include lists
excvar <- if (is.null(surv_config$exclude) || length(surv_config$exclude) == 0) c("") else surv_config$exclude
if (length(excvar) == 1 && excvar == "") {
  excvar <- c("")
}

fixvar <- if (is.null(surv_config$include) || length(surv_config$include) == 0) "" else surv_config$include
if (length(fixvar) == 0 || (length(fixvar) == 1 && fixvar == "")) {
  fixvar <- ""
}

# Get feature columns (exclude sample_id, Survtime, and Event)
exclude_cols <- c(sample_id, Survtime, Event)

# If features are specified in config, use those; otherwise use all columns except excluded ones
if (!is.null(surv_config$features) && length(surv_config$features) > 0) {
  totvar <- surv_config$features
  cat(paste("STEPWISE_LOG:Using", length(totvar), "specified features from config\n"), file = stderr())
} else {
  totvar <- colnames(dat)[-match(exclude_cols, colnames(dat), nomatch = 0)]
  cat(paste("STEPWISE_LOG:Using", length(totvar), "features (auto-selected from", ncol(dat), "total columns)\n"), file = stderr())
}

# Apply Open Targets evidence-based gene filtering if configured
if (!is.null(config$evidence) && !is.null(config$evidence$gene_file)) {
  evidence_file <- config$evidence$gene_file
  if (!file.exists(evidence_file)) {
    stop(paste("Evidence gene file not found:", evidence_file))
  }
  evidence_genes <- read.csv(evidence_file, header = TRUE, stringsAsFactors = FALSE)
  score_threshold <- ifelse(is.null(config$evidence$score_threshold), 0.0,
                            as.numeric(config$evidence$score_threshold))
  evidence_genes <- evidence_genes[evidence_genes$score >= score_threshold, ]
  evidence_symbols <- evidence_genes$gene_symbol
  filtered_totvar <- intersect(totvar, evidence_symbols)
  cat(paste("STEPWISE_LOG:Evidence filtering:", length(evidence_symbols),
            "evidence genes,", length(totvar), "data genes,",
            length(filtered_totvar), "intersection\n"), file = stderr())
  if (length(filtered_totvar) == 0) {
    stop("No genes remaining after evidence filtering.")
  }
  totvar <- filtered_totvar
}

# Create output directories
outcandir <- file.path(output_dir, "ExtCandidat")
outdir <- file.path(output_dir, "StepSurv")

dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
dir.create(outcandir, showWarnings = FALSE, recursive = TRUE)
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)

############################################################################
##### Extract candidate gene lists with Freq threshold
############################################################################
# Rename columns for consistency
colnames(dat) <- gsub(paste0("^", Event, "$"), "Event", 
                      gsub(paste0("^", Survtime, "$"), "Survtime", colnames(dat)), 
                      ignore.case = TRUE)

cat("STEPWISE_START\n", file = stderr())
cat(paste("STEPWISE_LOG:Starting candidate gene extraction...\n"), file = stderr())
cat(paste("STEPWISE_LOG:Total iterations:", numSeed, ", Variables:", length(totvar), ", Frequency threshold:", Freq, "\n"), file = stderr())
cat(paste("PROGRESS_START:", numSeed, "\n"), file = stderr())

# Extract candidate genes
Candivar <- Extract_CandidGene(dat, numSeed, SplitProp, totvar, outcandir, Freq, top_k, p_adjust_method, p_threshold)

cat(paste("STEPWISE_LOG:Candidate gene extraction completed -", length(Candivar), "candidate genes selected\n"), file = stderr())
# Candivar: Candidate gene lists for variable selection
############################################################################
if (length(Candivar) == 0) {
  cat("STEPWISE_LOG:No candidate genes found matching the criteria. Analysis cannot proceed.\n", file = stderr())
  cat("STEPWISE_LOG:Try relaxing the p-value threshold or frequency cutoff in the configuration.\n", file = stderr())
  quit(save = "no", status = 0)
}

#####################################################################
##### Run TrainAUC-based stepwise selection (Outcome: Survival time)
#####################################################################
cat(paste("STEPWISE_LOG:Starting stepwise selection with", length(Candivar), "candidate genes\n"), file = stderr())
if (!is.null(max_candidates_per_step) && !is.null(prescreen_seeds)) {
  cat(paste("STEPWISE_LOG:Pre-screening enabled - max candidates per step:", max_candidates_per_step, ", prescreen seeds:", prescreen_seeds, "\n"), file = stderr())
}
Result <- SurvTrainAUCStepwise(Candivar, dat, fixvar, excvar, horizon, numSeed, SplitProp, outdir, max_candidates_per_step, prescreen_seeds)

if (is.null(Result)) {
  cat("STEPWISE_LOG:Stepwise selection failed to select any variables.\n", file = stderr())
  quit(save = "no", status = 0)
}

cat(paste("STEPWISE_LOG:Stepwise selection completed\n"), file = stderr())

# Result: Final variable selection result eg. Variable / trainAUC / testAUC
#####################################################################

#####################################################################
##### Plot ROC curves and Variable Importance 
#####################################################################
cat(paste("STEPWISE_LOG:Generating plots...\n"), file = stderr())
# Change to output directory for saving plots
old_dir <- getwd()
setwd(output_dir)

# Helper to safely run plot functions
safe_plot <- function(expr, name) {
  tryCatch({
    expr
    cat(paste("STEPWISE_LOG:", name, "saved\n"), file = stderr())
  }, error = function(e) {
    cat(paste("STEPWISE_LOG:Warning -", name, "failed:", e$message, "\n"), file = stderr())
  })
}

safe_plot(PlotSurvROC(dat, numSeed, SplitProp, Result, horizon), "ROC curve plot")
safe_plot(PlotSurVarImp(dat, Result), "Variable importance plot")
safe_plot(PlotSurvKM(dat, numSeed, SplitProp, Result, horizon), "Kaplan-Meier plot")
safe_plot(PlotSurvTimeAUC(dat, numSeed, SplitProp, Result), "Time-dependent AUC plot")
safe_plot(PlotSurvRiskDist(dat, Result), "Risk distribution plots")
safe_plot(PlotSurvStepwiseProcess(outdir), "Stepwise process plot")

setwd(old_dir)  # Restore original directory

# Save model artifact for prediction use
safe_plot(
  SaveModelArtifact(dat, Result, "survival", output_dir, numSeed, SplitProp, config),
  "Model artifact"
)

cat(paste("STEPWISE_LOG:Analysis complete!\n"), file = stderr())
#####################################################################