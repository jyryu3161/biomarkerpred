# Verify Bioconductor packages (installed via conda in Dockerfile)
for (pkg in c("clusterProfiler", "enrichplot", "org.Hs.eg.db", "ReactomePA")) {
  if (!requireNamespace(pkg, quietly = TRUE))
    stop(sprintf("FATAL: %s not installed!", pkg))
}
cat("All Bioconductor packages OK.\n")
