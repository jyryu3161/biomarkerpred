"""Test-only Tauri boundary for independent browser review.

Read-only requests and frozen prediction/evaluation use the real CLI; other
mutations return retained synthetic artifacts with controlled event timing. This is not a
native desktop or process-cancellation test (the Rust suite covers those).
"""
import asyncio
import base64
import csv
import hashlib
import json
from collections import deque
from pathlib import Path


INIT_SCRIPT = r"""
(() => {
  let serial = 0;
  const callbacks = new Map();
  const listeners = new Map();
  window.__BMP_TEST_EMIT = (event, payload) => {
    for (const [id, listener] of listeners) {
      if (listener.event === event) callbacks.get(listener.handler)?.({event, id, payload});
    }
  };
  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = {
    unregisterListener: (_event, id) => listeners.delete(id),
  };
  window.__TAURI_INTERNALS__ = {
    transformCallback(callback, once = false) {
      const id = ++serial;
      callbacks.set(id, (...args) => {
        if (once) callbacks.delete(id);
        return callback(...args);
      });
      return id;
    },
    unregisterCallback: id => callbacks.delete(id),
    convertFileSrc: path => path,
    async invoke(command, args = {}) {
      if (command === 'plugin:event|listen') {
        const id = ++serial;
        listeners.set(id, args);
        return id;
      }
      if (command === 'plugin:event|unlisten') {
        listeners.delete(args.eventId);
        return null;
      }
      return window.__BMP_TEST_INVOKE(command, args);
    },
  };
})();
"""


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def read_csv(path, limit=None):
    with Path(path).open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        rows = list(reader)
        return {"headers": reader.fieldnames, "rows": rows[:limit], "count": len(rows)}


def read_run(path):
    root = Path(path)
    manifest = read_json(root / "manifest.json")
    artifacts, errors, paths = {}, {}, {}
    names = ["config.json", "qc.json", "metrics.json", "summary.json", "universes.json",
             "annotation.json", "gsea.json", "graph.json", "gene_evidence.json",
             "figures/index.json", "stability.csv", "panel_comparison.csv",
             "model_comparison.csv", "ora_original.csv", "ora_expanded.csv", "gsea.csv"]
    for name in names:
        if (root / name).exists():
            artifacts[name] = read_csv(root / name) if name.endswith(".csv") else read_json(root / name)
    for name in manifest.get("required_artifacts", []):
        if (root / name).is_file():
            paths[name] = str(root / name)
        else:
            errors[name] = "Required artifact is missing"
    for name, digest in manifest.get("artifact_verification", {}).get("sha256", {}).items():
        file = root / name
        if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != digest:
            errors[name] = "Artifact checksum mismatch"
    return {"run_dir": str(root), "manifest": manifest, "artifacts": artifacts,
            "paths": paths, "verification_error": str(errors) if errors else None,
            "artifact_errors": errors}


def response(result, *, success=True, cancelled=False, code=0):
    return {"success": success, "cancelled": cancelled, "exitCode": code,
            "result": result, "verificationError": None, "stderrTail": []}


