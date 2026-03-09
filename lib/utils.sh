#!/usr/bin/env bash
# Shared utilities for shellia

SHELLIA_VERSION="0.1.0"

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

# Platform-specific install hint for a command
_install_hint() {
    local cmd="$1"
    local hint=""
    case "$(uname -s)" in
        Darwin)
            case "$cmd" in
                jq)   hint="brew install jq" ;;
                curl) hint="brew install curl" ;;
                git)  hint="xcode-select --install  OR  brew install git" ;;
                *)    hint="brew install $cmd" ;;
            esac
            ;;
        Linux)
            if command -v apt-get >/dev/null 2>&1; then
                hint="sudo apt-get install $cmd"
            elif command -v dnf >/dev/null 2>&1; then
                hint="sudo dnf install $cmd"
            elif command -v pacman >/dev/null 2>&1; then
                hint="sudo pacman -S $cmd"
            elif command -v apk >/dev/null 2>&1; then
                hint="sudo apk add $cmd"
            else
                hint="Install '$cmd' using your package manager"
            fi
            ;;
        *)
            hint="Install '$cmd' using your package manager"
            ;;
    esac
    echo "$hint"
}

# Check all required dependencies and report missing ones with install hints
check_dependencies() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    log_error "Missing required dependencies:"
    echo "" >&2
    for cmd in "${missing[@]}"; do
        local hint
        hint=$(_install_hint "$cmd")
        echo -e "  ${BOLD}${cmd}${NC}  ->  ${hint}" >&2
    done
    echo "" >&2
    exit 1
}

# Spinner for long-running operations
SPINNER_PID=""

