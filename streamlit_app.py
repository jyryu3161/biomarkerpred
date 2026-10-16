#!/usr/bin/env python3
"""Migration notice for the retired Streamlit analysis interface.

This module intentionally contains no fitting, process-launch or patient-upload
workflow. Use the shared CLI or the React/Tauri desktop application.
"""
from pathlib import Path
import sys

MIGRATION = """The legacy Streamlit scientific workflow is retired.
Use the desktop application (./run_gui.sh from a source checkout), or the shared CLI:

  ./run_analysis.sh doctor --json
  ./run_analysis.sh validate --config CONFIG.json --json
  ./run_analysis.sh analyze --config CONFIG.json --json

Read the actual run_dir and manifest returned by the CLI. Completed runs contain
model.bmpmodel, report.html and report.pdf. Use predict/evaluate for frozen models,
runs/compare for history, and ora for exploratory pathway/gene evidence.
Old train-AUC/seed selection results and incomplete model files need retraining
with nested grouped validation; they cannot be converted into frozen models.
See README.md, AGENTS.md and CLAUDE.md for the shared-engine workflow.
"""


def main():
    try:
        import streamlit as st
        from streamlit.runtime.scriptrunner import get_script_run_ctx
    except ImportError:
        print(MIGRATION, file=sys.stderr)
        return 2
    if get_script_run_ctx(suppress_warning=True) is None:
        print(MIGRATION, file=sys.stderr)
        return 2
    st.set_page_config(page_title="BioMarkerPred migration", layout="centered")
    st.title("Use the shared BioMarkerPred engine")
    st.warning("The legacy Streamlit analysis interface has been retired.")
    st.markdown("The desktop and CLI now share grouped nested validation, frozen models and verified run artifacts.")
    st.code(MIGRATION, language="text")
    st.caption(f"Source checkout: {Path(__file__).resolve().parent}")
    return 0


if __name__ == "__main__":
    code = main()
    if code:
        raise SystemExit(code)
