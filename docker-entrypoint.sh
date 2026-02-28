#!/bin/bash
set -e

case "$1" in
  binary)
    shift
    exec Rscript /app/Main_Binary.R "$@"
    ;;
  ora)
    shift
    exec Rscript /app/ORA_PPI_Analysis.R "$@"
    ;;
  --help|"")
    echo "RESPRED - RESponse PREDiction"
    echo ""
    echo "Usage:"
    echo "  docker run --rm -v \$(pwd):/work jyryu3161/respred binary --config=/work/config.yaml"
    echo "  docker run --rm -v \$(pwd):/output jyryu3161/respred ora --genes='G1;G2' --output-dir=/output"
    echo ""
    echo "Commands:"
    echo "  binary     Run drug response prediction (logistic regression)"
    echo "  ora        Run ORA pathway analysis with PPI integration"
    echo ""
    echo "Options:"
    echo "  --config=<path>  Path to YAML config file (binary mode)"
    echo "  --genes=<list>   Semicolon-separated gene symbols (ora mode)"
    echo "  --output-dir     Output directory for results"
    echo ""
    echo "Example:"
    echo "  docker run --rm -v \$(pwd):/work jyryu3161/respred \\"
    echo "    binary --config=/work/config/example_analysis.yaml"
    ;;
  *)
    exec "$@"
    ;;
esac
