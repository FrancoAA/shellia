#!/usr/bin/env bash
# Shared utilities for bashia

BASHIA_VERSION="0.1.0"

# Colors (only if terminal supports them)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m' # No Color
else
    RED='' YELLOW='' GREEN='' BLUE='' BOLD='' DIM='' NC=''
fi

log_info() {
    echo -e "${BLUE}${1}${NC}" >&2
}

log_success() {
    echo -e "${GREEN}${1}${NC}" >&2
}

log_warn() {
    echo -e "${YELLOW}${1}${NC}" >&2
}

log_error() {
    echo -e "${RED}${1}${NC}" >&2
}

die() {
    log_error "Error: $1"
    exit 1
}

# Check if a required command exists
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}
