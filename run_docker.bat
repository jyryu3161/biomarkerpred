@echo off
REM BioMarkerPred - Docker wrapper script for Windows
REM Usage: run_docker.bat binary --config=/work/config/analysis.yaml

docker run --rm -v "%cd%:/work" jyryu3161/biomarkerpred %*
