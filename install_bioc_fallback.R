# Install missing Bioconductor packages via BiocManager
# Used as fallback when conda bioconda fails (e.g., on amd64)
pkgs <- c("clusterProfiler", "enrichplot", "org.Hs.eg.db", "ReactomePA")
missing <- pkgs[!sapply(pkgs, requireNamespace, quietly = TRUE)]

if (length(missing) == 0) {
  cat("All Bioconductor packages already installed via conda.\n")
  q(save = "no", status = 0)
}

cat("Missing packages:", paste(missing, collapse = ", "), "\n")
cat("Installing via BiocManager...\n")

if (!requireNamespace("BiocManager", quietly = TRUE)) {
  install.packages("BiocManager", repos = "https://cloud.r-project.org")
}
BiocManager::install(missing, ask = FALSE, update = FALSE, force = TRUE)

# Verify
still_missing <- missing[!sapply(missing, requireNamespace, quietly = TRUE)]
if (length(still_missing) > 0) {
  stop(paste("FATAL: Failed to install:", paste(still_missing, collapse = ", ")))
}
cat("All Bioconductor packages installed successfully.\n")
