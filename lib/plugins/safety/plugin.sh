#!/usr/bin/env bash
# Plugin: safety — dangerous command detection and confirmation

plugin_safety_info() {
    echo "Dangerous command detection and confirmation prompts"
}

plugin_safety_hooks() {
    echo "init before_tool_call"
}

plugin_safety_on_init() {
    load_dangerous_commands
    debug_log "plugin:safety" "loaded ${#DANGEROUS_PATTERNS[@]} dangerous patterns"
}

plugin_safety_on_before_tool_call() {
    local tool_name="$1"
    local tool_args="$2"

    # Only check command-executing tools
    case "$tool_name" in
        run_command)
            local cmd
            cmd=$(echo "$tool_args" | jq -r '.command' 2>/dev/null)
            [[ -z "$cmd" ]] && return 0
            _safety_check_command "$cmd"
            ;;
        run_plan)
            local steps
            steps=$(echo "$tool_args" | jq -r '.steps[].command' 2>/dev/null)
            while IFS= read -r cmd; do
                [[ -z "$cmd" ]] && continue
                _safety_check_command "$cmd"
                # If one command was blocked, stop checking the rest
                [[ "${SHELLIA_TOOL_BLOCKED:-false}" == "true" ]] && return 0
            done <<< "$steps"
            ;;
        edit_file|write_file)
            local file_path
            file_path=$(echo "$tool_args" | jq -r '.path' 2>/dev/null)
            [[ -z "$file_path" ]] && return 0
            # Check if the target path matches a dangerous pattern
            _safety_check_command "write ${file_path}"
            ;;
    esac
}

_safety_check_command() {
    local cmd="$1"
    if is_dangerous "$cmd"; then
        debug_log "plugin:safety" "dangerous pattern matched: ${cmd}"
        # Skip confirmation in yolo mode
        if [[ "${SHELLIA_YOLO_MODE:-false}" == "true" ]]; then
            debug_log "plugin:safety" "yolo mode enabled, skipping confirmation"
            return 0
        fi
        echo -e "${THEME_ERROR}Warning: '${cmd}' matches a dangerous pattern.${NC}" >&2
        read -rp "Run this? [y/N]: " confirm </dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_warn "Command blocked by safety plugin." >&2
            SHELLIA_TOOL_BLOCKED=true
            return 0
        fi
    fi
}
