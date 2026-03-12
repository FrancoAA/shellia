#!/usr/bin/env bash
# Tool: search_files — find files by glob pattern

# Directories to exclude from search results
_SEARCH_FILES_EXCLUDE_DIRS=(.git node_modules __pycache__ .venv vendor dist build .next coverage)

tool_search_files_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "search_files",
        "description": "Find files by glob pattern. Returns matching file paths sorted by modification time (newest first), capped at 100 results. Automatically excludes common non-essential directories (.git, node_modules, __pycache__, .venv, vendor, dist, build, .next, coverage).",
        "parameters": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Glob pattern to match files (e.g. \"*.py\", \"src/**/*.ts\")"
                },
                "path": {
                    "type": "string",
                    "description": "Directory to search in. Defaults to current working directory."
                }
            },
            "required": ["pattern"]
        }
    }
}
EOF
}

tool_search_files_execute() {
    local args_json="$1"
    local max_results="${SHELLIA_MAX_SEARCH_RESULTS:-100}"

    local pattern path
    pattern=$(echo "$args_json" | jq -r '.pattern')
    path=$(echo "$args_json" | jq -r '.path // empty')
    path="${path:-$PWD}"

    debug_log "tool" "search_files: pattern=${pattern} path=${path}"
    echo -e "${THEME_CMD:-}search_files: ${pattern} in ${path}${NC:-}" >&2

    # Validate path exists
    if [[ ! -d "$path" ]]; then
        echo "Error: directory not found: ${path}"
        return 1
    fi

    # Build find command as an array (no eval — safe from injection)
    local -a find_cmd=(find "$path")

    # Add prune expressions for excluded directories
    find_cmd+=(\()
    local first=true
    for dir in "${_SEARCH_FILES_EXCLUDE_DIRS[@]}"; do
        if [[ "$first" == true ]]; then
            first=false
        else
            find_cmd+=(-o)
        fi
        find_cmd+=(-name "$dir")
    done
    find_cmd+=(\) -prune -o)

    # Determine whether to use -name or -path based on pattern containing /
    local match_flag match_pattern
    if [[ "$pattern" == */* ]]; then
        match_flag="-path"
        # For -path, prepend */ only if pattern doesn't already start with * or /
        if [[ "$pattern" == /* || "$pattern" == \** ]]; then
            match_pattern="$pattern"
        else
            match_pattern="*/${pattern}"
        fi
    else
        match_flag="-name"
        match_pattern="$pattern"
    fi

    find_cmd+=(-type f "$match_flag" "$match_pattern" -print)

    # Execute find
    local find_results
    find_results=$("${find_cmd[@]}" 2>/dev/null)

    # Handle no results
    if [[ -z "$find_results" ]]; then
        echo "No files found matching '${pattern}' in ${path}"
        return 0
    fi

    # Sort by modification time (newest first)
    # Process line-by-line to handle paths with spaces safely
    local mtime_list=""
    if [[ "$(uname)" == "Darwin" ]]; then
        while IFS= read -r file; do
            mtime_list+="$(stat -f '%m %N' "$file" 2>/dev/null)"$'\n'
        done <<< "$find_results"
    else
        while IFS= read -r file; do
            mtime_list+="$(stat --format '%Y %n' "$file" 2>/dev/null)"$'\n'
        done <<< "$find_results"
    fi

    local sorted_results
    sorted_results=$(echo "$mtime_list" | sed '/^$/d' | sort -rn | cut -d' ' -f2-)

    # Fallback: if stat produced nothing, use unsorted results
    if [[ -z "$sorted_results" ]]; then
        sorted_results="$find_results"
    fi

    # Count total results
    local total_count
    total_count=$(echo "$sorted_results" | wc -l | tr -d ' ')

    # Cap at max results
    local output
    if [[ "$total_count" -gt "$max_results" ]]; then
        output=$(echo "$sorted_results" | head -n "$max_results")
        printf '%s\n[results truncated: showing %d of %d matches]' "$output" "$max_results" "$total_count"
    else
        echo "$sorted_results"
    fi
}
