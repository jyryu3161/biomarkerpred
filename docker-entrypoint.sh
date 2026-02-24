#!/bin/bash
set -e

case "$1" in
  binary)
    shift
    exec Rscript /app/Main_Binary.R "$@"
    ;;
  --help|"")
    echo "RESPRED - RESponse PREDiction"
    echo ""
    echo "Usage:"
    echo "  docker run --rm -v \$(pwd):/work jyryu3161/respred binary --config=/work/config.yaml"
    echo ""
    echo "Commands:"
    echo "  binary     Run drug response prediction (logistic regression)"
    echo ""
    echo "Options:"
    echo "  --config=<path>  Path to YAML config file (use /work/ prefix for mounted files)"
    echo ""
    echo "Example:"
    echo "  docker run --rm -v \$(pwd):/work jyryu3161/respred \\"
    echo "    binary --config=/work/config/example_analysis.yaml"
    ;;
  *)
    exec "$@"
    ;;
esac
