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
