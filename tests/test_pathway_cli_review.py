#!/usr/bin/env python3
"""Independent, offline process-level pathway acceptance using real run artifacts."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads(Path(path).read_text())


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def review(work, rscript):
    work.mkdir(parents=True, exist_ok=True)

    def call(*args, success=True, script="BiomarkerCLI.R"):
        process = subprocess.run([str(rscript), str(ROOT / script), *map(str, args), "--json"],
                                 cwd=work, capture_output=True, text=True, timeout=180)
        try:
            result = json.loads(process.stdout)
        except json.JSONDecodeError:
            raise AssertionError((process.stdout, process.stderr))
        assert (process.returncode == 0) == success, (result, process.stderr)
        assert result["ok"] == success, result
        return result

    config = read(ROOT / "tests/fixtures/binary.json")
    config.update(data_file=str(ROOT / "tests/fixtures/binary.csv"), output_dir=str(work / "results"),
                  models=["stepwise"], feature_sets=["genes"], include=["gene A", "gene,quoted"],
                  panel_sizes=[2], max_features=2, bootstrap_samples=0)
    config_file = work / "development config.json"
    config_file.write_text(json.dumps(config))
    source = Path(call("analyze", "--config", config_file)["run_dir"])
    core = ["manifest.json", "model.bmpmodel", "predictions.csv", "config.json", "qc.json", "gene_ranking.csv"]
    before = {name: sha(source / name) for name in core}
    gmt = work / "pathways ; review.gmt"
    gmt.write_text("Signal <review>\tSynthetic signal term\tgene A\tgene,quoted\n"
                   "Other gene\tGene outside final panel\tGENE-2\n"
                   "All QC genes\tWhole ranked universe\tgene A\tgene,quoted\tGENE-2\n")
    options = ("--gmt", gmt, "--annotation-version", "independent-cli-review-v1", "--network", "none", "--min-size", "1", "--max-size", "100",
               "--permutations", "99", "--seed", "51")
    result = call("ora", "--run", source, *options)
    derivative = Path(result["run_dir"])
    manifest = read(derivative / "manifest.json")
    assert result["source_run_id"] == source.name
    assert manifest["status"] == "completed" and manifest["operation"] == "ora"
    for relative in manifest["required_artifacts"]:
        path = derivative / relative
        assert path.is_file() and path.stat().st_size > 0, relative
        assert sha(path) == manifest["artifact_verification"]["sha256"][relative], relative
    summary = read(result["paths"]["summary"])
    assert summary["annotation"]["provider"] == "local"
    assert summary["annotation"]["version"] == "independent-cli-review-v1"
    sets = summary["gene_sets"]
    assert set(sets["original"]) == {"gene A", "gene,quoted"}, sets
    assert set(sets["expanded"]) == set(sets["original"])
    assert summary["universes"]["configured_assay"]["count"] == 5
    assert summary["universes"]["development_qc"]["count"] == 3
    assert summary["universes"]["annotation_mapped"]["count"] == 3
    gsea = read(result["paths"]["gsea"])
    assert gsea["metadata"]["ranked_gene_count"] == 3
    with (derivative / "ranked_genes.csv").open(newline="") as handle:
        ranks = list(csv.DictReader(handle))
    assert "GENE-2" in {row["gene"] for row in ranks}, ranks
    whole = next(row for row in gsea["results"] if row["term_id"] == "All QC genes")
    assert whole["nes"] is None and whole["reason"], whole
    evidence = read(result["paths"]["evidence"])
    assert all(row["evidence_score"] is None and row["evidence_status"] == "missing"
               for row in evidence["records"])
    assert next(row for row in evidence["records"] if row["gene"] == "gene A")["final_coefficients"]
    graph = read(result["paths"]["graph"])
    assert graph["status"] == "not_requested" and isinstance(graph["nodes"], list)
    html = Path(result["paths"]["report_html"]).read_text()
    assert "Signal &lt;review&gt;" in html and "Signal <review>" not in html
    assert source.name in html and derivative.name in html
    assert before == {name: sha(source / name) for name in core}

    repeated = call("--run", source, *options, script="ORA_PPI_Analysis.R")
    assert repeated["run_dir"] != str(derivative)
    for filename in ["ora_original.csv", "ora_expanded.csv", "gsea.csv", "ranked_genes.csv"]:
        assert sha(Path(repeated["run_dir"]) / filename) == sha(derivative / filename), filename
    call("ora", "--run", source, "--output", source, *options, success=False)
    bad = work / "invalid.gmt"
    bad.write_text("invalid single field\n")
    failed = call("ora", "--run", source, "--gmt", bad, success=False)
    assert read(Path(failed["run_dir"]) / "manifest.json")["status"] == "failed"
    assert before == {name: sha(source / name) for name in core}

    # A clinical-only final model does not erase its recorded assay universe.
    config.update(feature_sets=["clinical"], include=[], panel_sizes=[1])
    config_file.write_text(json.dumps(config))
    clinical = Path(call("analyze", "--config", config_file)["run_dir"])
    clinical_pathway = call("ora", "--run", clinical, *options)
    clinical_summary = read(clinical_pathway["paths"]["summary"])
    assert clinical_summary["gene_sets"]["original"] == []
    assert clinical_summary["universes"]["development_qc"]["count"] == 3
    assert read(clinical_pathway["paths"]["gsea"])["metadata"]["ranked_gene_count"] == 3
    with Path(clinical_pathway["paths"]["ora_original"]).open(newline="") as handle:
        assert all(not row["p_value"] and row["reason"] for row in csv.DictReader(handle))

    external = call("evaluate", "--model", source / "model.bmpmodel", "--data", config["data_file"],
                    "--output", work / "external", "--bootstrap-samples", "0")
    rejected = call("ora", "--run", external["run_dir"], *options, success=False)
    assert "development run" in rejected["error"].lower()
    print("Independent pathway CLI review passed: full ranks/background, immutable source, null panel, failures, deterministic exports and legacy wrapper.")
    print("Retained pathway report:", result["paths"]["report_html"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rscript", type=Path, default=ROOT / "tests/runtime/.pixi/envs/default/bin/Rscript")
    parser.add_argument("--keep-directory", type=Path)
    args = parser.parse_args()
    if args.keep_directory:
        review(args.keep_directory.resolve(), args.rscript.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="bmp pathway CLI review ") as temporary:
            review(Path(temporary), args.rscript.resolve())


if __name__ == "__main__":
    main()
