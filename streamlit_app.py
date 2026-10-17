"""
RESPRED - Drug Response Biomarker Prediction Platform
데이터 업로드하고 분석 실행하는 간단한 웹 인터페이스
"""

import streamlit as st
import pandas as pd
import subprocess
import tempfile
import yaml
from pathlib import Path
import time

# Page configuration
st.set_page_config(page_title="RESPRED", page_icon="💊", layout="wide")

# Custom CSS - Enhanced modern design with better readability
st.markdown(
    """
<style>
    :root {
        --pm-bg: #ffffff; /* 배경을 흰색으로 변경 */
        --pm-surface: #ffffff;
        --pm-border: #e2e8f0;
        --pm-text: #000000; /* 글자를 검은색으로 변경 */
        --pm-text-secondary: #475569;
        --pm-muted: #64748b;
        --pm-primary: #3b82f6;
        --pm-primary-dark: #2563eb;
        --pm-primary-light: #dbeafe;
        --pm-success: #10b981;
        --pm-warning: #f59e0b;
        --pm-error: #ef4444;
    }

    html, body, [data-testid="stAppViewContainer"] {
        background: var(--pm-bg);
        color: var(--pm-text);
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Roboto', 'Helvetica', 'Arial', sans-serif;
    }

    .block-container {
        padding-top: 2rem;
        padding-bottom: 3rem;
        max-width: 1200px;
    }

    h1, h2, h3 {
        color: var(--pm-text);
        font-weight: 700;
        letter-spacing: -0.025em;
    }

    .page-title {
        text-align: center;
        margin-bottom: 0.5rem;
        font-size: 2.5rem;
        background: linear-gradient(135deg, var(--pm-primary) 0%, #8b5cf6 100%);
        -webkit-background-clip: text;
        -webkit-text-fill-color: transparent;
        background-clip: text;
    }

    .page-subtitle {
        text-align: center;
        color: var(--pm-text-secondary);
        margin-bottom: 2.5rem;
        font-size: 1.1rem;
        font-weight: 500;
    }

    .section-card {
        background: var(--pm-surface);
        border: 1px solid var(--pm-border);
        border-radius: 16px;
        padding: 1.75rem 2rem;
        margin-bottom: 1.5rem;
        box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05), 0 10px 15px -3px rgba(0, 0, 0, 0.03);
        transition: box-shadow 0.2s ease;
    }

    .section-card:hover {
        box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.05), 0 20px 25px -5px rgba(0, 0, 0, 0.05);
    }

    .section-card h2 {
        font-size: 1.25rem;
        margin-bottom: 1.25rem;
        padding-bottom: 0.75rem;
        border-bottom: 2px solid var(--pm-border);
        color: var(--pm-text);
        font-weight: 700;
    }

    .section-card h3 {
        font-size: 1.1rem;
        margin-top: 1.5rem;
        margin-bottom: 0.875rem;
        color: var(--pm-text);
        font-weight: 600;
    }

    .stButton>button,
    [data-testid="baseButton-primary"],
    [data-testid="baseButton-primaryFormSubmit"] {
        background: linear-gradient(135deg, var(--pm-primary) 0%, var(--pm-primary-dark) 100%) !important;
        color: #ffffff !important;
        border: none !important;
        border-radius: 10px !important;
        font-weight: 600 !important;
        font-size: 0.95rem !important;
        padding: 0.75rem 1.75rem !important;
        transition: all 0.2s ease !important;
        box-shadow: 0 4px 12px rgba(59, 130, 246, 0.25) !important;
        letter-spacing: 0.01em !important;
    }

    .stButton>button:hover,
    [data-testid="baseButton-primary"]:hover,
    [data-testid="baseButton-primaryFormSubmit"]:hover {
        transform: translateY(-2px) !important;
        box-shadow: 0 6px 20px rgba(59, 130, 246, 0.35) !important;
    }

    .stButton>button:active {
        transform: translateY(0) !important;
    }

    .stButton>button:disabled {
        background: #cbd5e1 !important;
        color: #64748b !important;
        box-shadow: none !important;
        opacity: 0.6;
    }

    .stDownloadButton>button {
        border: 2px solid var(--pm-primary) !important;
        color: var(--pm-primary) !important;
        background: #ffffff !important;
        border-radius: 10px !important;
        font-weight: 600 !important;
        padding: 0.7rem 1.5rem !important;
        transition: all 0.2s ease !important;
    }

    .stDownloadButton>button:hover {
        background: var(--pm-primary) !important;
        color: #ffffff !important;
        transform: translateY(-1px);
        box-shadow: 0 4px 12px rgba(59, 130, 246, 0.2) !important;
    }

    .stTextInput>div>div>input,
    .stSelectbox>div>div>div,
    .stSelectbox>div>div>div>input,
    .stNumberInput>div>div>input,
    .stNumberInput>div>div,
    .stTextArea>div>div>textarea {
        border-radius: 10px !important;
        border: 2px solid var(--pm-border) !important;
        background: #ffffff !important;
        color: var(--pm-text) !important;
        box-shadow: 0 1px 2px rgba(0, 0, 0, 0.05) !important;
        font-size: 0.95rem !important;
        transition: all 0.2s ease !important;
    }

    .stNumberInput>div>div {
        border-radius: 10px !important;
    }

    .stNumberInput button {
        border-left: 2px solid var(--pm-border) !important;
        background: #ffffff !important;
        color: var(--pm-text) !important;
    }

    .stNumberInput button:hover {
        background: var(--pm-bg) !important;
    }

    .stTextInput>div>div>input:focus,
    .stSelectbox>div>div>div:focus,
    .stNumberInput>div>div>input:focus,
    .stTextArea>div>div>textarea:focus {
        border-color: var(--pm-primary) !important;
        box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.15) !important;
    }

    label {
        color: var(--pm-text) !important;
        font-weight: 600 !important;
        font-size: 0.925rem !important;
        margin-bottom: 0.5rem !important;
    }

    [data-baseweb="select"] span {
        color: var(--pm-text) !important;
        font-weight: 500 !important;
    }

    [data-baseweb="menu"] {
        background: #ffffff !important;
        border: 2px solid var(--pm-border) !important;
        border-radius: 12px !important;
        box-shadow: 0 10px 25px rgba(0, 0, 0, 0.1) !important;
    }

    [data-baseweb="menu"] [role="option"] {
        color: var(--pm-text) !important;
        background: transparent !important;
        border-radius: 8px !important;
        padding: 0.625rem 1rem !important;
        margin: 0.25rem 0.5rem !important;
        font-weight: 500 !important;
    }

    [data-baseweb="menu"] [role="option"]:hover {
        background: var(--pm-primary-light) !important;
        color: var(--pm-primary-dark) !important;
    }

    [data-baseweb="menu"] [aria-selected="true"] {
        background: var(--pm-primary) !important;
        color: #ffffff !important;
    }

    [data-testid="stFileUploader"] {
        border-radius: 16px !important;
        border: 2px dashed var(--pm-border) !important;
        padding: 1.5rem 1.25rem !important;
        background: #ffffff !important;
        transition: all 0.3s ease !important;
    }

    [data-testid="stFileUploader"]:hover {
        border-color: var(--pm-primary) !important;
        background: var(--pm-primary-light) !important;
    }

    [data-testid="stFileUploaderDropzone"] {
        border: none !important;
        background: transparent !important;
    }

    [data-testid="stFileUploaderDropzoneInstructions"] {
        color: var(--pm-text-secondary) !important;
        font-weight: 500 !important;
    }

    /* Alert/Notification Boxes - Remove black lines */
    .stAlert, [data-baseweb="notification"] {
        border-radius: 12px !important;
        border: none !important;
        padding: 1rem 1.25rem !important;
        font-weight: 500 !important;
        box-shadow: 0 1px 3px rgba(0, 0, 0, 0.08) !important;
    }

    div[data-baseweb="notification"] {
        background: #ffffff !important;
        border: none !important;
    }

    div[data-baseweb="notification"] > div {
        color: var(--pm-text) !important;
        border: none !important;
    }

    /* Success alerts */
    [data-baseweb="notification"][kind="success"],
    .stSuccess {
        background: #f0fdf4 !important;
        border-left: 4px solid var(--pm-success) !important;
    }

    [data-baseweb="notification"][kind="success"] svg,
    .stSuccess svg {
        color: var(--pm-success) !important;
    }

    /* Info alerts */
    [data-baseweb="notification"][kind="info"],
    .stInfo {
        background: var(--pm-primary-light) !important;
        border-left: 4px solid var(--pm-primary) !important;
    }

    [data-baseweb="notification"][kind="info"] svg,
    .stInfo svg {
        color: var(--pm-primary) !important;
    }

    /* Warning alerts */
    [data-baseweb="notification"][kind="warning"],
    .stWarning {
        background: #fef3c7 !important;
        border-left: 4px solid var(--pm-warning) !important;
    }

    [data-baseweb="notification"][kind="warning"] svg,
    .stWarning svg {
        color: var(--pm-warning) !important;
    }

    /* Error alerts */
    [data-baseweb="notification"][kind="error"],
    .stError {
        background: #fef2f2 !important;
        border-left: 4px solid var(--pm-error) !important;
    }

    [data-baseweb="notification"][kind="error"] svg,
    .stError svg {
        color: var(--pm-error) !important;
    }

    hr {
        border: none;
        height: 2px;
        background: linear-gradient(90deg, transparent, var(--pm-border), transparent);
        margin: 2rem 0;
    }

    .stExpander {
        border: 1px solid var(--pm-border) !important;
        border-radius: 12px !important;
        background: #ffffff !important;
    }

    .stExpander summary {
        color: var(--pm-text) !important;
        font-weight: 600 !important;
    }

    [data-testid="stMetricValue"] {
        color: var(--pm-primary) !important;
        font-size: 1.75rem !important;
        font-weight: 700 !important;
    }

    [data-testid="stMetricLabel"] {
        color: var(--pm-text-secondary) !important;
        font-weight: 600 !important;
        font-size: 0.925rem !important;
    }

    .stDataFrame {
        border: 2px solid var(--pm-border) !important;
        border-radius: 12px !important;
        overflow: hidden;
    }

    /* Remove black lines from images */
    [data-testid="stImage"] {
        border: none !important;
    }

    [data-testid="stImage"] img {
        border: none !important;
        box-shadow: 0 1px 3px rgba(0, 0, 0, 0.05) !important;
        border-radius: 8px !important;
    }

    /* Remove borders from image containers */
    .stImage > div {
        border: none !important;
    }

    footer {visibility: hidden;}
</style>
""",
    unsafe_allow_html=True,
)

