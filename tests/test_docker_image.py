#!/usr/bin/env python3
"""Exercise the installed image engine, mounting synthetic data only, never repo code."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def review(image, output):
    image_id = subprocess.check_output(
        ["docker", "image", "inspect", image, "--format", "{{.Id}}"], text=True).strip()
    output.mkdir(parents=True, exist_ok=False)
    prefix = ["docker", "run", "--rm", "--user", f"{os.getuid()}:{os.getgid()}",
              "--mount", f"type=bind,src={output},dst=/work", "--workdir", "/work",
              "--env", f"BMP_IMAGE_DIGEST={image_id}", image_id]
    counter = 0

    def call(*args, success=True):
        nonlocal counter
        counter += 1
        process = subprocess.run([*prefix, *map(str, args), "--json"],
                                 capture_output=True, text=True, timeout=180)
        (output / f"command-{counter:02d}.stderr").write_text(process.stderr, encoding="utf-8")
        value = json.loads(process.stdout)
        (output / f"command-{counter:02d}.json").write_text(
            json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")
        assert (process.returncode == 0) is success and value["ok"] is success, (value, process.stderr)
        return value

    def host(path):
        return output / Path(path).relative_to("/work")

    def verify(run):
        directory = host(run["run_dir"])
        manifest = json.loads((directory / "manifest.json").read_text())
        assert manifest["status"] == "completed"
        for name in manifest["required_artifacts"]:
            assert sha(directory / name) == manifest["artifact_verification"]["sha256"][name], name
        runtime_key = "evaluation_engine" if manifest.get("operation") == "evaluate" else "environment"
        assert manifest["provenance"][runtime_key]["docker_image_digest"] == image_id
        return directory, manifest

    doctor = call("doctor")
    assert doctor["engine_root"] != "/work" and doctor["interface_version"] == 1
    assert all(doctor["graphics"][name] for name in ("cairo", "png", "tiff"))
    assert not doctor["missing_packages"]
    call("version")
    ids = output / "identifiers only.csv"
    ids.write_text("sample,patient\n00001,patient001\n9007199254740993123,patient002\n", encoding="utf-8")
    expected_engine = {str(p.relative_to(ROOT)): sha(p) for p in
                       [*ROOT.glob("*.R"), *(ROOT / "R").glob("*.R"), ROOT / "config/schema.json"]}
    runs = []
    for kind in ("binary", "survival"):
        shutil.copy(ROOT / f"tests/fixtures/{kind}.csv", output / f"{kind}.csv")
        config = json.loads((ROOT / f"tests/fixtures/{kind}.json").read_text())
        config.update(data_file=f"/work/{kind}.csv", output_dir=f"/work/{kind} output",
                      models=["stepwise"], feature_sets=["genes"], features=["GENE-2"],
                      max_features=1, panel_sizes=[1], p_threshold=1e-300,
                      positive_label="반응군", negative_label="비반응군")
        config_path = output / f"{kind} config.json"
        config_path.write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")
        call("validate", "--config", f"/work/{config_path.name}")
        run = call("analyze", "--config", f"/work/{config_path.name}")
        directory, manifest = verify(run)
        assert manifest["provenance"]["engine"]["files"] == expected_engine, "Image engine differs from checkout."
        model_path = directory / "model.bmpmodel"
        model = json.loads(model_path.read_text())
        assert model["features"] == [], "This fixture must exercise a valid null model."
        model_hash = sha(model_path)
        prediction_options = ["predict", "--model", run["paths"]["model"],
                              "--data", "/work/identifiers only.csv", "--output", f"/work/{kind} predictions.csv"]
        if kind == "survival":
            mismatch = call(*prediction_options, "--time-unit", "days", success=False)
            assert "Time-unit mismatch" in mismatch["error"]
            prediction_options += ["--time-unit", "years"]
        prediction = call(*prediction_options)
        with host(prediction["paths"]["predictions"]).open(newline="") as stream:
            rows = list(csv.DictReader(stream))
        assert [row["sample_id"] for row in rows] == ["00001", "9007199254740993123"]
        evaluation_options = ["evaluate", "--model", run["paths"]["model"],
                              "--data", f"/work/{kind}.csv", "--output", f"/work/{kind} external",
                              "--bootstrap-samples", "0"]
        if kind == "survival":
            evaluation_options += ["--time-unit", "years"]
        external = call(*evaluation_options)
        verify(external)
        call("resume", "--run", external["run_dir"])
        call("resume", "--run", run["run_dir"])
        call("report", "--run", run["run_dir"])
        verify(run)
        assert sha(model_path) == model_hash, "Scoring/report/resume changed the frozen model."
        assert (directory / "report.pdf").read_bytes().startswith(b"%PDF")
        if shutil.which("pdftotext"):
            pdf_text = subprocess.check_output(["pdftotext", str(directory / "report.pdf"), "-"], text=True)
            assert run["run_id"] in pdf_text
            if kind == "binary":
                assert "반응군" in pdf_text, "Korean outcome label is missing from the searchable PDF."
        runs.append(run["run_dir"])
    call("compare", "--run", runs[0], "--run", runs[1])
    print(f"Installed Docker engine review passed: {image_id}; retained evidence: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="biomarkerpred-engine:local")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    destination = args.output or Path(tempfile.mkdtemp(prefix="bmp-image-parent-")) / "review"
    review(args.image, destination.resolve())
