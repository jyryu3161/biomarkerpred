#!/bin/bash

# ============================================================================
# RESPRED - Installation Script
# ============================================================================
# Installs pixi, R environment, and all required R packages.
#
# Usage: ./install.sh
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}============================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================================================${NC}"
    echo ""
}

print_success() { echo -e "  ${GREEN}✓${NC} $1"; }
print_info()    { echo -e "  ${YELLOW}→${NC} $1"; }
print_error()   { echo -e "  ${RED}✗${NC} $1"; }

# ============================================================================
# Step 1: Install pixi
# ============================================================================
print_header "Step 1/4: Checking pixi"

if command -v pixi &> /dev/null; then
    print_success "pixi $(pixi --version) is installed"
else
    print_info "Installing pixi..."

    if [[ "$OSTYPE" == "linux-gnu"* ]] || [[ "$OSTYPE" == "darwin"* ]]; then
        curl -fsSL https://pixi.sh/install.sh | bash
        export PATH="$HOME/.pixi/bin:$PATH"
    else
        print_error "Unsupported OS. Install pixi manually: https://pixi.sh"
        exit 1
    fi

    if command -v pixi &> /dev/null; then
        print_success "pixi installed: $(pixi --version)"
    else
        print_error "pixi not found after installation"
        print_info "Add to PATH: export PATH=\"\$HOME/.pixi/bin:\$PATH\""
        exit 1
    fi
fi

# ============================================================================
# Step 2: Install conda-forge dependencies (R, compilers, libraries)
# ============================================================================
print_header "Step 2/4: Installing R environment and dependencies"

print_info "Running: pixi install"
print_info "This downloads R, compilers, and conda-forge packages..."

if pixi install; then
    print_success "R environment installed"
else
    print_error "pixi install failed"
    exit 1
fi

# ============================================================================
# Step 3: Install CRAN packages
# ============================================================================
print_header "Step 3/4: Installing R packages from CRAN"

print_info "Running: pixi run install-r-packages"
print_info "This compiles packages not available on conda-forge (cutpointr, coefplot, etc.)"
print_info "This may take 5-10 minutes on first install..."

if pixi run install-r-packages; then
    print_success "CRAN packages installed"
else
    print_error "Some CRAN packages failed to install"
    print_info "You can retry later: pixi run install-r-packages"
fi

# ============================================================================
# Step 4: Verify installation
# ============================================================================
print_header "Step 4/4: Verifying installation"

VERIFY_SCRIPT='
pkgs <- c("yaml", "ggplot2", "caret", "pROC", "cutpointr", "coefplot", "ROCR")
ok <- TRUE
for (p in pkgs) {
  result <- tryCatch({
    suppressPackageStartupMessages(library(p, character.only = TRUE))
    TRUE
  }, error = function(e) FALSE)
  status <- if (result) "OK" else "MISSING"
  cat(sprintf("  %s %s\n", ifelse(result, "\033[0;32m✓\033[0m", "\033[0;31m✗\033[0m"), p))
  if (!result) ok <- FALSE
}
if (ok) {
  cat("\n  \033[0;32mAll packages verified.\033[0m\n")
  quit(status = 0)
} else {
  cat("\n  \033[0;31mSome packages are missing. Run: pixi run install-r-packages\033[0m\n")
  quit(status = 1)
}
'

if pixi run Rscript -e "$VERIFY_SCRIPT"; then
    VERIFY_OK=true
else
    VERIFY_OK=false
fi

# ============================================================================
# Done
# ============================================================================
print_header "Installation Complete"

if [ "$VERIFY_OK" = true ]; then
    print_success "All dependencies are installed and verified"
else
    print_info "Some packages may be missing — see above for details"
    print_info "Retry with: pixi run install-r-packages"
fi

echo ""
echo -e "  ${BLUE}Quick start:${NC}"
echo ""
echo "    # Run drug response prediction"
echo "    ./run_analysis.sh binary --config config/example_analysis.yaml"
echo ""
echo "    # Launch GUI (requires Node.js + Rust)"
echo "    cd gui && npx @tauri-apps/cli dev"
echo ""
