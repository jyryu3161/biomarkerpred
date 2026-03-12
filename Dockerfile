FROM condaforge/mambaforge:latest AS builder

# System deps for font rendering and source package compilation
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update && apt-get install -y --no-install-recommends \
    fontconfig fonts-liberation \
    zlib1g-dev libcurl4-openssl-dev libssl-dev libxml2-dev libpng-dev libtiff5-dev \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -fv

# Install R + CRAN packages via conda
RUN mamba install -y -c conda-forge \
    r-base \
    r-yaml r-ggplot2 r-caret r-rocr r-proc r-svglite \
    r-reshape2 r-gridextra r-pheatmap \
    r-httr r-jsonlite r-igraph r-tidygraph r-ggraph r-ggrepel \
    r-dplyr r-readr r-stringr r-tibble r-tidyr \
    r-survival r-lme4 \
    r-locfit r-zoo \
    r-rcurl r-png r-tiff r-biocmanager \
    r-rsqlite r-dbi r-dbplyr \
    && mamba clean -afy

# Install AnnotationDbi and core Bioconductor deps via conda
# (these are required by clusterProfiler but fail to compile from source in conda env)
RUN mamba install -y -c conda-forge -c bioconda \
        bioconductor-annotationdbi \
        bioconductor-biobase \
        bioconductor-biocgenerics \
        bioconductor-iranges \
        bioconductor-s4vectors \
        bioconductor-go.db \
    && mamba clean -afy \
    || echo "WARN: some bioconductor core deps failed via conda"

# Try installing Bioconductor packages via conda (may fail on some archs)
RUN mamba install -y -c conda-forge -c bioconda \
        bioconductor-clusterprofiler \
        bioconductor-org.hs.eg.db \
        bioconductor-enrichplot \
        bioconductor-reactomepa \
    && mamba clean -afy \
    || echo "WARN: conda bioconda install failed, will use BiocManager fallback"

# Fallback: install any missing Bioconductor packages via BiocManager
COPY install_bioc_fallback.R /tmp/install_bioc_fallback.R
RUN Rscript /tmp/install_bioc_fallback.R

# Install remaining CRAN packages not available in conda-forge
RUN R -e "install.packages(c('cutpointr','coefplot','nsROC','survminer'), repos='https://cloud.r-project.org', Ncpus=4)"

# Verify all critical packages
COPY install_bioc.R /tmp/install_bioc.R
RUN Rscript /tmp/install_bioc.R && rm /tmp/install_bioc.R /tmp/install_bioc_fallback.R

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
