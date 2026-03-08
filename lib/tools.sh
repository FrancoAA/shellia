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

# Build JSON array of all tool schemas for the API request
build_tools_array() {
    local funcs
    funcs=$(_list_functions | grep '^tool_.*_schema$' | sort)

    if [[ -z "$funcs" ]]; then
        echo '[]'
        return
    fi

    # Collect schemas into a jq-built array for valid JSON
    local schemas="[]"
    for func in $funcs; do
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

    if _function_exists "$func_name"; then
        "$func_name" "$tool_args"
    else
        echo "Error: unknown tool '${tool_name}'"
        return 1
    fi
}
