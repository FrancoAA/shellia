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
                __max_iter="${1#*=}"
                shift
                ;;
            --max-iterations)
                __max_iter="${2:-5}"
                shift 2
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
