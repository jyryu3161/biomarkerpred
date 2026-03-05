#!/bin/bash
# BioMarkerPred - Docker wrapper script
# Usage: ./run_docker.sh binary --config=/work/config/analysis.yaml

docker run --rm -v "$(pwd):/work" jyryu3161/biomarkerpred "$@"