class DesktopBridge:
    def __init__(self, root, rscript, directory, development_run, survival_run, pathway_run):
        self.root = Path(root).resolve()
        self.rscript = Path(rscript).resolve()
        self.directory = Path(directory).resolve()
        self.development_run = Path(development_run).resolve()
        self.survival_run = Path(survival_run).resolve()
        self.pathway_run = Path(pathway_run).resolve()
        self.files, self.folders = deque(), deque()
        self.calls, self.opened, self.saved = [], [], []
        self.settings = {"backend": "local", "rPath": str(self.rscript), "dockerPath": None,
                         "dockerImage": "biomarkerpred-engine:local",
                         "outputRoot": str(self.development_run.parent.parent)}
        self.snapshots = {}
        self.active = None
        self.mutation_mode = "immediate"
        self.page = None

    async def attach(self, page):
        self.page = page
        await page.expose_binding("__BMP_TEST_INVOKE", self.invoke)
        await page.add_init_script(INIT_SCRIPT)

    async def emit(self, job_id, operation, kind, payload):
        if job_id in self.snapshots:
            self.snapshots[job_id]["lastEvent"] = {"type": kind, "payload": payload}
        await self.page.evaluate(
            "value => window.__BMP_TEST_EMIT('engine://event', value)",
            {"jobId": job_id, "operation": operation, "type": kind, "payload": payload},
        )

    async def cli(self, request):
        operation = request["operation"]
        options = dict(request.get("options", {}))
        if request.get("config") is not None:
            config = dict(request["config"])
            config.setdefault("workdir", str(self.root))
            path = self.directory / f"validation-{len(self.calls)}.json"
            path.write_text(json.dumps(config, ensure_ascii=False), encoding="utf-8")
            options["config"] = str(path)
        argv = [str(self.rscript), str(self.root / "BiomarkerCLI.R"), operation]
        for key, value in options.items():
            for item in value if isinstance(value, list) else [value]:
                argv.extend([f"--{key}", str(item)])
        argv.append("--json")
        process = await asyncio.create_subprocess_exec(
            *argv, cwd=self.root, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=120)
        result = json.loads(stdout)
        result_response = response(result, success=process.returncode == 0 and result.get("ok") is True,
                                   code=process.returncode)
        result_response["stderrTail"] = stderr.decode().splitlines()[-200:]
        return result_response

    def run_result(self, operation):
        root = self.pathway_run if operation == "ora" else self.development_run
        manifest = read_json(root / "manifest.json")
        result = {"ok": True, "operation": operation, "status": manifest["status"],
                  "run_id": manifest["run_id"], "run_dir": str(root), "paths": {}}
        for key in ["source_run_id", "source_run_dir", "analysis_type", "warnings", "components",
                    "validation", "cohort", "failed_folds"]:
            if key in manifest:
                result[key] = manifest[key]
        for key, name in {"manifest": "manifest.json", "config": "config.json", "qc": "qc.json",
                          "model": "model.bmpmodel", "predictions": "predictions.csv",
                          "metrics": "metrics.json", "report_html": "report.html",
                          "report_pdf": "report.pdf", "figures": "figures/index.json",
                          "summary": "summary.json", "ora_original": "ora_original.csv",
                          "ora_expanded": "ora_expanded.csv", "gsea": "gsea.json",
                          "graph": "graph.json", "evidence": "gene_evidence.json"}.items():
            if (root / name).exists():
                result["paths"][key] = str(root / name)
        if (root / "qc.json").exists():
            result["qc"] = read_json(root / "qc.json")
        return result

    async def finish(self, job_id, operation, result_response=None):
        result_response = result_response or response(self.run_result(operation))
        self.snapshots[job_id] = {"jobId": job_id, "operation": operation, "phase": "finished",
                                  "lastEvent": {"type": "complete", "payload": result_response},
                                  "response": result_response}
        self.active = None
        await self.emit(job_id, operation, "complete", result_response)

    async def invoke(self, _source, command, args):
        self.calls.append((command, args))
        if command == "engine_schema":
            return read_json(self.root / "config/schema.json")
        if command == "engine_get_settings":
            return self.settings
        if command == "engine_save_settings":
            self.settings = args["settings"]
            return self.settings
        if command == "engine_call":
            return await self.cli(args["request"])
        if command == "engine_read_run":
            return read_run(args["runDir"])
        if command == "engine_job_status":
            job_id = args.get("jobId") or self.active
            return self.snapshots.get(job_id)
        if command == "engine_start":
            assert self.active is None, "Frontend allowed a second mutation"
            job_id, operation = args["jobId"], args["request"]["operation"]
            self.active = job_id
            accepted = {"jobId": job_id, "operation": operation, "phase": "starting",
                        "lastEvent": None, "response": None}
            self.snapshots[job_id] = accepted
            await self.emit(job_id, operation, "accepted", {"phase": "starting"})
            if self.mutation_mode == "immediate":
                # Complete before the invoke promise resolves: a real desktop race.
                result_response = await self.cli(args["request"]) if operation in {"predict", "evaluate"} else None
                await self.finish(job_id, operation, result_response)
            else:
                self.snapshots[job_id] = dict(accepted, phase="running")
                await self.emit(job_id, operation, "started", {"backend": "local"})
            return accepted
        if command == "engine_cancel":
            job_id = args["jobId"]
            snapshot = self.snapshots[job_id]
            if self.mutation_mode == "unverified":
                result_response = response({"ok": False, "error": "[termination-unverified] Synthetic test diagnostic"},
                                           success=False, code=None)
                snapshot.update(phase="cancellation_unverified", response=result_response)
                await self.emit(job_id, snapshot["operation"], "cancellation_unverified", result_response)
            else:
                await self.finish(job_id, snapshot["operation"], response(
                    {"ok": False, "status": "cancelled", "error": "Cancelled synthetic job"},
                    success=False, cancelled=True, code=None))
            return self.snapshots[job_id]
        if command == "fs_pick_file":
            return str(self.files.popleft()) if self.files else None
        if command == "fs_pick_directory":
            return str(self.folders.popleft()) if self.folders else None
        if command == "fs_read_csv_header":
            table = read_csv(args["path"], 5)
            return {"path": args["path"], "rowCount": table["count"], "columns": table["headers"],
                    "preview": {key: [row[key] for row in table["rows"]] for key in table["headers"]}}
        if command == "fs_read_csv":
            return read_csv(args["path"], args.get("limit"))
        if command == "fs_read_text_file":
            return Path(args["path"]).read_text(encoding="utf-8")
        if command == "fs_read_image":
            return base64.b64encode(Path(args["path"]).read_bytes()).decode()
        if command == "fs_open_directory":
            self.opened.append(args["path"])
            return None
        if command == "fs_save_file":
            assert Path(args["sourcePath"]).is_file()
            self.saved.append(args["sourcePath"])
            return str(self.directory / args["defaultName"])
        if command == "model_load":
            path = Path(args["path"])
            return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "model": read_json(path), "metrics": None,
                    "metrics_reason": "Performance belongs to a verified run, not a portable model."}
        if command == "prediction_read_results":
            path = Path(args["outputDir"])
            return read_csv(path if path.is_file() else path / "predictions.csv")
        if command == "opentargets_list_cached" or command == "config_list_presets":
            return []
        raise AssertionError(f"Unexpected desktop command: {command} {args}")
