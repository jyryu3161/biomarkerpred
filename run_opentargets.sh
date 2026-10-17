#!/bin/bash
# ============================================================================
# RESPRED - Run binary analysis for all datasets with Open Targets
# evidence-based gene filtering
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}→ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
}

# Add pixi to PATH if it exists
if [ -f "$HOME/.pixi/bin/pixi" ]; then
    export PATH="$HOME/.pixi/bin:$PATH"
fi

# Check if pixi is installed
if ! command -v pixi &> /dev/null; then
    print_error "pixi is not installed or not in PATH"
    print_info "Please run: ./install.sh"
    exit 1
fi

# Check if dependencies are installed
if [ ! -d ".pixi" ]; then
    print_error "Dependencies not installed"
    print_info "Please run: pixi install && pixi run install-r-packages"
    exit 1
fi

# Get all Open Targets config files
CONFIG_FILES=(config/*_opentargets_analysis.yaml)

# Check if config files exist
if [ ! -f "${CONFIG_FILES[0]}" ]; then
    print_error "No Open Targets config files found in ./config/"
    print_info "Please run:"
    print_info "  python3 fetch_opentargets_genes.py"
    print_info "  python3 generate_opentargets_configs.py"
    exit 1
fi

# Count total datasets
TOTAL=${#CONFIG_FILES[@]}
print_header "Running Open Targets Evidence-Filtered Analysis for $TOTAL Datasets"

# Initialize counters
SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_DATASETS=()

# Create results directory
mkdir -p results

# Process each dataset
for i in "${!CONFIG_FILES[@]}"; do
    CONFIG="${CONFIG_FILES[$i]}"
    DATASET=$(basename "$CONFIG" _opentargets_analysis.yaml)
    CURRENT=$((i + 1))

    print_header "[$CURRENT/$TOTAL] Processing: $DATASET (Open Targets filtered)"
    print_info "Config: $CONFIG"

    # Run binary analysis
    print_info "Running binary analysis: pixi run binary -- --config $CONFIG"
    if pixi run binary -- --config "$CONFIG" 2>&1; then
        print_success "$DATASET binary analysis completed"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        EXIT_CODE=$?
        print_error "$DATASET binary analysis failed (exit code: $EXIT_CODE)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAILED_DATASETS+=("$DATASET")
    fi

    echo ""
done

# Print summary
print_header "Analysis Summary"
echo -e "${BLUE}Binary Analysis:${NC}"
echo -e "  ${GREEN}✓ Successful: $SUCCESS_COUNT${NC}"
echo -e "  ${RED}✗ Failed: $FAIL_COUNT${NC}"
echo ""

EXIT_CODE=0
if [ $FAIL_COUNT -gt 0 ]; then
    print_error "Failed analyses:"
    for dataset in "${FAILED_DATASETS[@]}"; do
        echo "  - $dataset"
    done
    EXIT_CODE=1
fi

if [ $EXIT_CODE -eq 0 ]; then
    print_success "All analyses completed successfully!"
fi

exit $EXIT_CODE
