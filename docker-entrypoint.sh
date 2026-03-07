#!/bin/bash
set -e

case "$1" in
  binary)
    shift
    exec Rscript /app/Main_Binary.R "$@"
    ;;
  survival)
    shift
    exec Rscript /app/Main_Survival.R "$@"
    ;;
  ora)
    shift
    exec Rscript /app/ORA_PPI_Analysis.R "$@"
    ;;
  predict)
    shift
    exec Rscript /app/Predict_New.R "$@"
    ;;
  --help|"")
    echo "BioMarkerPred - Biomarker Prediction Platform"
    echo ""
    echo "Usage:"
    echo "  docker run --rm -v \$(pwd):/work jyryu3161/biomarkerpred binary --config=/work/config.yaml"
    echo "  docker run --rm -v \$(pwd):/output jyryu3161/biomarkerpred ora --genes='G1;G2' --output-dir=/output"
    echo ""
    echo "Commands:"
    echo "  binary     Run drug response prediction (logistic regression)"
    echo "  survival   Run prognosis/survival prediction (Cox regression)"
    echo "  ora        Run ORA pathway analysis with PPI integration"
    echo ""
    echo "Options:"
    echo "  --config=<path>  Path to YAML config file (binary mode)"
    echo "  --genes=<list>   Semicolon-separated gene symbols (ora mode)"
    echo "  --output-dir     Output directory for results"
    echo ""
    echo "Example:"
    echo "  docker run --rm -v \$(pwd):/work jyryu3161/biomarkerpred \\"
    echo "    binary --config=/work/config/example_analysis.yaml"
    ;;
  *)
    exec "$@"
    ;;
esac
