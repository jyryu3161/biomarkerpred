#!/bin/bash
# RESPRED - GUI Launcher
# Usage: ./run_gui.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check Node.js
if ! command -v node &> /dev/null; then
    echo -e "${RED}Node.js not found.${NC} Install from: https://nodejs.org (v18+)"
    exit 1
fi

# Check Rust/Cargo
if ! command -v cargo &> /dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env"
    fi
    if ! command -v cargo &> /dev/null; then
        echo -e "${RED}Rust not found.${NC} Install from: https://rustup.rs"
        exit 1
    fi
fi

# Install npm dependencies if needed
if [ ! -d "gui/node_modules" ]; then
    echo -e "${YELLOW}Installing frontend dependencies...${NC}"
    (cd gui && npm install)
fi

echo -e "${GREEN}Starting RESPRED GUI...${NC}"
cd gui && npx @tauri-apps/cli dev
