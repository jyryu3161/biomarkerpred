#!/usr/bin/env python3
"""
RESPRED - Generate Open Targets evidence-filtered analysis configuration files.

Reads existing config files and creates new configs with an 'evidence'
section for drug-target gene filtering.

Usage:
    python3 generate_opentargets_configs.py [--drugs pembrolizumab nivolumab]
    python3 generate_opentargets_configs.py --score-threshold 0.2
"""

import argparse
import glob
import json
import os
import sys

import yaml

MAPPING_FILE = "drug_chembl_mapping.json"
EVIDENCE_DIR = "evidence"
CONFIG_DIR = "config"


def load_mapping(mapping_file):
    with open(mapping_file, "r") as f:
        return json.load(f)


def generate_config(drug_key, base_config_path, mapping_info, score_threshold, evidence_dir):
    """Generate an opentargets-filtered config from a base config."""
    with open(base_config_path, "r") as f:
        config = yaml.safe_load(f)

    evidence_file = os.path.join(evidence_dir, f"{drug_key}_opentargets_genes.csv")

    # Check that evidence file exists
    if not os.path.exists(evidence_file):
        print(f"  Warning: Evidence file not found: {evidence_file}", file=sys.stderr)
        return None

    # Add evidence section
    config["evidence"] = {
        "gene_file": evidence_file,
        "score_threshold": score_threshold,
        "source": "Open Targets Platform",
        "drug_name": drug_key,
        "chembl_id": mapping_info["chembl_id"],
    }

    # Update output directories for binary
    if "binary" in config:
        config["binary"]["output_dir"] = f"results/{drug_key}_opentargets/binary"

    return config


def main():
    parser = argparse.ArgumentParser(
        description="Generate Open Targets evidence-filtered analysis configs"
    )
    parser.add_argument(
        "--score-threshold",
        type=float,
        default=0.1,
        help="Score threshold for evidence filtering (default: 0.1)",
    )
    parser.add_argument(
        "--drugs",
        nargs="*",
        default=None,
        help="Specific drug names (e.g., pembrolizumab nivolumab). Default: all.",
    )
    parser.add_argument(
        "--mapping-file",
        default=MAPPING_FILE,
        help=f"Path to drug-ChEMBL mapping JSON (default: {MAPPING_FILE})",
    )
    parser.add_argument(
        "--evidence-dir",
        default=EVIDENCE_DIR,
        help=f"Directory containing evidence CSV files (default: {EVIDENCE_DIR})",
    )
    parser.add_argument(
        "--config-dir",
        default=CONFIG_DIR,
        help=f"Directory for config files (default: {CONFIG_DIR})",
    )
    parser.add_argument(
        "--base-config",
        default=None,
        help="Base config file to use for all drugs (default: auto-detect)",
    )
    args = parser.parse_args()

    # Load mapping
    if not os.path.exists(args.mapping_file):
        print(f"Error: Mapping file not found: {args.mapping_file}", file=sys.stderr)
        sys.exit(1)

    mapping = load_mapping(args.mapping_file)

    # Select drugs
    if args.drugs:
        datasets = {k: v for k, v in mapping.items() if k in args.drugs}
        missing = set(args.drugs) - set(datasets.keys())
        if missing:
            print(f"Warning: Unknown drugs: {missing}", file=sys.stderr)
    else:
        datasets = mapping

    if not datasets:
        print("No drugs to process.", file=sys.stderr)
        sys.exit(1)

    total = len(datasets)
    created = 0
    skipped = 0

    print(f"Generating opentargets configs for {total} drugs")
    print("=" * 60)

    for drug_key, info in sorted(datasets.items()):
        # Use specified base config or look for drug-specific one
        if args.base_config:
            base_config = args.base_config
        else:
            base_config = os.path.join(args.config_dir, "example_analysis.yaml")

        output_config = os.path.join(args.config_dir, f"{drug_key}_opentargets_analysis.yaml")

        if not os.path.exists(base_config):
            print(f"  Skipping {drug_key}: base config not found ({base_config})")
            skipped += 1
            continue

        config = generate_config(
            drug_key, base_config, info, args.score_threshold, args.evidence_dir
        )
        if config is None:
            skipped += 1
            continue

        with open(output_config, "w") as f:
            f.write(f"# RESPRED Open Targets evidence-filtered configuration for {drug_key}\n")
            f.write(f"# Drug: {drug_key} ({info['chembl_id']})\n")
            f.write(f"# Generated from: {os.path.basename(base_config)}\n")

            class QuotedDumper(yaml.SafeDumper):
                pass

            def str_representer(dumper, data):
                if data in (".", "~", "null", "true", "false", "yes", "no",
                            "on", "off", "none"):
                    return dumper.represent_scalar(
                        "tag:yaml.org,2002:str", data, style='"'
                    )
                return dumper.represent_scalar("tag:yaml.org,2002:str", data)

            QuotedDumper.add_representer(str, str_representer)

            yaml.dump(config, f, Dumper=QuotedDumper,
                      default_flow_style=False, sort_keys=False)

        print(f"  Created: {output_config}")
        created += 1

    print("\n" + "=" * 60)
    print(f"Done: {created} configs created, {skipped} skipped")


if __name__ == "__main__":
    main()
