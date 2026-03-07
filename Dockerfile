FROM condaforge/mambaforge:latest AS builder

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

# Install Bioconductor packages separately (retry on transient failures)
RUN for i in 1 2 3; do \
      mamba install -y -c conda-forge -c bioconda \
        bioconductor-clusterprofiler \
        bioconductor-org.hs.eg.db \
        bioconductor-enrichplot \
        bioconductor-reactomepa \
      && break || echo "Retry $i..."; \
    done && mamba clean -afy

# Install remaining CRAN packages not in conda-forge
RUN R -e "install.packages(c('cutpointr','coefplot','tiff','nsROC','survminer'), repos='https://cloud.r-project.org', Ncpus=4)"

# Verify
COPY install_bioc.R /tmp/install_bioc.R
RUN Rscript /tmp/install_bioc.R && rm /tmp/install_bioc.R

# Install Arial font
RUN apt-get update && apt-get install -y --no-install-recommends \
    fontconfig fonts-liberation \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -fv

LABEL maintainer="jyryu3161"
LABEL description="BioMarkerPred - Biomarker Prediction Platform"
LABEL version="0.3.3"
LABEL changelog="v0.3.3: Add survival/prognosis analysis, fix nsROC dependency, rename to BioMarkerPred"

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
