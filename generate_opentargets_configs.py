#!/usr/bin/env python3
"""Attach an explicitly selected immutable disease snapshot to a base config.

The shared R CLI normalizes the original base file before it moves, preserving
its workdir/config-directory path semantics. This command neither selects a
disease from a drug name nor interprets association scores as response evidence.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

from generate_configs import HelperError, emit_failure, save_validated, validate_config, validate_object
from fetch_opentargets_genes import MIGRATION, disease_identifier


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_snapshot(path):
    path = Path(path).expanduser().resolve(strict=True)
    directory = path if path.is_dir() else path.parent
    csv_path = directory / "genes.csv" if path.is_dir() else path
    metadata_path = directory / "metadata.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    if not isinstance(metadata, dict) or metadata.get("source") != "Open Targets Platform":
        raise HelperError("Snapshot metadata must identify Open Targets Platform")
    if not metadata.get("csv_sha256") or digest(csv_path) != metadata["csv_sha256"]:
        raise HelperError("Snapshot CSV hash differs from its immutable metadata")
    disease_id = disease_identifier(metadata.get("disease_id", metadata.get("efo_id")))
    if not isinstance(metadata.get("disease_name"), str) or not metadata["disease_name"].strip():
        raise HelperError("Snapshot metadata has no disease name")
    if metadata.get("complete") is False:
        raise HelperError("A partial evidence snapshot cannot be attached")
    count = metadata.get("gene_count")
    if type(count) is not int or count < 0 or metadata.get("query_variables", {}).get("expected_count") != count:
        raise HelperError("Snapshot lacks a verified full target count")
    identifiers = set()
    with csv_path.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        if not {"gene_symbol", "ensembl_id", "score"}.issubset(reader.fieldnames or []):
            raise HelperError("Snapshot CSV requires gene_symbol, ensembl_id and score")
        for row in reader:
            if not row["ensembl_id"] or not row["gene_symbol"] or row["ensembl_id"] in identifiers:
                raise HelperError("Snapshot has duplicate or missing target identifiers")
            identifiers.add(row["ensembl_id"])
            score = float(row["score"])
            if not math.isfinite(score) or not 0 <= score <= 1:
                raise HelperError("Snapshot scores must be finite numbers between 0 and 1")
    if len(identifiers) != count:
        raise HelperError("Snapshot CSV count differs from metadata")
    for page in metadata.get("pages", []):
        for kind in ("request", "response"):
            target = (directory / page[f"{kind}_file"]).resolve(strict=True)
            if not target.is_relative_to(directory) or digest(target) != page[f"{kind}_sha256"]:
                raise HelperError("Snapshot request/response provenance is missing, outside the snapshot, or changed")
    return csv_path, metadata_path, disease_id, metadata


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if any(value.split("=", 1)[0] in {"--drugs", "--mapping-file", "--evidence-dir", "--config-dir"} for value in argv):
        return emit_failure(HelperError(MIGRATION + " Use --base-config PATH --snapshot DIRECTORY --output-config PATH --score-threshold NUMBER."))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-config", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path, required=True, help="Snapshot directory or its genes.csv (metadata.json is required)")
    parser.add_argument("--output-config", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, help="Optional separate scientific run root; otherwise retain the base output path")
    parser.add_argument("--score-threshold", type=float, required=True, help="Prespecified disease association threshold in [0,1]")
    parser.add_argument("--rscript", help="Rscript executable path; otherwise use BMP_RSCRIPT/project launcher")
    args = parser.parse_args(argv)
    try:
        if not math.isfinite(args.score_threshold) or not 0 <= args.score_threshold <= 1:
            raise HelperError("score-threshold must be a finite number between 0 and 1")
        csv_path, metadata_path, disease_id, metadata = read_snapshot(args.snapshot)
        config = validate_config(args.base_config, args.rscript)["config"]
        config.pop("source_config", None)
        config["evidence"] = {"gene_file": str(csv_path), "score_threshold": args.score_threshold,
            "source": metadata["source"], "disease_id": disease_id, "efo_id": disease_id,
            "disease_name": metadata["disease_name"], "retrieved_at": metadata.get("fetched_at"),
            "snapshot_metadata": metadata, "metadata_file": str(metadata_path), "metadata_sha256": digest(metadata_path)}
        if args.output_dir is not None:
            config["output_dir"] = str(args.output_dir.expanduser().resolve())
        value = validate_object(config, args.rscript)
        # Guard against a concurrently replaced snapshot during normalization/QC.
        if digest(csv_path) != metadata["csv_sha256"] or digest(metadata_path) != config["evidence"]["metadata_sha256"]:
            raise HelperError("Evidence snapshot changed during configuration generation")
        result = save_validated(args.output_config, value)
        result["disease_id"] = disease_id
    except (ValueError, OSError, TypeError, KeyError, subprocess.SubprocessError) as error:
        return emit_failure(error)
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
