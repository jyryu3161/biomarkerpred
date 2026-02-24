#!/bin/bash

# ============================================================================
# RESPRED - Analysis Runner Script
# ============================================================================
# Runs drug response prediction workflow using pixi
#
# Usage:
#   ./run_analysis.sh binary --config path/to/config.yaml
# ============================================================================

set -e  # Exit on any error

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

# Add pixi to PATH if it exists in the default location
if [ -f "$HOME/.pixi/bin/pixi" ]; then
    export PATH="$HOME/.pixi/bin:$PATH"
fi

# Check if pixi is installed
if ! command -v pixi &> /dev/null; then
    print_error "pixi is not installed or not in PATH"
    print_info "Please install pixi first:"
    print_info "  curl -fsSL https://pixi.sh/install.sh | bash"
    print_info ""
    print_info "Or run the full installation script:"
    print_info "  ./install.sh"
    print_info ""
    print_info "After installation, restart your shell or run:"
    print_info "  export PATH=\"\$HOME/.pixi/bin:\$PATH\""
    exit 1
fi

# Check if dependencies are installed
if [ ! -d ".pixi" ]; then
    print_error "Dependencies not installed (no .pixi directory found)"
    print_info ""
    print_info "Please install dependencies first:"
    print_info "  pixi install"
    print_info "  pixi run install-r-packages"
    exit 1
fi

# Check arguments
if [ $# -lt 1 ]; then
    print_error "Usage: $0 binary [--config CONFIG_FILE]"
    print_info ""
    print_info "Examples:"
    print_info "  $0 binary --config config/example_analysis.yaml"
    exit 1
fi

ANALYSIS_TYPE=$1
shift  # Remove first argument, rest will be passed to Rscript

if [ "$ANALYSIS_TYPE" != "binary" ]; then
    print_error "Analysis type must be 'binary'"
    exit 1
fi

# Check if config file is provided
CONFIG_FILE=""
if [ $# -gt 0 ]; then
    if [ "$1" == "--config" ] || [ "$1" == "-c" ]; then
        if [ $# -lt 2 ]; then
            print_error "Config file path required after --config"
            exit 1
        fi
        CONFIG_FILE="$2"
        shift 2
    elif [[ "$1" == --config=* ]]; then
        CONFIG_FILE="${1#--config=}"
        shift
    else
        # Assume first argument is config file
        CONFIG_FILE="$1"
        shift
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
fi

# Run the analysis
print_info "Running $ANALYSIS_TYPE analysis..."
if [ -n "$CONFIG_FILE" ]; then
    print_info "Using config: $CONFIG_FILE"
    pixi run "$ANALYSIS_TYPE" -- --config "$CONFIG_FILE" "$@"
else
    print_info "Using default config: config/example_analysis.yaml"
    pixi run "$ANALYSIS_TYPE" "$@"
fi

print_success "Analysis completed!"
