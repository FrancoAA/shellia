#!/usr/bin/env bash
# Tool registry: auto-discovers tools from lib/tools/, builds schemas, dispatches calls

# Source all tool files from lib/tools/
load_tools() {
    local tools_dir="${SHELLIA_DIR}/lib/tools"
    if [[ -d "$tools_dir" ]]; then
        for tool_file in "${tools_dir}"/*.sh; do
            [[ -f "$tool_file" ]] || continue
            source "$tool_file"
            debug_log "tools" "loaded $(basename "$tool_file")"
        done
    fi
}

SHELLIA_PLAN_MODE_TOOL_WHITELIST=(
    read_file
    search_files
    search_content
    todo_write
    ask_user
)

_normalize_agent_mode() {
    local mode="${1:-build}"
    case "$mode" in
        build|plan) echo "$mode" ;;
        *) echo "build" ;;
    esac
}

_tool_allowed_for_mode() {
    local mode
    mode=$(_normalize_agent_mode "$1")
    local tool_name="$2"

    if [[ "$mode" == "build" ]]; then
        return 0
    fi

    local allowed_tool
    for allowed_tool in "${SHELLIA_PLAN_MODE_TOOL_WHITELIST[@]}"; do
        if [[ "$allowed_tool" == "$tool_name" ]]; then
            return 0
        fi
    done

    return 1
}

# Build JSON array of all tool schemas for the API request
build_tools_array() {
    local mode
    mode=$(_normalize_agent_mode "${SHELLIA_AGENT_MODE:-build}")

    local funcs
    funcs=$(declare -F | awk '{print $3}' | grep '^tool_.*_schema$' | sort)

    if [[ -z "$funcs" ]]; then
        echo '[]'
        return
    fi

    # Collect schemas into a jq-built array for valid JSON
    local schemas="[]"
    for func in $funcs; do
        local tool_name
        tool_name="${func#tool_}"
        tool_name="${tool_name%_schema}"

        if ! _tool_allowed_for_mode "$mode" "$tool_name"; then
            continue
        fi

        local schema
        schema=$("$func")
        schemas=$(echo "$schemas" | jq --argjson s "$schema" '. + [$s]')
    done

    echo "$schemas"
}

# Dispatch a tool call to the correct execute function
# Args: $1 = tool name, $2 = arguments JSON string
# Returns: tool result string on stdout
dispatch_tool_call() {
    local tool_name="$1"
    local tool_args="$2"
    local func_name="tool_${tool_name}_execute"

    debug_log "tools" "dispatch: ${tool_name}"

    if declare -F "$func_name" >/dev/null 2>&1; then
        "$func_name" "$tool_args"
    else
        echo "Error: unknown tool '${tool_name}'"
        return 1
    fi
}
