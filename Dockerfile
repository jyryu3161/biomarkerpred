# Preserve the exact published v0.4.2 Linux R/system runtime.
FROM jyryu3161/biomarkerpred@sha256:f865534ce6757662a6214339bf0710473bd377d0459b3df9ddad04c8bd30a7c6

LABEL maintainer="jyryu3161"
LABEL description="BioMarkerPred - Biomarker Prediction Platform"
LABEL version="0.4.3"
LABEL changelog="v0.4.2 maintenance: survival cutoff and unavailable AUC fixes"

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
