#!/usr/bin/env python3
"""Independent one-object CLI checks for editable, failed configuration imports."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def review(rscript):
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="bmp-validation-handoff-") as temporary:
        folder = Path(temporary)
        config = json.loads((root / "tests/fixtures/binary.json").read_text())
        config["data_file"] = str(root / "tests/fixtures/binary.csv")
        config["output_dir"] = str(folder / "output")
        config["positive_class"] = "wrong outcome code"
        config["positive_label"] = "한글 반응군"
        path = folder / "invalid cohort config.json"
        path.write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")

        def invoke():
            result = subprocess.run(
                [str(rscript), str(root / "BiomarkerCLI.R"), "validate", "--config", str(path), "--json"],
                cwd=folder, text=True, capture_output=True, timeout=60)
            value = json.loads(result.stdout)
            assert result.returncode != 0 and value["ok"] is False, result
            return value

        value = invoke()
        normalized = value.get("config")
        assert isinstance(normalized, dict), "A normalized but QC-invalid import must remain editable."
        assert normalized["positive_class"] == "wrong outcome code"
        assert normalized["positive_label"] == "한글 반응군"
        assert normalized["data_file"] == config["data_file"]
        assert normalized["outer_folds"] == 3
        assert value["qc"]["status"] == "failed" and value["qc"]["errors"]
        assert not (folder / "output").exists(), "Validation must not create a scientific run."

        path.write_text('{"unfinished":', encoding="utf-8")
        failed_parse = invoke()
        assert failed_parse.get("config") is None
        assert failed_parse.get("error")
    print("Validation handoff passed: normalized failed QC, exact labels, one-object JSON and parse failure.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rscript", type=Path, required=True)
    review(parser.parse_args().rscript.resolve())
