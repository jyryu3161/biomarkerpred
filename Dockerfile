FROM rocker/r-ver:4.3.3

LABEL maintainer="jyryu3161"
LABEL description="RESPRED - RESponse PREDiction"

# System dependencies for R packages + Arial font
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
    fontconfig \
    fonts-liberation \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -fv

# Install R packages (using Ncpus=4 for parallel compilation)
RUN R -e "install.packages(c( \
    'yaml', 'ggplot2', 'caret', 'ROCR', 'pROC', 'cutpointr', \
    'coefplot', 'svglite', 'tiff', \
    'reshape2', 'gridExtra', 'pheatmap' \
  ), repos='https://cloud.r-project.org', Ncpus=4)"

# Bioconductor packages for pathway analysis (ORA + PPI)
RUN R -e "install.packages('BiocManager', repos='https://cloud.r-project.org')" && \
    R -e "BiocManager::install(c('clusterProfiler', 'org.Hs.eg.db', 'enrichplot', 'ReactomePA'), ask=FALSE, update=FALSE)"

# Additional CRAN packages for ORA/PPI
RUN R -e "install.packages(c( \
    'httr', 'jsonlite', 'igraph', 'tidygraph', 'ggraph', \
    'dplyr', 'readr', 'stringr', 'tibble' \
  ), repos='https://cloud.r-project.org', Ncpus=4)"

WORKDIR /app

# Copy R scripts
COPY Main_Binary.R \
     Binary_TrainAUC_StepwiseSelection.R \
     ORA_PPI_Analysis.R \
     ./

# Copy entrypoint
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["--help"]
