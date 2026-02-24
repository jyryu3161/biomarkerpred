# RESPRED

**RESponse PREDiction** — Drug Response Biomarker Prediction Platform

AUC-driven stepwise variable selection for drug response biomarker discovery. Uses logistic regression with reproducible train/test splitting to identify gene signatures that predict drug responders vs non-responders.

## Features

- **Drug response prediction**: Logistic regression with ROC analysis
- **Stepwise selection**: Forward/backward variable selection optimizing AUC across multiple random seeds
- **Evidence-based filtering**: Open Targets Platform drug-target association integration
- **Publication-ready figures**: TIFF (300 DPI) and SVG outputs
- **Visualizations**: ROC curves, Waterfall plots, Volcano plots, Biomarker heatmaps, Variable importance, DCA, Confusion matrices
- **Desktop GUI**: Interactive analysis with real-time progress tracking
- **Cross-platform**: macOS, Windows, Linux via Docker

## Quick Start (GUI)

**Prerequisites**: [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running.

1. Download the installer from [Releases](https://github.com/jyryu3161/respred/releases)

| Platform | File |
|----------|------|
| macOS (Universal — Apple Silicon + Intel) | `.dmg` |
| Windows | `.msi` / `.exe` |
| Linux | `.deb` / `.AppImage` |

2. Install and launch the app
3. On first launch, the app checks for Docker Desktop
   - If Docker is not running, a download link is shown
   - If Docker is ready, click **"Download Analysis Image"** (one-time, ~1-2 GB)
4. Once the image is downloaded, the main analysis UI opens automatically

> No R, pixi, or any other dependencies needed. Docker handles everything.

## CLI Usage

### Docker (Recommended)

```bash
docker pull jyryu3161/respred

# Drug response prediction
docker run --rm -v $(pwd):/work jyryu3161/respred \
  binary --config=/work/config/example_analysis.yaml
```

Windows:
```bat
docker run --rm -v %cd%:/work jyryu3161/respred binary --config=/work/config/analysis.yaml
```

> When using Docker CLI, set paths relative to `/work/` in your config (e.g., `data_file: "/work/data/my_data.csv"`).

### Native (Advanced)

For users who prefer running R directly without Docker:

```bash
git clone https://github.com/jyryu3161/respred.git
cd respred
./install.sh   # installs pixi + R + packages

./run_analysis.sh binary --config config/example_analysis.yaml
```

## Configuration

Create a YAML config file (see `config/example_analysis.yaml`):

```yaml
workdir: "."

binary:
  data_file: data/my_data.csv
  sample_id: sample
  outcome: response
  split_prop: 0.7
  num_seed: 100
  output_dir: results/binary
  freq: 50
```

<details>
<summary>All parameters</summary>

| Parameter | Description | Default |
|-----------|-------------|---------|
| `num_seed` | Random seed iterations for stability | 100 |
| `split_prop` | Train/test split ratio | 0.7 |
| `freq` | Min frequency for candidate selection | 50 |
| `top_k` | Limit candidates to top K per iteration | NULL (all) |
| `p_adjust_method` | P-value correction: `"none"`, `"fdr"`, `"bonferroni"` | `"none"` |
| `p_threshold` | Significance threshold | 0.05 |
| `max_candidates_per_step` | Cap per forward step | NULL |
| `prescreen_seeds` | Seeds for pre-screening | NULL |
| `exclude` | Columns to exclude from analysis | `[]` |
| `include` | Columns to force-include | `[]` |

**Evidence-based filtering** (optional):
```yaml
evidence:
  gene_file: evidence_genes.csv
  score_threshold: 0.5
```

</details>

## Output

Results are saved in the configured `output_dir`:

```
output_dir/
├── figures/                    # All plots (SVG + TIFF)
│   ├── Binary_ROCcurve.*      # ROC curves (train + test)
│   ├── Binary_Variable_Importance.*
│   ├── Binary_Waterfall.*     # Prediction score waterfall
│   ├── Binary_Volcano.*       # Differential expression
│   ├── Binary_Heatmap.*       # Biomarker expression heatmap
│   ├── Binary_AUC_Boxplot.*
│   ├── Binary_Confusion_Matrix.*
│   ├── Binary_DCA.*
│   └── Binary_Stepwise_Process.*
├── StepBin/                   # Stepwise selection intermediates + final result
├── ExtBinCandidat/            # Per-seed univariate results
└── auc_iterations.csv         # AUC per seed
```

## Troubleshooting

- **macOS "damaged" or "unidentified developer" error**: The app is not Apple-signed.

  **Option 1** (recommended): Right-click the app → "Open" → Click "Open" in the dialog.

  **Option 2**: Remove quarantine flag:
  ```bash
  xattr -cr /Applications/RESPRED.app
  ```

  **Option 3**: System Settings → Privacy & Security → scroll to the blocked app → "Open Anyway"
- **"Docker Desktop Required" screen**: Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) and make sure it is running before launching the app.
- **Image download fails**: Check your internet connection. You can also pull manually: `docker pull jyryu3161/respred`
- **Analysis fails in Docker mode**: Check that the data file path and output directory are accessible. Docker needs permission to mount those directories.
- **Config errors**: Ensure column names in YAML match CSV headers exactly
- **Permission denied (CLI)**: `chmod +x install.sh run_analysis.sh run_gui.sh`

## Requirements

| Component | Requirement |
|-----------|-------------|
| **GUI** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) |
| **CLI (Docker)** | Docker |
| **CLI (Native)** | macOS/Linux/Windows, pixi (auto-installed via `install.sh`) |
| **GUI (Build from source)** | Node.js >= 18, Rust >= 1.70 |
