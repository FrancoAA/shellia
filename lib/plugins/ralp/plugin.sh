#!/usr/bin/env bash
# Plugin: ralp — LLM-driven PRD interview + Claude iteration loop

plugin_ralp_info() {
    echo "LLM-driven PRD interview that feeds into a Claude iteration loop"
}

plugin_ralp_hooks() {
    echo ""
}

# Parse ralp command arguments
# Usage: _ralp_parse_args <topic_var> <max_iter_var> [args...]
# Sets topic_var to the topic string (may be empty)
# Sets max_iter_var to the resolved max iterations
_ralp_parse_args() {
    local __topic_var="$1"
    local __max_iter_var="$2"
    shift 2

    local __topic=""
    local __max_iter
    __max_iter=$(plugin_config_get "ralp" "max_iterations" "5")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-iterations=*)
                local __extracted="${1#*=}"
                if [[ -n "$__extracted" ]]; then
                    __max_iter="$__extracted"
                fi
                shift
                ;;
            --max-iterations)
                if [[ $# -ge 2 ]]; then
                    __max_iter="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            *)
                if [[ -z "$__topic" ]]; then
                    __topic="$1"
                fi
                shift
                ;;
        esac
    done

    printf -v "$__topic_var" '%s' "$__topic"
    printf -v "$__max_iter_var" '%s' "$__max_iter"
}

# Generate a URL-friendly slug from PRD content
# Looks for the first "# PRD: <title>" line; falls back to timestamp
_ralp_prd_slug() {
    local prd_content="$1"
    local title

    # Try to extract title from "# PRD: <title>" line
    title=$(echo "$prd_content" | grep -m1 '^# PRD:' | sed 's/^# PRD:[[:space:]]*//')

    if [[ -z "$title" ]]; then
        # Fallback: use timestamp
        echo "prd-$(date +%Y%m%d-%H%M%S)"
        return 0
    fi

    # Slugify: lowercase, replace non-alphanumeric runs with hyphens, trim hyphens
    echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//;s/-$//'
}

# Write the PRD content to a file in the given directory
# Prints the full path of the written file on stdout
_ralp_write_prd() {
    local prd_content="$1"
    local outdir="${2:-.}"

    mkdir -p "$outdir" || { log_error "ralp: cannot create directory '${outdir}'"; return 1; }

    local slug
    slug=$(_ralp_prd_slug "$prd_content")

    local outfile="${outdir}/prd-${slug}.md"
    printf '%s\n' "$prd_content" > "$outfile"
    echo "$outfile"
}

# Check if a response contains the interview complete sentinel.
# Outputs "0" if not found, or "1" followed by the PRD content (one line per line) if found.
# The sentinel line itself is stripped from the output.
# Usage:
#   sentinel_output=$(_ralp_check_sentinel "$response")
#   found=$(echo "$sentinel_output" | head -n1)
#   prd=$(echo "$sentinel_output" | tail -n +2)
_ralp_check_sentinel() {
    local response="$1"

    if [[ "$response" != *"[INTERVIEW_COMPLETE]"* ]]; then
        echo "0"
        return 0
    fi

    local prd_content
    prd_content=$(echo "$response" | awk '/\[INTERVIEW_COMPLETE\]/{found=1; next} found{print}')

    echo "1"
    echo "$prd_content"
}

# Ensure cclean is installed; install it if not found
_ralp_ensure_cclean() {
    if ! command -v cclean &>/dev/null; then
        log_info "Installing cclean for pretty output..."
        if ! curl -fsSL https://raw.githubusercontent.com/ariel-frischer/claude-clean/main/install.sh | sh; then
            log_error "Failed to install cclean. Continuing without pretty output."
            return 1
        fi
    fi
    return 0
}

# Run the claude iteration loop with the given PRD content
# Args: $1 = prd_content, $2 = max_iterations
_ralp_run_claude_loop() {
    local prd_content="$1"
    local max_iterations="$2"

    # Validate max_iterations is a positive integer
    if ! [[ "$max_iterations" =~ ^[1-9][0-9]*$ ]]; then
        log_error "ralp: max_iterations must be a positive integer, got: '${max_iterations}'"
        return 1
    fi

    # Ensure claude is available
    if ! command -v claude &>/dev/null; then
        log_error "'claude' CLI not found. Install it from: https://claude.ai/code"
        return 1
    fi

    _ralp_ensure_cclean
    local cclean_available=0
    command -v cclean &>/dev/null && cclean_available=1

    echo -e "${THEME_HEADER}Starting Claude loop: ${max_iterations} iteration(s)${NC}"
    echo -e "${THEME_SEPARATOR}$(printf '%.0s─' {1..50})${NC}"

    local i
    for ((i=1; i<=max_iterations; i++)); do
        echo ""
        echo -e "${THEME_ACCENT}=== Iteration ${i} of ${max_iterations} ===${NC}"
        echo ""

        if [[ $cclean_available -eq 1 ]]; then
            claude -p "$prd_content" \
                --dangerously-skip-permissions \
                --output-format stream-json | cclean
            local claude_exit="${PIPESTATUS[0]}"
        else
            claude -p "$prd_content" \
                --dangerously-skip-permissions \
                --output-format stream-json
            local claude_exit=$?
        fi

        if [[ $claude_exit -ne 0 ]]; then
            log_error "claude exited with code ${claude_exit} on iteration ${i}. Stopping loop."
            return 1
        fi

        if [[ $i -lt $max_iterations ]]; then
            echo ""
            echo -e "${THEME_MUTED}--- Completed iteration ${i}, continuing... ---${NC}"
        fi
    done

    echo ""
    echo -e "${THEME_SEPARATOR}$(printf '%.0s─' {1..50})${NC}"
    echo -e "${THEME_SUCCESS}Ralph loop completed after ${max_iterations} iteration(s).${NC}"
}