# Initialize session state
if "analysis_complete" not in st.session_state:
    st.session_state.analysis_complete = False
if "results_dir" not in st.session_state:
    st.session_state.results_dir = None

# Header
st.markdown("<h1 class='page-title'>💊 RESPRED</h1>", unsafe_allow_html=True)
st.markdown(
    "<p class='page-subtitle'>Drug Response Biomarker Prediction Platform</p>",
    unsafe_allow_html=True,
)

# Main content
col1, col2 = st.columns([2, 1])

with col1:
    st.markdown("## 📁 1. Data Upload")

    # Example data load button
    col_upload, col_example = st.columns([3, 1])

    with col_upload:
        uploaded_file = st.file_uploader(
            "Upload your CSV file",
            type=["csv"],
            help="Upload the dataset for analysis",
        )

    with col_example:
        st.markdown("<br>", unsafe_allow_html=True)  # Spacing
        if st.button("📊 Load Example Data", key="load_example"):
            # Load example data
            example_path = Path("Example_data.csv")
            if example_path.exists():
                st.session_state.example_loaded = True
                st.rerun()
            else:
                st.error("Example_data.csv file not found")

    # Handle example data
    if "example_loaded" in st.session_state and st.session_state.example_loaded:
        example_path = Path("Example_data.csv")
        if example_path.exists():
            uploaded_file = example_path
            st.info("✓ Example data loaded successfully")

    if uploaded_file:
        # Preview data
        df = pd.read_csv(uploaded_file)
        file_name = (
            uploaded_file.name if hasattr(uploaded_file, "name") else str(uploaded_file)
        )
        st.success(f"✓ File loaded: {file_name}")

        with st.expander("📊 Data Preview"):
            preview_df = df.head(10)
            try:
                styled = preview_df.style.set_properties(
                    **{
                        "background-color": "#ffffff",
                        "color": "#0f172a",
                        "border-color": "#e2e8f0",
                        "font-weight": "500",
                    }
                ).set_table_styles(
                    [
                        {
                            "selector": "th",
                            "props": [
                                ("background-color", "#f8fafc"),
                                ("color", "#0f172a"),
                                ("font-weight", "700"),
                                ("border", "2px solid #e2e8f0"),
                                ("padding", "0.75rem 1rem"),
                            ],
                        },
                        {
                            "selector": "td",
                            "props": [
                                ("border", "1px solid #e2e8f0"),
                                ("padding", "0.625rem 1rem"),
                            ],
                        },
                    ]
                )
                st.dataframe(styled, use_container_width=True, hide_index=True)
            except Exception:
                st.dataframe(preview_df, use_container_width=True, hide_index=True)

            col_a, col_b, col_c = st.columns(3)
            with col_a:
                st.metric("Rows", df.shape[0])
            with col_b:
                st.metric("Columns", df.shape[1])
            with col_c:
                # Handle file size for both uploaded and example files
                if hasattr(uploaded_file, "size"):
                    file_size = uploaded_file.size / 1024
                else:
                    file_size = Path(uploaded_file).stat().st_size / 1024
                st.metric("Size", f"{file_size:.1f} KB")

    if uploaded_file:

        st.markdown("## ⚙️ 2. Configuration")

        columns = df.columns.tolist()

        with st.form("analysis_config"):
            col_left, col_right = st.columns(2)

            with col_left:
                sample_id = st.selectbox(
                    "Sample ID Column", columns,
                    index=columns.index("sample") if "sample" in columns else 0
                )
                outcome = st.selectbox(
                    "Response Column", columns,
                    index=columns.index("response") if "response" in columns else 0
                )

            with col_right:
                split_prop = st.slider("Train/Test Split Ratio", 0.5, 0.9, 0.7, 0.05)
                num_seed = st.number_input(
                    "Number of Iterations",
                    value=30,
                    min_value=10,
                    max_value=1000,
                    step=10,
                )
                output_dir = st.text_input(
                    "Output Directory",
                    value="results/binary",
                )

            submitted = st.form_submit_button("🚀 Start Analysis")

            if submitted:
                # Save uploaded file temporarily
                temp_dir = tempfile.mkdtemp()
                # Handle both uploaded file and example file (Path object)
                file_name = (
                    uploaded_file.name
                    if hasattr(uploaded_file, "name")
                    else str(uploaded_file)
                )
                if isinstance(uploaded_file, Path):
                    file_name = uploaded_file.name
                data_path = Path(temp_dir) / file_name
                df.to_csv(data_path, index=False)

                # Create config (workdir omitted - R will default to getwd())
                config = {"data_file": str(data_path)}
                config["binary"] = {
                    "data_file": str(data_path),
                    "sample_id": sample_id,
                    "outcome": outcome,
                    "split_prop": split_prop,
                    "num_seed": num_seed,
                    "output_dir": output_dir,
                }

                # Save config
                config_path = Path(temp_dir) / "config.yaml"
                with open(config_path, "w") as f:
                    yaml.dump(config, f)

                # Run analysis
                st.markdown("<hr/>", unsafe_allow_html=True)
                st.markdown("### 🔄 Running Analysis...")

                progress_bar = st.progress(0)
                status_text = st.empty()
                iteration_text = st.empty()

                try:
                    # Run binary analysis
                    script_type = "binary"

                    status_text.text("Starting R script...")

                    # Run pixi command with real-time output
                    import re
                    import threading
                    import queue

                    process = subprocess.Popen(
                        [
                            "pixi",
                            "run",
                            script_type,
                            "--",
                            "--config",
                            str(config_path),
                        ],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        bufsize=1,
                        universal_newlines=True,
                    )

                    total_iterations = num_seed
                    current_iteration = 0
                    stderr_output = []
                    start_time = time.time()
                    timeout = 600  # 10 minutes
                    stepwise_running = False

                    # Queue for stderr output
                    stderr_queue = queue.Queue()

                    def read_stderr():
                        for line in iter(process.stderr.readline, ""):
                            stderr_queue.put(line)
                        process.stderr.close()

                    # Start stderr reader thread
                    stderr_thread = threading.Thread(target=read_stderr)
                    stderr_thread.daemon = True
                    stderr_thread.start()

                    # Read stderr output in real-time
                    while True:
                        # Check timeout
                        if time.time() - start_time > timeout:
                            process.kill()
                            raise subprocess.TimeoutExpired(process.args, timeout)

                        # Check if process is done
                        if process.poll() is not None:
                            # Read remaining items from queue
                            while not stderr_queue.empty():
                                try:
                                    line = stderr_queue.get_nowait()
                                    stderr_output.append(line)

                                    # Check for progress markers
                                    if "PROGRESS_START:" in line:
                                        match = re.search(r"PROGRESS_START:(\d+)", line)
                                        if match:
                                            total_iterations = int(match.group(1))
                                    elif "STEPWISE_START" in line:
                                        stepwise_running = True
                                        status_text.text(
                                            f"🔍 Step 1/2: Stepwise selection (finding best variables)..."
                                        )
                                        iteration_text.text(
                                            f"⏳ This step performs ~{len(df.columns) * total_iterations} model evaluations and may take 5-15 minutes..."
                                        )
                                    elif "STEPWISE_LOG:" in line:
                                        # Extract and display detailed stepwise log
                                        log_msg = line.split("STEPWISE_LOG:", 1)[1].strip()
                                        iteration_text.text(f"📝 {log_msg}")
                                    elif "STEPWISE_DONE" in line:
                                        stepwise_running = False
                                        status_text.text(
                                            f"✓ Step 1/2 complete! Starting iterations..."
                                        )
                                        iteration_text.text(
                                            f"🚀 Running {total_iterations} iterations (much faster)..."
                                        )
                                    elif "PROGRESS:" in line:
                                        match = re.search(r"PROGRESS:(\d+)", line)
                                        if match:
                                            current_iteration = int(match.group(1))
                                            progress = min(
                                                int((current_iteration / total_iterations) * 100),
                                                100
                                            )
                                            progress_bar.progress(progress)
                                            status_text.text(
                                                f"🔄 Step 2/2: Running iterations ({current_iteration}/{total_iterations})..."
                                            )
                                            iteration_text.text(
                                                f"📊 Progress: {progress}% complete"
                                            )
                                except queue.Empty:
                                    break
                            break

                        # Try to get line from queue (non-blocking)
                        try:
                            line = stderr_queue.get(timeout=0.1)
                            stderr_output.append(line)

                            # Check for progress markers
                            if "PROGRESS_START:" in line:
                                match = re.search(r"PROGRESS_START:(\d+)", line)
                                if match:
                                    total_iterations = int(match.group(1))
                            elif "STEPWISE_START" in line:
                                stepwise_running = True
                                status_text.text(
                                    f"🔍 Step 1/2: Stepwise selection (finding best variables)..."
                                )
                                iteration_text.text(
                                    f"⏳ This step performs ~{len(df.columns) * total_iterations} model evaluations and may take 5-15 minutes..."
                                )
                            elif "STEPWISE_LOG:" in line:
                                # Extract and display detailed stepwise log
                                log_msg = line.split("STEPWISE_LOG:", 1)[1].strip()
                                iteration_text.text(f"📝 {log_msg}")
                            elif "STEPWISE_DONE" in line:
                                stepwise_running = False
                                status_text.text(
                                    f"✓ Step 1/2 complete! Starting iterations..."
                                )
                                iteration_text.text(
                                    f"🚀 Running {total_iterations} iterations (much faster)..."
                                )
                            elif "PROGRESS:" in line:
                                match = re.search(r"PROGRESS:(\d+)", line)
                                if match:
                                    current_iteration = int(match.group(1))
                                    progress = min(
                                        int((current_iteration / total_iterations) * 100),
                                        100
                                    )
                                    progress_bar.progress(progress)
                                    status_text.text(
                                        f"Running iterations ({current_iteration}/{total_iterations})..."
                                    )
                                    iteration_text.text(
                                        f"📊 Progress: {progress}% complete"
                                    )
                        except queue.Empty:
                            continue

                    # Wait for process to complete
                    process.wait()

                    if process.returncode == 0:
                        progress_bar.progress(100)
                        status_text.text("✓ Analysis completed!")
                        iteration_text.text("✅ All iterations finished successfully!")

                        st.session_state.analysis_complete = True
                        st.session_state.results_dir = output_dir

                        time.sleep(1)
                        st.rerun()
                    else:
                        st.error("❌ Error occurred during analysis")
                        if stderr_output:
                            # Filter out PROGRESS lines from error output
                            error_lines = [
                                line
                                for line in stderr_output
                                if not line.startswith("PROGRESS")
                            ]
                            if error_lines:
                                st.code("".join(error_lines), language="text")

                except subprocess.TimeoutExpired:
                    st.error("❌ Analysis timeout (10 minute limit)")
                except Exception as e:
                    st.error(f"❌ Error: {str(e)}")


