#!/usr/bin/env python3
"""Review a staged desktop engine's completeness and execution away from the repo.

The packager supplies --engine-root; this test does not assemble its own bundle.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def engine_files(root):
    paths = [*root.glob("*.R"), *(root / "R").glob("*.R"), root / "config/schema.json"]
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine-root", type=Path, required=True)
    parser.add_argument("--rscript", type=Path, required=True)
    args = parser.parse_args()
    staged = args.engine_root.resolve()
    assert staged != ROOT, "Pass staged resource files, not the source checkout."
    expected, actual = engine_files(ROOT), engine_files(staged)
    assert expected == actual, {
        "missing": sorted(expected.keys() - actual.keys()),
        "extra": sorted(actual.keys() - expected.keys()),
        "different": sorted(key for key in expected.keys() & actual.keys()
                            if expected[key] != actual[key]),
    }
    with tempfile.TemporaryDirectory(prefix="bmp resource execution ") as directory:
        work = Path(directory)
        environment = os.environ.copy()
        environment.pop("BMP_ENGINE_ROOT", None)

        def call(*options):
            result = subprocess.run(
                [str(args.rscript.resolve()), str(staged / "BiomarkerCLI.R"),
                 *map(str, options), "--json"],
                cwd=work, env=environment, capture_output=True, text=True, timeout=60,
            )
            payload = json.loads(result.stdout)
            assert result.returncode == 0 and payload["ok"], (payload, result.stderr)
            return payload

        doctor = call("doctor")
        assert Path(doctor["engine_root"]).resolve() == staged
        assert Path(doctor["schema"]).resolve() == staged / "config/schema.json"
        assert all(doctor[key] == 1 for key in ("interface_version", "config_version", "model_version"))
        assert doctor["graphics"]["cairo"] and not doctor["missing_packages"]

        # Data paths are explicit and independent of both engine and working directories.
        config = json.loads((ROOT / "tests/fixtures/binary.json").read_text())
        config.update(data_file=str(ROOT / "tests/fixtures/binary.csv"),
                      output_dir=str(work / "output"))
        config_path = work / "analysis config.json"
        config_path.write_text(json.dumps(config))
        result = call("validate", "--config", config_path)
        assert result["status"] == "validated" and not result["qc"]["errors"]
        assert "gene,quoted" in result["qc"]["measured_genes"]
        assert result["config"]["group_column"] == "patient"
        assert result["config"]["data_file"] == config["data_file"]
    print(f"Staged engine review passed: {len(actual)} matching code/schema files, doctor and QC from unrelated cwd.")


if __name__ == "__main__":
    main()
