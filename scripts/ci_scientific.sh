#!/usr/bin/env bash
# Run the scientific contract against the exact installed root lockfile.
set -euo pipefail
bmp_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$bmp_root"
bmp_rscript="${BMP_RSCRIPT:-$bmp_root/.pixi/envs/default/bin/Rscript}"
"$bmp_rscript" BiomarkerCLI.R doctor --json
for bmp_test in tests/test_*.R; do
  "$bmp_rscript" "$bmp_test"
done
python tests/test_cli_review.py --rscript "$bmp_rscript"
python tests/test_pathway_cli_review.py --rscript "$bmp_rscript"
python tests/test_cli_helpers.py --rscript "$bmp_rscript"
python tests/test_helpers_review.py --rscript "$bmp_rscript"
python tests/test_validation_handoff.py --rscript "$bmp_rscript"
