#!/usr/bin/env python3
"""Create one validated shared-engine configuration from explicit cohort roles.

Defaults and validation come from BiomarkerCLI.R and config/schema.json. Paths
are saved as absolute paths so moving the generated JSON cannot change inputs.
No model is fitted. Existing configuration/QC files are never overwritten.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent


class HelperError(ValueError):
    def __init__(self, message, details=None):
        super().__init__(message)
        self.details = details


def validate_config(path, rscript=None):
    if rscript:
        command = [str(Path(rscript).expanduser().resolve()), str(ROOT / "BiomarkerCLI.R")]
    else:
        command = [str(ROOT / "run_analysis.sh")]
    result = subprocess.run(command + ["validate", "--config", str(Path(path).resolve()), "--json"],
                            capture_output=True, text=True, timeout=300)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    try:
        value = json.loads(result.stdout)
    except (ValueError, TypeError) as error:
        raise HelperError(f"Shared CLI validation did not return one JSON object (exit {result.returncode})") from error
    if result.returncode != 0 or not isinstance(value, dict) or value.get("ok") is not True:
        raise HelperError("Shared-engine validation failed; no configuration was published", value)
    if not isinstance(value.get("config"), dict) or value.get("qc", {}).get("status") != "passed":
        raise HelperError("Shared CLI did not return a normalized configuration and passed QC", value)
    return value


def validate_object(config, rscript=None):
    with tempfile.TemporaryDirectory(prefix="bmp-config-") as temporary:
        path = Path(temporary) / "requested.json"
        path.write_text(json.dumps(config, ensure_ascii=False, allow_nan=False), encoding="utf-8")
        result = validate_config(path, rscript)
    # The temporary request file is not the persistent source configuration.
    result["config"].pop("source_config", None)
    return result


def publish_json(path, value):
    """Atomically install a new file without replacing an existing path."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".config-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, allow_nan=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)
    finally:
        os.unlink(temporary)


def save_validated(output_path, value):
    path = Path(output_path).expanduser().absolute()
    qc_path = path.with_name(path.name + ".qc.json")
    if path.exists() or path.is_symlink() or qc_path.exists() or qc_path.is_symlink():
        raise HelperError("Output config or QC path already exists; select a new output-config path")
    publish_json(path, value["config"])
    try:
        publish_json(qc_path, value["qc"])
    except OSError:
        path.unlink()
        raise
    return {"ok": True, "config": str(path), "qc": str(qc_path), "status": "validated",
            "next_command": [str(ROOT / "run_analysis.sh"), "analyze", "--config", str(path), "--json"]}


def emit_failure(error):
    print(json.dumps({"ok": False, "error": str(error), "details": getattr(error, "details", None)}, ensure_ascii=False))
    return 1


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True, help="Input CSV")
    parser.add_argument("--output-config", type=Path, required=True, help="New JSON configuration path")
    parser.add_argument("--output-dir", type=Path, required=True, help="Root for unique scientific run directories")
    parser.add_argument("--analysis-type", choices=("binary", "survival"), required=True)
    parser.add_argument("--rscript", help="Rscript executable path; otherwise use BMP_RSCRIPT/project launcher")
    for key in ("sample_id", "group_column", "outcome", "positive_class", "negative_class", "positive_label", "negative_label", "event", "time_variable", "time_unit"):
        parser.add_argument("--" + key.replace("_", "-"))
    for key in ("outer_folds", "inner_folds", "repeats", "seed", "workers", "max_features", "top_k", "max_candidates_per_step", "bootstrap_samples"):
        parser.add_argument("--" + key.replace("_", "-"), type=int)
    for key in ("horizon", "selection_frequency", "missing_threshold", "p_threshold"):
        parser.add_argument("--" + key.replace("_", "-"), type=float)
    for flag, key, value_type in (("clinical-column", "clinical_columns", str), ("feature", "features", str),
            ("include", "include", str), ("exclude", "exclude", str), ("model", "models", str),
            ("feature-set", "feature_sets", str), ("panel-size", "panel_sizes", int), ("alpha", "alpha_grid", float)):
        parser.add_argument("--" + flag, dest=key, type=value_type, action="append", help="Repeat for multiple values; column names are literal")
    args = parser.parse_args(argv)
    try:
        config = {key: value for key, value in vars(args).items() if value is not None and key not in {"data", "output_config", "output_dir", "rscript"}}
        config.update(data_file=str(args.data.expanduser().resolve(strict=True)), output_dir=str(args.output_dir.expanduser().resolve()))
        value = validate_object(config, args.rscript)
        result = save_validated(args.output_config, value)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        return emit_failure(error)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
