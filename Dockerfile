FROM condaforge/mambaforge:latest AS builder

# Install R + all packages via conda (pre-compiled, no version conflicts)
RUN mamba install -y -c conda-forge -c bioconda \
    r-base=4.3 \
    r-yaml r-ggplot2 r-caret r-rocr r-proc r-svglite \
    r-reshape2 r-gridextra r-pheatmap \
    r-httr r-jsonlite r-igraph r-tidygraph r-ggraph r-ggrepel \
    r-dplyr r-readr r-stringr r-tibble r-tidyr \
    bioconductor-clusterprofiler \
    bioconductor-org.hs.eg.db \
    bioconductor-enrichplot \
    bioconductor-reactomepa \
    && mamba clean -afy

# Install remaining CRAN packages not in conda-forge
RUN R -e "install.packages(c('cutpointr','coefplot','tiff'), repos='https://cloud.r-project.org', Ncpus=4)"

# Verify
COPY install_bioc.R /tmp/install_bioc.R
RUN Rscript /tmp/install_bioc.R && rm /tmp/install_bioc.R

# Install Arial font
RUN apt-get update && apt-get install -y --no-install-recommends \
    fontconfig fonts-liberation \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -fv

LABEL maintainer="jyryu3161"
LABEL description="RESPRED - RESponse PREDiction"
LABEL version="0.3.0"
LABEL changelog="v0.3.0: Add ORA pathway analysis with PPI integration (clusterProfiler, ReactomePA, STRING DB)"

WORKDIR /app

COPY Main_Binary.R \
     Binary_TrainAUC_StepwiseSelection.R \
     ORA_PPI_Analysis.R \
     ./

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["--help"]
