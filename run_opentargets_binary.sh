#!/bin/bash
# ============================================================================
# RESPRED - Run BINARY analysis for all datasets with Open Targets evidence filtering
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${YELLOW}→ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"
}

if [ -f "$HOME/.pixi/bin/pixi" ]; then
    export PATH="$HOME/.pixi/bin:$PATH"
fi

if ! command -v pixi &> /dev/null; then
    print_error "pixi is not installed or not in PATH"
    exit 1
fi

if [ ! -d ".pixi" ]; then
    print_error "Dependencies not installed"
    exit 1
fi

CONFIG_FILES=(config/*_opentargets_analysis.yaml)

if [ ! -f "${CONFIG_FILES[0]}" ]; then
    print_error "No Open Targets config files found in ./config/"
    print_info "Run: python3 fetch_opentargets_genes.py && python3 generate_opentargets_configs.py"
    exit 1
fi

TOTAL=${#CONFIG_FILES[@]}
print_header "Open Targets BINARY Analysis for $TOTAL Datasets"

SUCCESS=0
FAIL=0
FAILED=()

for i in "${!CONFIG_FILES[@]}"; do
    CONFIG="${CONFIG_FILES[$i]}"
    DATASET=$(basename "$CONFIG" _opentargets_analysis.yaml)
    CURRENT=$((i + 1))

    print_header "[$CURRENT/$TOTAL] $DATASET - Binary"
    print_info "Config: $CONFIG"

    if pixi run binary -- --config "$CONFIG" 2>&1; then
        print_success "$DATASET binary completed"
        SUCCESS=$((SUCCESS + 1))
    else
        print_error "$DATASET binary failed (exit code: $?)"
        FAIL=$((FAIL + 1))
        FAILED+=("$DATASET")
    fi
    echo ""
done

print_header "Binary Analysis Summary"
echo -e "  ${GREEN}✓ Successful: $SUCCESS${NC}"
echo -e "  ${RED}✗ Failed: $FAIL${NC}"

if [ $FAIL -gt 0 ]; then
    print_error "Failed datasets:"
    for d in "${FAILED[@]}"; do echo "  - $d"; done
    exit 1
fi

print_success "All binary analyses completed!"
