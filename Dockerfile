FROM rocker/r-ver:4.4.2

LABEL maintainer="jyryu3161"
LABEL description="BioMarkerPred - Biomarker Prediction Platform"
LABEL version="0.4.0"
LABEL changelog="v0.4.0: Add model save and prediction features"

# System dependencies for R packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libtiff-dev \
    libpng-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    cmake \
    libglpk-dev \
    fontconfig fonts-liberation \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -fv

# Install CRAN packages from the Bioconductor-aligned repository set.
# This keeps ggplot2 and related packages compatible with Bioconductor 3.20.
RUN Rscript -e ' \
  install.packages("BiocManager", repos="https://cloud.r-project.org"); \
  options(repos = BiocManager::repositories()); \
  install.packages(c( \
    "yaml", "ggplot2", "caret", "ROCR", "pROC", "cutpointr", \
    "coefplot", "nsROC", "survival", "svglite", "tiff", \
    "reshape2", "gridExtra", "survminer", "pheatmap", \
    "httr", "jsonlite", "igraph", "tidygraph", "ggraph", "ggrepel", \
    "dplyr", "readr", "stringr", "tibble", "tidyr", \
    "lme4", "locfit", "zoo" \
  ), Ncpus=4) \
'

# Install Bioconductor core dependencies first (these must succeed before main packages)
RUN Rscript -e 'BiocManager::install(c("AnnotationDbi", "GO.db", "org.Hs.eg.db"), ask=FALSE, update=FALSE)'

# Install Bioconductor analysis packages (depend on core above)
RUN Rscript -e 'BiocManager::install(c("DOSE", "GOSemSim", "enrichplot", "ggtree"), ask=FALSE, update=FALSE)'

# Install main Bioconductor packages
RUN Rscript -e 'BiocManager::install(c("clusterProfiler", "ReactomePA"), ask=FALSE, update=FALSE)'

# Verify all installed
RUN Rscript -e 'for (p in c("clusterProfiler","enrichplot","org.Hs.eg.db","ReactomePA")) { if (!requireNamespace(p, quietly=TRUE)) stop(paste(p,"not installed")) }'

WORKDIR /app

COPY Main_Binary.R \
     Binary_TrainAUC_StepwiseSelection.R \
     Main_Survival.R \
     Survival_TrainAUC_StepwiseSelection.R \
     Save_Model.R \
     Predict_New.R \
     ORA_PPI_Analysis.R \
     ./

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["--help"]