with col2:
    st.markdown("## 💡 Help")

    st.info(
        """
    **🚀 Quick Start**

    1. Click **📊 Load Example Data** for a demo
    2. Or **upload your CSV file**
    3. Configure column names
    4. Start analysis!

    **📋 Data Format**

    - **Sample ID**: Patient/sample identifier
    - **Response**: Binary (0=Non-responder, 1=Responder)
    - **Feature columns**: Gene expression values
    """
    )

    with st.expander("⚙️ Parameter Details"):
        st.markdown(
            """
        **Split Ratio**
        - Proportion for training set (0.7 = 70%)
        - Higher ratio = more training data

        **Number of Iterations**
        - Train/test split repetitions
        - More iterations = more stable, but longer runtime
        """
        )

    with st.expander("📊 Example Data Info"):
        st.markdown(
            """
        **Example_data.csv**

        Drug response dataset for immediate analysis.

        - 28 patient samples
        - 25,268 gene expression features
        - Binary response (responder/non-responder)
        """
        )

    # Results section (outside col2 to use full width)
if st.session_state.analysis_complete and st.session_state.results_dir:
    st.markdown("---")
    st.markdown("## 📊 Analysis Results")

    results_dir = Path(st.session_state.results_dir)

    if results_dir.exists():
        figures_dir = results_dir / "figures"

        # Display results - ROC and Variable Importance
        col1, col2 = st.columns(2)

        with col1:
            roc_tiff = figures_dir / "Binary_ROCcurve.tiff"
            roc_svg = figures_dir / "Binary_ROCcurve.svg"
            roc_file = roc_tiff if roc_tiff.exists() else (roc_svg if roc_svg.exists() else None)
            if roc_file:
                st.image(str(roc_file), caption="ROC Curve", use_container_width=True)

        with col2:
            vi_tiff = figures_dir / "Binary_Variable_Importance.tiff"
            vi_svg = figures_dir / "Binary_Variable_Importance.svg"
            vi_file = vi_tiff if vi_tiff.exists() else (vi_svg if vi_svg.exists() else None)
            if vi_file:
                st.image(str(vi_file), caption="Variable Importance", use_container_width=True)

        # Waterfall and Volcano plots
        col3, col4 = st.columns(2)

        with col3:
            wf_tiff = figures_dir / "Binary_Waterfall.tiff"
            wf_svg = figures_dir / "Binary_Waterfall.svg"
            wf_file = wf_tiff if wf_tiff.exists() else (wf_svg if wf_svg.exists() else None)
            if wf_file:
                st.image(str(wf_file), caption="Waterfall Plot", use_container_width=True)

        with col4:
            vc_tiff = figures_dir / "Binary_Volcano.tiff"
            vc_svg = figures_dir / "Binary_Volcano.svg"
            vc_file = vc_tiff if vc_tiff.exists() else (vc_svg if vc_svg.exists() else None)
            if vc_file:
                st.image(str(vc_file), caption="Volcano Plot", use_container_width=True)

        # Heatmap (full width)
        hm_tiff = figures_dir / "Binary_Heatmap.tiff"
        hm_svg = figures_dir / "Binary_Heatmap.svg"
        hm_file = hm_tiff if hm_tiff.exists() else (hm_svg if hm_svg.exists() else None)
        if hm_file:
            st.image(str(hm_file), caption="Biomarker Expression Heatmap", use_container_width=True)

        # AUC results
        auc_csv = results_dir / "auc_iterations.csv"
        if auc_csv.exists():
            st.markdown("### 📈 AUC Results")
            auc_df = pd.read_csv(auc_csv)
            st.dataframe(auc_df, use_container_width=True, hide_index=True)

        # Download section
        st.markdown("### 📥 Download Results")

        download_col1, download_col2, download_col3 = st.columns(3)

        with download_col1:
            if roc_file and roc_file.exists():
                with open(roc_file, "rb") as f:
                    st.download_button(
                        "📊 ROC Curve",
                        f,
                        file_name=roc_file.name,
                        mime="image/tiff" if roc_file.suffix == ".tiff" else "image/svg+xml",
                    )

        with download_col2:
            if vi_file and vi_file.exists():
                with open(vi_file, "rb") as f:
                    st.download_button(
                        "📊 Variable Importance",
                        f,
                        file_name=vi_file.name,
                        mime="image/tiff" if vi_file.suffix == ".tiff" else "image/svg+xml",
                    )

        with download_col3:
            if auc_csv.exists():
                with open(auc_csv, "rb") as f:
                    st.download_button(
                        "📄 AUC Results (CSV)",
                        f,
                        file_name="auc_iterations.csv",
                        mime="text/csv",
                    )

        # New analysis button
        if st.button("🔄 Start New Analysis"):
            st.session_state.analysis_complete = False
            st.session_state.results_dir = None
            if "example_loaded" in st.session_state:
                del st.session_state.example_loaded
            st.rerun()
    else:
        st.warning("Results directory not found.")

# Footer
st.markdown("<hr/>", unsafe_allow_html=True)
st.markdown(
    """
    <div style='text-align: center; padding: 2rem 0 1rem 0;'>
        <p style='font-size: 0.9rem; color: #4b5563; margin-bottom: 0.3rem;'>
            <strong>RESPRED</strong> — Drug Response Biomarker Prediction Tool
        </p>
        <p style='font-size: 0.85rem; color: #94a3b8;'>
            Powered by R, Python & Streamlit | © 2025
        </p>
    </div>
    """,
    unsafe_allow_html=True,
)
