FROM condaforge/mambaforge:latest AS builder

# Install system libraries needed for R package compilation
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev libssl-dev libxml2-dev libpng-dev \
    libtiff5-dev libfontconfig1-dev libfreetype6-dev \
    fontconfig fonts-liberation make gcc g++ \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -fv

# Install R + CRAN packages via conda
RUN mamba install -y -c conda-forge \
    r-base=4.3 \
    r-yaml r-ggplot2 r-caret r-rocr r-proc r-svglite \
    r-reshape2 r-gridextra r-pheatmap \
    r-httr r-jsonlite r-igraph r-tidygraph r-ggraph r-ggrepel \
    r-dplyr r-readr r-stringr r-tibble r-tidyr \
    r-survival r-lme4 \
    r-locfit r-zoo \
    && mamba clean -afy

# Install Bioconductor packages (conda first, BiocManager fallback)
RUN mamba install -y -c conda-forge -c bioconda \
        bioconductor-clusterprofiler \
        bioconductor-org.hs.eg.db \
        bioconductor-enrichplot \
        bioconductor-reactomepa \
    2>/dev/null \
    && mamba clean -afy \
    || ( \
        echo "Conda bioconda failed, falling back to BiocManager..." \
        && Rscript -e "install.packages('BiocManager', repos='https://cloud.r-project.org'); \
           BiocManager::install(c('clusterProfiler','enrichplot','org.Hs.eg.db','ReactomePA'), ask=FALSE, update=FALSE)" \
    )

# Install remaining CRAN packages not in conda-forge
RUN R -e "install.packages(c('cutpointr','coefplot','tiff','nsROC','survminer'), repos='https://cloud.r-project.org', Ncpus=4)"

# Verify all packages
COPY install_bioc.R /tmp/install_bioc.R
RUN Rscript /tmp/install_bioc.R && rm /tmp/install_bioc.R

LABEL maintainer="jyryu3161"
LABEL description="BioMarkerPred - Biomarker Prediction Platform"
LABEL version="0.4.0"
LABEL changelog="v0.4.0: Add model save and prediction features"

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