# Format markdown text for terminal output using ANSI escape codes.
# Reads from stdin. Uses theme colors when available.
format_markdown() {
    # Skip formatting if stdout is not a terminal
    [[ -t 1 ]] || { cat; return; }

    local line in_code_block=false code_lang=""
    local esc_bold esc_dim esc_italic esc_underline esc_reset esc_invert esc_strike
    local c_accent c_muted c_separator c_header
    # Use printf to expand escape sequences into actual bytes
    printf -v esc_bold '\033[1m'
    printf -v esc_dim '\033[2m'
    printf -v esc_italic '\033[3m'
    printf -v esc_underline '\033[4m'
    printf -v esc_reset '\033[0m'
    printf -v esc_invert '\033[7m'
    printf -v esc_strike '\033[9m'
    # Use theme colors if available, fall back to defaults
    printf -v c_accent "${THEME_ACCENT:-\033[0;36m}"
    printf -v c_muted "${THEME_MUTED:-\033[2m}"
    printf -v c_separator "${THEME_SEPARATOR:-\033[2;36m}"
    printf -v c_header "${THEME_HEADER:-\033[1;35m}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        # --- Code block toggle ---
        if [[ "$line" =~ ^\`\`\`(.*)$ ]]; then
            if [[ "$in_code_block" == false ]]; then
                in_code_block=true
                code_lang="${BASH_REMATCH[1]}"
                if [[ -n "$code_lang" ]]; then
                    printf '%s\n' "${c_muted}┌─ ${code_lang} ${esc_reset}"
                else
                    printf '%s\n' "${c_muted}┌──${esc_reset}"
                fi
                continue
            else
                in_code_block=false
                code_lang=""
                printf '%s\n' "${c_muted}└──${esc_reset}"
                continue
            fi
        fi

        # --- Inside code block: print dimmed with border ---
        if [[ "$in_code_block" == true ]]; then
            printf '%s\n' "${c_muted}│${esc_reset} ${c_accent}${line}${esc_reset}"
            continue
        fi

        # --- Horizontal rule ---
        if [[ "$line" =~ ^(---+|\*\*\*+|___+)$ ]]; then
            printf '%s\n' "${c_separator}$(printf '%.0s─' {1..40})${esc_reset}"
            continue
        fi

        # --- Headers ---
        if [[ "$line" =~ ^###[[:space:]]+(.+)$ ]]; then
            printf '%s\n' "${esc_bold}${c_header}${BASH_REMATCH[1]}${esc_reset}"
            continue
        fi
        if [[ "$line" =~ ^##[[:space:]]+(.+)$ ]]; then
            printf '%s\n' "${esc_bold}${c_header}${BASH_REMATCH[1]}${esc_reset}"
            continue
        fi
        if [[ "$line" =~ ^#[[:space:]]+(.+)$ ]]; then
            printf '%s\n' "${esc_bold}${esc_underline}${c_header}${BASH_REMATCH[1]}${esc_reset}"
            continue
        fi

        # --- Blockquotes ---
        if [[ "$line" =~ ^'>'[[:space:]]*(.*)$ ]]; then
            printf '%s\n' "${c_muted}│ ${BASH_REMATCH[1]}${esc_reset}"
            continue
        fi

        # --- Unordered list items ---
        if [[ "$line" =~ ^[[:space:]]*[-\*][[:space:]]+\[x\][[:space:]]+(.+)$ ]]; then
            printf '%s\n' "  ☑ ${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*[-\*][[:space:]]+\[[[:space:]]\][[:space:]]+(.+)$ ]]; then
            printf '%s\n' "  ☐ ${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*[-\*][[:space:]]+(.+)$ ]]; then
            local item="${BASH_REMATCH[1]}"
            item=$(_fmt_inline "$item" "$esc_bold" "$esc_italic" "$c_accent" "$esc_underline" "$esc_reset" "$esc_strike")
            printf '%s\n' "  • ${item}"
            continue
        fi

        # --- Ordered list items ---
        if [[ "$line" =~ ^[[:space:]]*([0-9]+)\.[[:space:]]+(.+)$ ]]; then
            local num="${BASH_REMATCH[1]}"
            local item="${BASH_REMATCH[2]}"
            item=$(_fmt_inline "$item" "$esc_bold" "$esc_italic" "$c_accent" "$esc_underline" "$esc_reset" "$esc_strike")
            printf '%s\n' "  ${num}. ${item}"
            continue
        fi

        # --- Regular line: apply inline formatting ---
        line=$(_fmt_inline "$line" "$esc_bold" "$esc_italic" "$c_accent" "$esc_underline" "$esc_reset" "$esc_strike")
        printf '%s\n' "$line"
    done
}

# Apply inline markdown formatting using pure bash (no sed).
# Arguments: text esc_bold esc_italic c_accent esc_underline esc_reset esc_strike
_fmt_inline() {
    local text="$1"
    local esc_bold="$2" esc_italic="$3" c_accent="$4" esc_underline="$5" esc_reset="$6" esc_strike="$7"
    local result="" remaining="$text"

    # Inline code: `code`
    local re_code='^([^`]*)`([^`]+)`(.*)'
    result=""
    while [[ "$remaining" =~ $re_code ]]; do
        result+="${BASH_REMATCH[1]}${c_accent}${BASH_REMATCH[2]}${esc_reset}"
        remaining="${BASH_REMATCH[3]}"
    done
    result+="$remaining"
    remaining="$result"

    # Bold + italic: ***text***
    local re_bi='(.*)\*\*\*([^*]+)\*\*\*(.*)'
    result=""
    while [[ "$remaining" =~ $re_bi ]]; do
        result+="${BASH_REMATCH[1]}${esc_bold}${esc_italic}${BASH_REMATCH[2]}${esc_reset}"
        remaining="${BASH_REMATCH[3]}"
    done
    result+="$remaining"
    remaining="$result"

    # Bold: **text**
    local re_bold='(.*)\*\*([^*]+)\*\*(.*)'
    result=""
    while [[ "$remaining" =~ $re_bold ]]; do
        result+="${BASH_REMATCH[1]}${esc_bold}${BASH_REMATCH[2]}${esc_reset}"
        remaining="${BASH_REMATCH[3]}"
    done
    result+="$remaining"
    remaining="$result"

    # Italic: *text* (bold already processed, so no ** pairs remain)
    local re_italic='(.*)\*([^*]+)\*(.*)'
    result=""
    while [[ "$remaining" =~ $re_italic ]]; do
        result+="${BASH_REMATCH[1]}${esc_italic}${BASH_REMATCH[2]}${esc_reset}"
        remaining="${BASH_REMATCH[3]}"
    done
    result+="$remaining"
    remaining="$result"

    # Strikethrough: ~~text~~
    local re_strike='^(.*)~~([^~]+)~~(.*)'
    result=""
    while [[ "$remaining" =~ $re_strike ]]; do
        result+="${BASH_REMATCH[1]}${esc_strike}${BASH_REMATCH[2]}${esc_reset}"
        remaining="${BASH_REMATCH[3]}"
    done
    result+="$remaining"
    remaining="$result"

    # Links: [text](url) -> text (url)
    local re_link='(.*)\[([^]]+)\]\(([^)]+)\)(.*)'
    result=""
    while [[ "$remaining" =~ $re_link ]]; do
        result+="${BASH_REMATCH[1]}${esc_underline}${BASH_REMATCH[2]}${esc_reset} (${c_accent}${BASH_REMATCH[3]}${esc_reset})"
        remaining="${BASH_REMATCH[4]}"
    done
    result+="$remaining"

    printf '%s' "$result"
}

spinner_start() {
    local msg="${1:-Thinking...}"
    # Only show spinner if stderr is a terminal
    [[ -t 2 ]] || return 0

    (
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
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        # Clear the spinner line
        printf "\r\033[K" >&2
    fi
}
