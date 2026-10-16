#!/usr/bin/env python3
"""Independent end-to-end CLI review; run after stage 3c is implemented.

Uses only Python's standard library and an installed Rscript. PDF text checks
also run when pdftotext is installed. Synthetic data and all output stay in a
temporary directory. No command is invoked through a shell.
"""

import argparse
import csv
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rscript", default=str(ROOT / "tests/runtime/.pixi/envs/default/bin/Rscript"))
    args = parser.parse_args()
    rscript = str(Path(args.rscript).resolve())
    cli = ROOT / "BiomarkerCLI.R"
    assert cli.is_file(), "CLI implementation is not present yet"

    with tempfile.TemporaryDirectory(prefix="bmp CLI review ") as temporary:
        work = Path(temporary)
        output = work / "results with spaces"

        def call(*command, success=True, script=cli):
            result = subprocess.run(
                [rscript, str(script), *map(str, command), "--json"],
                cwd=work, capture_output=True, text=True, timeout=300,
            )
            assert (result.returncode == 0) == success, (
                command, result.returncode, result.stdout, result.stderr
            )
            # json.loads rejects extra log lines or a second JSON object.
            value = json.loads(result.stdout)
            assert isinstance(value, dict), result.stdout
            for line in result.stderr.splitlines():
                if line.startswith("BMP_EVENT:"):
                    event = json.loads(line[len("BMP_EVENT:"):])
                    assert event.get("event"), event
            return value

        help_result = subprocess.run(
            [rscript, str(cli), "--help"], cwd=work,
            capture_output=True, text=True, timeout=20,
        )
        assert help_result.returncode == 0, help_result.stderr
        for command in ("validate", "analyze", "predict", "evaluate", "runs", "compare", "resume", "report"):
            assert command in help_result.stdout, command
        call("validate", "--unknown-option", "1", success=False)

        completed = []
        for kind in ("binary", "survival"):
            config = read_json(ROOT / "tests/fixtures" / f"{kind}.json")
            input_path = work / f"{kind} cohort ; literal.csv"
            shutil.copyfile(ROOT / "tests/fixtures" / f"{kind}.csv", input_path)
            config.update(data_file=str(input_path), output_dir=str(output),
                          models=["stepwise"], feature_sets=["clinical"], panel_sizes=[1])
            if kind == "binary":
                config.update(positive_label="반응 <review>", negative_label="비반응")
            config_path = work / f"{kind} config.json"
            config_path.write_text(json.dumps(config))
            validation = call("validate", "--config", config_path)
            assert validation.get("qc", {}).get("status") == "passed", validation
            before_runs = set((output / "runs").glob("*")) if (output / "runs").exists() else set()
            # Validate is read-only with respect to modeling run directories.
            call("validate", f"--config={config_path}")
            after_runs = set((output / "runs").glob("*")) if (output / "runs").exists() else set()
            assert before_runs == after_runs
            analyzed = call("analyze", "--config", config_path)
            run = Path(analyzed["run_dir"])
            manifest = read_json(run / "manifest.json")
            assert manifest["status"] == "completed", manifest
            assert run.parent == output / "runs", run
            assert manifest["run_id"] == run.name
            assert read_json(output / "latest.json")["run_dir"] == str(run)
            for relative in manifest["required_artifacts"]:
                artifact = run / relative
                assert artifact.is_file() and artifact.stat().st_size > 0, artifact
                assert manifest["artifact_verification"]["sha256"][relative] == sha(artifact)
            assert (run / "report.pdf").read_bytes().startswith(b"%PDF-"), "Invalid PDF header"
            html = (run / "report.html").read_text()
            assert run.name in html, "HTML report omitted run identity"
            if kind == "binary":
                assert "반응 &lt;review&gt;" in html and "반응 <review>" not in html
            if shutil.which("pdftotext"):
                pdf = subprocess.run(["pdftotext", str(run / "report.pdf"), "-"],
                                     capture_output=True, text=True, check=True).stdout
                assert run.name in pdf, "PDF report omitted run identity"
                if kind == "binary":
                    assert "반응 <review>" in pdf, "PDF lost outcome label or Unicode text"

            frozen = {name: sha(run / name) for name in ("model.bmpmodel", "predictions.csv", "splits.json")}
            call("resume", "--run", run)
            assert frozen == {name: sha(run / name) for name in frozen}, "Completed resume refit or changed predictions"
            call("report", "--run", run)
            assert frozen == {name: sha(run / name) for name in frozen}, "Report generation refit the model"
            assert read_json(run / "manifest.json")["status"] == "completed"

            with input_path.open(newline="") as handle:
                original_rows = list(csv.DictReader(handle))
            rows = original_rows[:4]
            outcome_columns = [config["outcome"]] if kind == "binary" else [config["event"], config["time_variable"]]
            fields = [name for name in rows[0] if name not in outcome_columns]
            for index, row in enumerate(rows):
                row["sample"] = "000000000000000000000" + str(index)
                row["patient"] = "external_" + row["patient"]
            prediction_input = work / f"{kind} without outcomes.csv"
            with prediction_input.open("w", newline="") as handle:
                writer = csv.DictWriter(handle, fields, extrasaction="ignore")
                writer.writeheader()
                writer.writerows(rows)
            prediction_output = work / f"{kind} frozen predictions.csv"
            call("predict", "--model", run / "model.bmpmodel", "--data", prediction_input,
                 "--output", prediction_output)
            with prediction_output.open(newline="") as handle:
                predictions = list(csv.DictReader(handle))
            assert [row["sample_id"] for row in predictions] == [row["sample"] for row in rows]
            # Overlapping output paths must not destroy the model or input.
            input_before = sha(prediction_input)
            call("predict", "--model", run / "model.bmpmodel", "--data", prediction_input,
                 "--output", run / "model.bmpmodel", success=False)
            call("predict", "--model", run / "model.bmpmodel", "--data", prediction_input,
                 "--output", prediction_input, success=False)
            assert input_before == sha(prediction_input)
            assert frozen["model.bmpmodel"] == sha(run / "model.bmpmodel")

            evaluation_input = work / f"{kind} external.csv"
            # Small external cohorts are valid even when nested CV is infeasible.
            # One-class/no-event metrics must remain unavailable with reasons.
            for row in rows:
                row[config["outcome"] if kind == "binary" else config["event"]] = "0"
            with evaluation_input.open("w", newline="") as handle:
                writer = csv.DictWriter(handle, list(rows[0]))
                writer.writeheader()
                writer.writerows(rows)
            extra = ["--time-unit", "years"] if kind == "survival" else []
            evaluated = call("evaluate", "--model", run / "model.bmpmodel", "--data", evaluation_input,
                             "--output", output, "--bootstrap-samples", "0", *extra)
            external_run = Path(evaluated["run_dir"])
            external_manifest = read_json(external_run / "manifest.json")
            assert external_manifest["status"] == "completed", external_manifest
            assert external_manifest["operation"] == "evaluate"
            assert sha(external_run / "model.bmpmodel") == frozen["model.bmpmodel"]
            metrics = read_json(external_run / "metrics.json")["primary"]["metrics"]
            unavailable = metrics["roc_auc" if kind == "binary" else "harrell_c"]
            assert unavailable["estimate"] is None and unavailable["reason"], unavailable
            assert frozen["model.bmpmodel"] == sha(run / "model.bmpmodel")
            completed.append(run)

            # A legitimate null model is still a deployable baseline. Empty
            # gene panels and unavailable calibration slopes must render.
            with input_path.open(newline="") as handle:
                null_rows = list(csv.DictReader(handle))
            for row in null_rows:
                row["constant for review"] = "1"
            null_data = work / f"{kind} null cohort.csv"
            with null_data.open("w", newline="") as handle:
                writer = csv.DictWriter(handle, list(null_rows[0]))
                writer.writeheader()
                writer.writerows(null_rows)
            null_config = dict(config, data_file=str(null_data), features=["constant for review"],
                               clinical_columns=[], feature_sets=["genes"])
            null_config_path = work / f"{kind} null config.json"
            null_config_path.write_text(json.dumps(null_config))
            null_result = call("analyze", "--config", null_config_path)
            null_run = Path(null_result["run_dir"])
            assert read_json(null_run / "manifest.json")["status"] == "completed"
            null_model = read_json(null_run / "model.bmpmodel")
            assert null_model["actual_gene_count"] == 0 and null_model["features"] == []

        history = call("runs", "--output", output)
        history_text = json.dumps(history)
        for run in completed:
            assert run.name in history_text
        comparison = call("compare", "--runs", ",".join(map(str, completed)))
        assert all(run.name in json.dumps(comparison) for run in completed)

        # Both legacy entrypoints must work from a different current directory.
        for kind, script in (("binary", "Main_Binary.R"), ("survival", "Main_Survival.R")):
            legacy = call("--config", work / f"{kind} config.json", script=ROOT / script)
            assert read_json(Path(legacy["run_dir"]) / "manifest.json")["status"] == "completed"

        invalid = read_json(work / "binary config.json")
        invalid["sample_id"] = "absent_identifier"
        invalid_path = work / "invalid config.json"
        invalid_path.write_text(json.dumps(invalid))
        failed = call("validate", "--config", invalid_path, success=False)
        assert "absent_identifier" in json.dumps(failed), failed
        print("Independent CLI review passed: binary/survival, reports, frozen prediction/evaluation, history, resume and legacy wrappers.")


if __name__ == "__main__":
    main()
