FROM rocker/r-ver:4.3.3

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
    fontconfig fonts-liberation \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -fv

# Install CRAN packages
RUN R -e "install.packages(c( \
    'yaml', 'ggplot2', 'caret', 'ROCR', 'pROC', 'cutpointr', \
    'coefplot', 'nsROC', 'survival', 'svglite', 'tiff', \
    'reshape2', 'gridExtra', 'survminer', 'pheatmap', \
    'httr', 'jsonlite', 'igraph', 'tidygraph', 'ggraph', 'ggrepel', \
    'dplyr', 'readr', 'stringr', 'tibble', 'tidyr', \
    'lme4', 'locfit', 'zoo', 'BiocManager' \
  ), repos='https://cloud.r-project.org', Ncpus=4)"

# Install Bioconductor deps that need more memory (one at a time)
RUN Rscript -e 'BiocManager::install("ggtree", ask=FALSE, update=FALSE, force=TRUE)' \
    && Rscript -e 'if (!requireNamespace("ggtree", quietly=TRUE)) stop("ggtree failed")'

RUN Rscript -e 'BiocManager::install("DOSE", ask=FALSE, update=FALSE, force=TRUE)' \
    && Rscript -e 'if (!requireNamespace("DOSE", quietly=TRUE)) stop("DOSE failed")'

# Install Bioconductor packages step by step with error checking
RUN Rscript -e ' \
  BiocManager::install("clusterProfiler", ask=FALSE, update=FALSE, force=TRUE); \
  if (!requireNamespace("clusterProfiler", quietly=TRUE)) stop("clusterProfiler failed")'

RUN Rscript -e ' \
  BiocManager::install("enrichplot", ask=FALSE, update=FALSE, force=TRUE); \
  if (!requireNamespace("enrichplot", quietly=TRUE)) stop("enrichplot failed")'

RUN Rscript -e ' \
  BiocManager::install("org.Hs.eg.db", ask=FALSE, update=FALSE, force=TRUE); \
  if (!requireNamespace("org.Hs.eg.db", quietly=TRUE)) stop("org.Hs.eg.db failed")'

RUN Rscript -e ' \
  BiocManager::install("ReactomePA", ask=FALSE, update=FALSE, force=TRUE); \
  if (!requireNamespace("ReactomePA", quietly=TRUE)) stop("ReactomePA failed")'

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
