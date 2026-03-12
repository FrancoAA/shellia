#!/usr/bin/env bash
# Tool: search_files — find files by glob pattern

_SEARCH_FILES_MAX_RESULTS="${SHELLIA_MAX_SEARCH_RESULTS:-100}"

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
    local max_results="${SHELLIA_MAX_SEARCH_RESULTS:-${_SEARCH_FILES_MAX_RESULTS}}"

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

    # Build the prune expression for excluded directories
    local prune_expr=""
    for dir in "${_SEARCH_FILES_EXCLUDE_DIRS[@]}"; do
        if [[ -n "$prune_expr" ]]; then
            prune_expr="${prune_expr} -o"
        fi
        prune_expr="${prune_expr} -name ${dir}"
    done

    # Determine whether to use -name or -path based on pattern containing /
    local match_flag match_pattern
    if [[ "$pattern" == */* ]]; then
        match_flag="-path"
        # For -path, prepend */ if not already starting with / or *
        match_pattern="*/${pattern}"
    else
        match_flag="-name"
        match_pattern="$pattern"
    fi

    # Build and execute find command with exclusions
    # Use eval to properly expand the prune expression
    local find_results
    find_results=$(
        eval "find \"$path\" \\( ${prune_expr} \\) -prune -o -type f ${match_flag} \"${match_pattern}\" -print" 2>/dev/null
    )

    # Handle no results
    if [[ -z "$find_results" ]]; then
        echo "No files found matching '${pattern}' in ${path}"
        return 0
    fi

    # Sort by modification time (newest first)
    # macOS and Linux need different approaches
    local sorted_results
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: use stat -f '%m %N' to get mtime + path, then sort
        sorted_results=$(
            echo "$find_results" | xargs stat -f '%m %N' 2>/dev/null \
                | sort -rn \
                | cut -d' ' -f2-
        )
    else
        # Linux: use stat --format '%Y %n'
        sorted_results=$(
            echo "$find_results" | xargs stat --format '%Y %n' 2>/dev/null \
                | sort -rn \
                | cut -d' ' -f2-
        )
    fi

    # Fallback: if stat failed, use unsorted results
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
