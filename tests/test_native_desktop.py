#!/usr/bin/env python3
"""Installed Windows/Linux desktop smoke through real WebDriver and Tauri IPC (no mocks).

Start tauri-driver first (under Xvfb on Linux). The app must have its packaged engine;
--data-dir is the container-visible directory containing synthetic binary.csv
and identifiers.csv. See https://v2.tauri.app/develop/tests/webdriver/ .
"""
import argparse
import base64
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.request
import uuid


def review(args):
    def request(method, path, value=None):
        payload = None if value is None else json.dumps(value).encode()
        req = urllib.request.Request(args.webdriver_url.rstrip("/") + path, data=payload,
                                     method=method, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=150) as response:
                result = json.load(response)["value"]
        except urllib.error.HTTPError as error:
            raise AssertionError(error.read().decode()) from error
        if isinstance(result, dict) and "error" in result:
            raise AssertionError(result)
        return result

    created = request("POST", "/session", {"capabilities": {"alwaysMatch": {
        "tauri:options": {"application": args.application}}}})
    session = "/session/" + created["sessionId"]
    try:
        request("POST", session + "/timeouts", {"script": 120000, "implicit": 10000})

        def javascript(code, *values, asynchronous=False):
            return request("POST", session + ("/execute/async" if asynchronous else "/execute/sync"),
                           {"script": code, "args": list(values)})

        def invoke(command, values=None):
            result = javascript("""
                const command = arguments[0], values = arguments[1], done = arguments[2];
                window.__TAURI_INTERNALS__.invoke(command, values).then(
                    value => done({ok: true, value}), error => done({ok: false, error: String(error)}));
            """, command, values or {}, asynchronous=True)
            assert result["ok"], result
            return result["value"]

        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            title = javascript("return document.querySelector('h1')?.textContent || '';")
            if title:
                break
            time.sleep(.2)
        assert title == "Analysis setup", title
        settings = {"backend": "local", "rPath": args.rscript, "dockerPath": None,
                    "dockerImage": "biomarkerpred-engine:local", "outputRoot": args.data_dir + "/output"}
        invoke("engine_save_settings", {"settings": settings})
        schema = invoke("engine_schema")
        assert schema["$defs"]["analysis"]["properties"]["config_version"]["const"] == 1
        doctor = invoke("engine_call", {"request": {"operation": "doctor", "settings": settings}})
        assert doctor["success"], doctor
        engine_root = doctor["result"]["engine_root"]
        def native_path(value):
            # Windows canonicalize may use the extended-length prefix; R normalizes
            # drive separators. Compare OS paths, never assume identical spelling.
            value = value.replace("\\", "/")
            if value.startswith("//?/UNC/"):
                value = "//" + value[8:]
            elif value.startswith("//?/"):
                value = value[4:]
            return os.path.normcase(os.path.realpath(value))
        assert native_path(engine_root) == native_path(args.engine_root), (engine_root, args.engine_root)
        config = {"config_version": 1, "analysis_type": "binary", "data_file": args.data_dir + "/binary.csv",
                  "output_dir": args.data_dir + "/output", "sample_id": "sample", "group_column": "patient",
                  "outcome": "response", "clinical_columns": ["age", "sex"], "features": ["GENE-2"],
                  "models": ["stepwise"], "feature_sets": ["genes"], "outer_folds": 3,
                  "inner_folds": 2, "panel_sizes": [1], "max_features": 1,
                  "bootstrap_samples": 0, "p_threshold": 1e-300}
        validation = invoke("engine_call", {"request": {"operation": "validate", "config": config, "settings": settings}})
        assert validation["success"] and validation["result"]["qc"]["rows"] == 80
        print(f"Installed engine doctor, schema and QC passed: {engine_root}", flush=True)

        def operation(name, **body):
            job_id = str(uuid.uuid4())
            invoke("engine_start", {"jobId": job_id, "request": {"operation": name, "settings": settings, **body}})
            until = time.monotonic() + 120
            while time.monotonic() < until:
                snapshot = invoke("engine_job_status", {"jobId": job_id})
                if snapshot["phase"] == "finished":
                    assert snapshot["response"]["success"], snapshot
                    return snapshot["response"]["result"]
                time.sleep(.2)
            raise AssertionError(f"Native operation timed out: {name}, {job_id}")

        run = operation("analyze", config=config)
        record = invoke("engine_read_run", {"runDir": run["run_dir"]})
        assert record["manifest"]["status"] == "completed" and not record["verification_error"]
        model = invoke("model_load", {"path": run["paths"]["model"]})
        assert model["model"]["features"] == []
        prediction = operation("predict", options={"model": run["paths"]["model"],
                               "data": args.data_dir + "/identifiers.csv",
                               "output": args.data_dir + "/prediction.csv"})
        table = invoke("fs_read_csv", {"path": prediction["paths"]["predictions"]})
        assert "sample_id" in table["headers"]
        assert [row["sample_id"] for row in table["rows"]] == ["00001", "9007199254740993123"]
        print("Real native analysis, verified artifacts, null model and exact-ID prediction passed.", flush=True)
        if args.screenshot:
            args.screenshot.write_bytes(base64.b64decode(request("GET", session + "/screenshot")))
        print(f"Native desktop IPC passed: installed engine {engine_root}, QC, analysis, null model and exact-ID prediction.")
    finally:
        request("DELETE", session)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--webdriver-url", default="http://127.0.0.1:4444")
    parser.add_argument("--application", required=True)
    parser.add_argument("--rscript", required=True)
    parser.add_argument("--engine-root", required=True)
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--screenshot", type=Path)
    review(parser.parse_args())
