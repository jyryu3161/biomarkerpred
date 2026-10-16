#!/usr/bin/env python3
"""Independent process review of evidence pagination and relocated configuration helpers."""
import argparse
import csv
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


class EvidenceHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        query = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        variables = query["variables"]
        if "search(" in query["query"]:
            value = {"search": {"hits": [{"id": "MONDO_SYNTHETIC", "name": "Synthetic condition",
                      "description": "Test only", "entity": "disease"}]}}
        else:
            assert set(variables) == {"id", "index", "size"}
            assert variables["id"] == "MONDO_SYNTHETIC" and variables["size"] == 1
            page = variables["index"]
            targets = [{"target": {"id": "ENSG_TEST_A", "approvedSymbol": "gene A"}, "score": .9},
                       {"target": {"id": "ENSG_TEST_B", "approvedSymbol": "GENE-2"}, "score": .2}]
            row = targets[0 if self.path == "/duplicate" else min(page, 1)]
            if self.path == "/nonfinite":
                row["score"] = float("nan")
            count = 3 if self.path == "/changing" and page else 2
            value = {"disease": {"id": "MONDO_SYNTHETIC", "name": "Synthetic condition",
                     "associatedTargets": {"count": count, "rows": [row]}}}
        payload = json.dumps({"data": value}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def review(rscript):
    server = ThreadingHTTPServer(("127.0.0.1", 0), EvidenceHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="bmp helpers parent ") as temporary:
            work = Path(temporary)
            endpoint = f"http://127.0.0.1:{server.server_port}"

            def call(script, *options, success=True):
                process = subprocess.run([sys.executable, str(ROOT / script), *map(str, options)],
                                         cwd=work, capture_output=True, text=True, timeout=60)
                value = json.loads(process.stdout)
                assert (process.returncode == 0) is success and value["ok"] is success, (value, process.stderr)
                return value

            hits = call("fetch_opentargets_genes.py", "search", "--query", "synthetic condition", "--api-url", endpoint + "/ok")
            assert hits["hits"][0]["disease_id"] == "MONDO_SYNTHETIC"
            snapshots = work / "evidence"
            common = ("fetch", "--disease-id", "MONDO_SYNTHETIC", "--page-size", "1", "--output-dir", snapshots)
            first = call("fetch_opentargets_genes.py", *common, "--api-url", endpoint + "/ok")
            genes = Path(first["file_path"])
            original = genes.read_bytes()
            metadata = json.loads(Path(first["metadata_path"]).read_text())
            assert metadata["gene_count"] == 2 and metadata["complete"] is True
            assert metadata["csv_sha256"] == hashlib.sha256(original).hexdigest()
            with genes.open(newline="") as stream:
                rows = list(csv.DictReader(stream))
            assert [row["gene_symbol"] for row in rows] == ["gene A", "GENE-2"]
            assert float(rows[1]["score"]) == .2, "Fetch must retain low-score associations."
            for page in metadata["pages"]:
                for kind in ("request", "response"):
                    assert hashlib.sha256((genes.parent / page[kind + "_file"]).read_bytes()).hexdigest() == page[kind + "_sha256"]
            second = call("fetch_opentargets_genes.py", *common, "--api-url", endpoint + "/ok")
            assert second["file_path"] != str(genes) and genes.read_bytes() == original
            before = set(snapshots.iterdir())
            for mode in ("duplicate", "changing", "nonfinite"):
                call("fetch_opentargets_genes.py", *common, "--api-url", endpoint + "/" + mode, success=False)
                assert set(snapshots.iterdir()) == before, "A failed fetch left a published or pending snapshot."
            old = call("fetch_opentargets_genes.py", "--drugs", "some-drug", success=False)
            assert "disease" in old["error"] and "membership" in old["error"]

            generated = work / "generated" / "analysis.json"
            base_args = ("--data", ROOT / "tests/fixtures/binary.csv", "--output-config", generated,
                         "--output-dir", work / "analysis output", "--analysis-type", "binary",
                         "--sample-id", "sample", "--outcome", "response", "--group-column", "patient",
                         "--clinical-column", "age", "--clinical-column", "sex", "--outer-folds", "3",
                         "--inner-folds", "2", "--rscript", rscript)
            result = call("generate_configs.py", *base_args)
            config_bytes = generated.read_bytes()
            assert json.loads(Path(result["qc"]).read_text())["status"] == "passed"
            call("generate_configs.py", *base_args, success=False)
            assert generated.read_bytes() == config_bytes

            base = json.loads((ROOT / "tests/fixtures/binary.json").read_text())
            base["data_file"] = os.path.relpath(ROOT / "tests/fixtures/binary.csv", work)
            base["output_dir"] = "preserved output"
            base_file = work / "relative base.json"
            base_file.write_text(json.dumps(base))
            attached = work / "moved" / "evidence.json"
            attach_args = ("--base-config", base_file, "--snapshot", genes.parent,
                           "--output-config", attached, "--score-threshold", ".5", "--rscript", rscript)
            attachment = call("generate_opentargets_configs.py", *attach_args)
            value = json.loads(attached.read_text())
            assert value["data_file"] == str(ROOT / "tests/fixtures/binary.csv")
            assert value["output_dir"] == str(work / "preserved output")
            assert value["evidence"]["disease_id"] == "MONDO_SYNTHETIC"
            qc = json.loads(Path(attachment["qc"]).read_text())
            assert qc["eligible_genes"] == ["gene A"] and "GENE-2" in qc["measured_genes"]
            genes.write_bytes(original + b"\n")
            call("generate_opentargets_configs.py", *attach_args, success=False)
            assert not (work / "preserved output").exists(), "Helpers must not fit scientific models."
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
    print("CLI helper process review passed: complete immutable evidence, failed-page rejection, exact filtering and relocated configuration paths.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rscript", type=Path, required=True)
    review(parser.parse_args().rscript.resolve())
