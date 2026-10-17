#!/usr/bin/env python3
"""Synthetic helper transport/process acceptance; no live API or patient data."""
import argparse
import csv
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import fetch_opentargets_genes as fetcher

RSCRIPT = ROOT / "tests/runtime/.pixi/envs/default/bin/Rscript"


def target(identifier, symbol, score):
    return {"target": {"id": identifier, "approvedSymbol": symbol}, "score": score}


def response(rows, count=3, name="Synthetic disease"):
    return {"data": {"disease": {"id": "MONDO_SYNTHETIC", "name": name,
            "associatedTargets": {"count": count, "rows": rows}}}}


ROWS = [target("ENSG1", "gene A", .9), target("ENSG2", "GENE-2", .1), target("ENSG3", "gene,quoted", .7)]


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bmp helpers , ")
        self.work = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def call(self, script, *args, ok=True, env=None, timeout=120):
        command = [str(ROOT / script), *map(str, args)] if script.endswith(".sh") else [sys.executable, str(ROOT / script), *map(str, args)]
        result = subprocess.run(command, cwd=self.work, env=env, text=True, capture_output=True, timeout=timeout)
        self.assertEqual(result.returncode == 0, ok, (command, result.returncode, result.stdout, result.stderr))
        return result

    def fetch(self, pages, directory="snapshot"):
        def transport(endpoint, body):
            variables = json.loads(body)["variables"]
            return json.dumps(pages[variables["index"]]).encode()
        return fetcher.fetch_snapshot("MONDO_SYNTHETIC", self.work / directory, page_size=2, transport=transport)

    def test_complete_snapshot_is_immutable_and_preserves_all_scores(self):
        first = self.fetch([response(ROWS[:2]), response(ROWS[2:])])
        original = Path(first["file_path"]).read_bytes()
        second = self.fetch([response(ROWS[:2]), response(ROWS[2:])])
        self.assertNotEqual(first["file_path"], second["file_path"])
        self.assertEqual(Path(first["file_path"]).read_bytes(), original)
        with Path(first["file_path"]).open(newline="") as stream:
            rows = list(csv.DictReader(stream))
        self.assertEqual([float(row["score"]) for row in rows], [.9, .1, .7])
        self.assertEqual(rows[-1]["gene_symbol"], "gene,quoted")
        provenance = first["provenance"]
        self.assertIsNone(provenance["release"])
        self.assertEqual(provenance["gene_count"], 3)
        self.assertEqual(provenance["csv_sha256"], hashlib.sha256(original).hexdigest())
        for page in provenance["pages"]:
            for kind in ("request", "response"):
                value = (Path(first["file_path"]).parent / page[f"{kind}_file"]).read_bytes()
                self.assertEqual(hashlib.sha256(value).hexdigest(), page[f"{kind}_sha256"])

    def test_bad_transport_never_publishes_partial_or_empty_success(self):
        invalid = [
            [response(ROWS[:1])],
            [response(ROWS[:2]), response(ROWS[2:], count=4)],
            [response([ROWS[0], ROWS[0]])],
            [response(ROWS[:2]), response([])],
            [response(ROWS[:2], count=1)],
            [response([target("ENSG1", "gene A", 1.2)], count=1)],
            [response([target("ENSG1", "gene A", True)], count=1)],
            [response([target("ENSG1", "", .5)], count=1)],
            [{"errors": [{"message": "synthetic API error"}], "data": {"disease": None}}],
            [{"data": {"disease": None}}],
            [response(ROWS[:2]), response(ROWS[2:], name="Changed disease")],
        ]
        for index, pages in enumerate(invalid):
            with self.subTest(index=index):
                with self.assertRaises(ValueError):
                    self.fetch(pages, str(index))
                self.assertEqual(list((self.work / str(index)).iterdir()), [])
        result = self.fetch([response([], count=0)], "verified-empty")
        self.assertTrue(result["ok"])
        self.assertEqual(result["gene_count"], 0)
        self.assertTrue(result["provenance"]["complete"])

    def test_old_drug_arguments_and_streamlit_fail_actionably(self):
        result = self.call("fetch_opentargets_genes.py", "--drugs", "a drug", ok=False)
        self.assertIn("membership", json.loads(result.stdout)["error"])
        result = self.call("generate_opentargets_configs.py", "--drugs", "a drug", ok=False)
        self.assertIn("--snapshot", json.loads(result.stdout)["error"])
        result = self.call("streamlit_app.py", ok=False)
        self.assertIn("retired", result.stderr)
        self.assertIn("validate", result.stderr)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_shared_engine_helpers_and_batch_from_other_directory(self):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append(body)
                if "SearchDiseases" in body["query"]:
                    value = {"data": {"search": {"hits": [{"id": "MONDO_SYNTHETIC", "name": "Synthetic disease", "description": None, "entity": "disease"}]}}}
                else:
                    index = body["variables"]["index"]
                    value = response(ROWS[:2] if index == 0 else ROWS[2:])
                raw = json.dumps(value).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
            def log_message(self, *_):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        endpoint = f"http://127.0.0.1:{server.server_port}/graphql"
        search = json.loads(self.call("fetch_opentargets_genes.py", "search", "--query", "synthetic", "--api-url", endpoint).stdout)
        self.assertEqual(search["hits"][0]["disease_id"], "MONDO_SYNTHETIC")
        snapshot = json.loads(self.call("fetch_opentargets_genes.py", "fetch", "--disease-id", "MONDO_SYNTHETIC", "--output-dir", self.work / "evidence", "--page-size", "2", "--api-url", endpoint).stdout)
        self.assertEqual(len(requests), 3)
        self.assertEqual(snapshot["gene_count"], 3)

        cohort = self.work / "cohort , literal.csv"
        shutil.copyfile(ROOT / "tests/fixtures/binary.csv", cohort)
        base = self.work / "base" / "config.json"
        generated = json.loads(self.call("generate_configs.py", "--data", cohort, "--output-config", base,
            "--output-dir", self.work / "runs root", "--analysis-type", "binary", "--rscript", RSCRIPT,
            "--group-column", "patient", "--clinical-column", "age", "--clinical-column", "sex",
            "--outer-folds", "3", "--inner-folds", "2", "--model", "stepwise", "--feature-set", "genes",
            "--panel-size", "1", "--max-features", "1", "--bootstrap-samples", "0", "--p-threshold", "1e-300").stdout)
        normalized = json.loads(base.read_text())
        self.assertEqual(normalized["data_file"], str(cohort))
        self.assertEqual(normalized["clinical_columns"], ["age", "sex"])
        self.assertEqual(json.loads(Path(generated["qc"]).read_text())["status"], "passed")
        self.assertFalse({"split_prop", "num_seed", "freq"}.intersection(normalized))

        # A base file's own directory, not the new file's directory, resolves input paths.
        normalized["data_file"] = "../" + cohort.name
        normalized["output_dir"] = "../runs root"
        base.write_text(json.dumps(normalized))
        attached = self.work / "different location" / "disease config.json"
        result = json.loads(self.call("generate_opentargets_configs.py", "--base-config", base,
            "--snapshot", snapshot["file_path"], "--output-config", attached, "--score-threshold", ".5", "--rscript", RSCRIPT).stdout)
        final = json.loads(attached.read_text())
        self.assertEqual(final["data_file"], str(cohort))
        self.assertEqual(Path(final["output_dir"]).resolve(), self.work / "runs root")
        self.assertEqual(final["evidence"]["disease_id"], "MONDO_SYNTHETIC")
        self.assertEqual(final["gene_columns"], ["gene A", "gene,quoted"])
        before = attached.read_bytes()
        self.call("generate_opentargets_configs.py", "--base-config", base, "--snapshot", snapshot["file_path"],
            "--output-config", attached, "--score-threshold", ".5", "--rscript", RSCRIPT, ok=False)
        self.assertEqual(attached.read_bytes(), before)
        env = dict(os.environ, BMP_RSCRIPT=str(RSCRIPT))
        batch = self.call("run_opentargets_binary.sh", attached, env=env, timeout=180)
        results = [json.loads(line) for line in batch.stdout.splitlines()]
        self.assertEqual(len(results), 2)
        run = Path(results[1]["run_dir"])
        manifest_bytes = (run / "manifest.json").read_bytes()
        manifest = json.loads(manifest_bytes)
        self.assertEqual(manifest["status"], "completed")
        self.assertEqual(manifest["provenance"]["evidence"]["sha256"], snapshot["provenance"]["csv_sha256"])
        self.call("run_opentargets.sh", self.work / "missing.json", env=env, ok=False)
        tampered = Path(snapshot["file_path"])
        tampered.write_bytes(tampered.read_bytes() + b"\n")
        rejected = self.call("generate_opentargets_configs.py", "--base-config", base, "--snapshot", tampered,
            "--output-config", self.work / "rejected.json", "--score-threshold", ".5", "--rscript", RSCRIPT, ok=False)
        self.assertIn("hash", json.loads(rejected.stdout)["error"])
        self.assertFalse((self.work / "rejected.json").exists())
        resume = subprocess.run([str(RSCRIPT), str(ROOT / "BiomarkerCLI.R"), "resume", "--run", str(run), "--json"],
                                cwd=self.work, text=True, capture_output=True, timeout=60)
        self.assertNotEqual(resume.returncode, 0)
        self.assertIn("incompatible", json.loads(resume.stdout)["error"])
        self.assertEqual((run / "manifest.json").read_bytes(), manifest_bytes)

    def test_workdir_semantics_and_invalid_config_are_not_silently_rewritten(self):
        snapshot = self.fetch([response(ROWS[:2]), response(ROWS[2:])])
        shutil.copyfile(ROOT / "tests/fixtures/binary.csv", self.work / "input.csv")
        config = json.loads((ROOT / "tests/fixtures/binary.json").read_text())
        config.update(workdir=".", data_file="input.csv", output_dir="retained output")
        base = self.work / "nested" / "base.json"
        base.parent.mkdir()
        base.write_text(json.dumps(config))
        output = self.work / "another" / "new.json"
        self.call("generate_opentargets_configs.py", "--base-config", base, "--snapshot", snapshot["file_path"],
            "--output-config", output, "--score-threshold", ".5", "--rscript", RSCRIPT)
        self.assertEqual(json.loads(output.read_text())["data_file"], str(self.work / "input.csv"))
        rejected = self.work / "invalid.json"
        result = self.call("generate_configs.py", "--data", self.work / "input.csv", "--output-config", rejected,
            "--output-dir", self.work / "invalid results", "--analysis-type", "binary", "--outcome", "absent", "--rscript", RSCRIPT, ok=False)
        self.assertFalse(rejected.exists())
        self.assertFalse((self.work / "invalid results").exists())
        self.assertEqual(json.loads(result.stdout)["details"]["qc"]["status"], "failed")

    def test_legacy_r_files_stop_before_loading_or_installing_packages(self):
        for name in ("Binary_TrainAUC_StepwiseSelection.R", "Survival_TrainAUC_StepwiseSelection.R", "Postprocess_Coexpression_Enrichment.R"):
            result = subprocess.run([str(RSCRIPT), str(ROOT / name)], cwd=self.work, text=True, capture_output=True, timeout=20)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("retired", result.stderr)
            self.assertNotIn("there is no package", result.stderr)
        self.assertEqual(list(self.work.iterdir()), [])

    def test_docker_wrapper_preserves_arguments_and_requires_inspected_image(self):
        docker = self.work / "fake docker"
        calls = self.work / "argv.jsonl"
        docker.write_text("#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ['BMP_ARGV_LOG'], 'a') as stream: stream.write(json.dumps(sys.argv[1:]) + '\\n')\nif sys.argv[1:3] == ['image', 'inspect']: print('sha256:' + 'a' * 64)\nelse: sys.exit(7)\n")
        docker.chmod(0o755)
        env = dict(os.environ, BMP_DOCKER_PATH=str(docker), BMP_ARGV_LOG=str(calls))
        env.pop("BMP_DOCKER_IMAGE", None)
        result = self.call("run_docker.sh", "validate", "--config", "/work/config with , space.json", "--json", env=env, ok=False)
        self.assertEqual(result.returncode, 7)
        recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        version = json.loads((ROOT / "gui/package.json").read_text())["version"]
        self.assertEqual(recorded[0], ["image", "inspect", "--format", "{{.Id}}", f"jyryu3161/biomarkerpred:v{version}"])
        command = recorded[1]
        self.assertEqual(command[command.index("--volume") + 1], str(self.work) + ":/work")
        self.assertEqual(command[command.index("--workdir") + 1], "/work")
        self.assertEqual(command[-4:], ["validate", "--config", "/work/config with , space.json", "--json"])
        self.assertEqual(command[command.index("--pull") + 1], "never")
        env["BMP_DOCKER_IMAGE"] = "biomarkerpred-engine:local"
        self.call("run_docker.sh", "doctor", "--json", env=env, ok=False)
        recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        self.assertEqual(recorded[-2][-1], "biomarkerpred-engine:local")

    def test_batch_checks_survive_python_optimization(self):
        executable = self.work / "fake Rscript"
        calls = self.work / "called.jsonl"
        executable.write_text("#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ['BMP_ARGV_LOG'], 'a') as stream: stream.write(json.dumps(sys.argv[1:]) + '\\n')\nprint(json.dumps({'ok': True, 'qc': {'status': 'passed'}, 'config': {'analysis_type': 'binary', 'evidence': None}}))\n")
        executable.chmod(0o755)
        env = dict(os.environ, BMP_RSCRIPT=str(executable), BMP_ARGV_LOG=str(calls), PYTHONOPTIMIZE="2")
        result = self.call("run_opentargets_binary.sh", "configuration with spaces.json", env=env, ok=False)
        self.assertIn("requires an explicit disease-evidence snapshot", result.stderr)
        recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        self.assertEqual(len(recorded), 1)
        self.assertEqual(recorded[0][1:], ["validate", "--config", "configuration with spaces.json", "--json"])

    def test_gui_launcher_uses_checkout_directory_and_locked_install(self):
        executables = self.work / "executables"
        executables.mkdir()
        calls = self.work / "gui commands.jsonl"
        for name, body in {
            "cargo": "#!/usr/bin/env bash\nexit 0\n",
            "rustc": "#!/usr/bin/env bash\nprintf '%s\\n' 'rustc 1.90.0 (synthetic)'\n",
            "node": "#!/usr/bin/env bash\nexit 0\n",
            "npm": "#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ['BMP_ARGV_LOG'], 'a') as stream: stream.write(json.dumps({'cwd': os.getcwd(), 'args': sys.argv[1:]}) + '\\n')\nsys.exit(0 if sys.argv[1:] == ['ci'] else 13)\n",
        }.items():
            path = executables / name
            path.write_text(body)
            path.chmod(0o755)
        env = dict(os.environ, PATH=str(executables) + os.pathsep + os.environ["PATH"], BMP_ARGV_LOG=str(calls))
        result = self.call("run_gui.sh", "--no-watch", env=env, ok=False)
        self.assertEqual(result.returncode, 13)
        recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        self.assertEqual(recorded, [{"cwd": str(ROOT / "gui"), "args": ["ci"]},
                                    {"cwd": str(ROOT / "gui"), "args": ["run", "tauri", "--", "dev", "--no-watch"]}])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rscript", type=Path, default=RSCRIPT)
    args, remaining = parser.parse_known_args()
    RSCRIPT = args.rscript.resolve()
    unittest.main(argv=[sys.argv[0], *remaining])
