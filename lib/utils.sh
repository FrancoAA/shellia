#!/usr/bin/env bash
# Shared utilities for shellia

# --- Zsh compatibility ---
# When running under zsh, enable options that make behavior match bash:
#   KSH_ARRAYS:      0-based array indexing (zsh default is 1-based)
#   SH_WORD_SPLIT:   split unquoted vars on whitespace (bash default behavior)
#   NO_NOMATCH:      don't error on unmatched globs (match bash behavior)
#   BASH_REMATCH:    use BASH_REMATCH for regex captures instead of $match
#   TYPESET_SILENT:  suppress output when 'local'/'typeset' re-declares in loops
if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt KSH_ARRAYS SH_WORD_SPLIT NO_NOMATCH BASH_REMATCH TYPESET_SILENT 2>/dev/null || true
fi

SHELLIA_VERSION="0.1.0"

# Portable function listing (bash: declare -F, zsh: typeset +f)
# Outputs one function name per line
_list_functions() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        typeset +f
    else
        declare -F | awk '{print $3}'
    fi
}

# Portable function existence check
# Usage: _function_exists "func_name"
_function_exists() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        [[ ${+functions[$1]} -eq 1 ]]
    else
        declare -F "$1" >/dev/null 2>&1
    fi
}

# Portable prompt-and-read (bash: read -rp, zsh: read -r "?prompt")
# Usage: _read_prompt "prompt text" varname
# For silent/password: _read_prompt_silent "prompt text" varname
_read_prompt() {
    local prompt="$1"
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        read -r "?${prompt}" "$2"
    else
        read -rp "$prompt" "$2"
    fi
}

_read_prompt_silent() {
    local prompt="$1"
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        read -rs "?${prompt}" "$2"
    else
        read -rsp "$prompt" "$2"
    fi
}

# REPL read with readline support (bash -e flag, zsh has built-in ZLE)
_read_prompt_repl() {
    local prompt="$1"
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        read -r "?${prompt}" "$2"
    else
        read -rep "$prompt" "$2"
    fi
}

# Debug mode (set via --debug flag, REPL command, or SHELLIA_DEBUG env var)
SHELLIA_DEBUG="${SHELLIA_DEBUG:-false}"

debug_log() {
    [[ "$SHELLIA_DEBUG" == "true" || "$SHELLIA_DEBUG" == "1" ]] || return 0
    local label="$1"
    shift
    echo -e "${DIM}[debug] ${label}:${NC} $*" >&2
}

debug_block() {
    [[ "$SHELLIA_DEBUG" == "true" || "$SHELLIA_DEBUG" == "1" ]] || return 0
    local label="$1"
    local content="$2"
    local max_lines="${3:-10}"
    local line_count
    line_count=$(echo "$content" | wc -l | tr -d ' ')
    echo -e "${DIM}[debug] ${label} (${line_count} lines):${NC}" >&2
    if [[ $line_count -le $max_lines ]]; then
        echo -e "${DIM}${content}${NC}" >&2
    else
        echo -e "${DIM}$(echo "$content" | head -n "$max_lines")${NC}" >&2
        echo -e "${DIM}  ... ($((line_count - max_lines)) more lines)${NC}" >&2
    fi
}

# Base reset code (always needed)
if [[ -t 1 ]]; then
    NC='\033[0m'
    BOLD='\033[1m'
    DIM='\033[2m'
else
    NC='' BOLD='' DIM=''
fi

# Theme color roles (set defaults, overridden by apply_theme)
THEME_PROMPT='' THEME_HEADER='' THEME_ACCENT='' THEME_CMD=''
THEME_SUCCESS='' THEME_WARN='' THEME_ERROR='' THEME_INFO=''
THEME_MUTED='' THEME_SEPARATOR=''

log_info() {
    echo -e "${THEME_INFO}${1}${NC}" >&2
}

log_success() {
    echo -e "${THEME_SUCCESS}${1}${NC}" >&2
}

log_warn() {
    echo -e "${THEME_WARN}${1}${NC}" >&2
}

log_error() {
    echo -e "${THEME_ERROR}${1}${NC}" >&2
}

die() {
    log_error "Error: $1"
    exit 1
}

# Check if a required command exists
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

# Spinner for long-running operations
SPINNER_PID=""

spinner_start() {
    local msg="${1:-Thinking...}"
    # Only show spinner if stderr is a terminal
    [[ -t 2 ]] || return 0

    (
        # Re-apply zsh compat in subshell (options don't inherit)
        [[ -n "${ZSH_VERSION:-}" ]] && setopt KSH_ARRAYS 2>/dev/null
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        local start_time=$SECONDS
        while true; do
            local elapsed=$(( SECONDS - start_time ))
            local display_msg="$msg"
            if [[ $elapsed -ge 10 ]]; then
                display_msg="Still thinking..."
            fi
            printf "\r${THEME_MUTED}%s %s ${NC}${THEME_MUTED}(%ds)${NC}" "${frames[$i]}" "$display_msg" "$elapsed" >&2
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}

spinner_stop() {
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        # Clear the spinner line
        printf "\r\033[K" >&2
    fi
}
