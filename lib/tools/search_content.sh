#!/usr/bin/env bash
# Tool: search_content — search file contents by regex pattern

# Directories to exclude from content search
_SEARCH_CONTENT_EXCLUDE_DIRS=(.git node_modules __pycache__ .venv vendor dist build .next coverage)

tool_search_content_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "search_content",
        "description": "Search file contents using regular expressions. Returns matching lines as filepath:line_number: content, capped at 100 results. Automatically excludes common non-essential directories (.git, node_modules, __pycache__, .venv, vendor, dist, build, .next, coverage).",
        "parameters": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Regex pattern to search for in file contents"
                },
                "path": {
                    "type": "string",
                    "description": "Directory to search in. Defaults to current working directory."
                },
                "include": {
                    "type": "string",
                    "description": "File glob filter, e.g. \"*.js\", \"*.{ts,tsx}\""
                }
            },
            "required": ["pattern"]
        }
    }
}
EOF
}

tool_search_content_execute() {
    local args_json="$1"
    local max_results="${SHELLIA_MAX_SEARCH_RESULTS:-100}"

    local pattern path include
    pattern=$(echo "$args_json" | jq -r '.pattern')
    path=$(echo "$args_json" | jq -r '.path // empty')
    path="${path:-$PWD}"
    path="${path%/}"
    include=$(echo "$args_json" | jq -r '.include // empty')

    debug_log "tool" "search_content: pattern=${pattern} path=${path} include=${include}"
    tool_trace "search_content: ${pattern} in ${path}"

    # Validate pattern is not empty
    if [[ -z "$pattern" ]]; then
        echo "Error: pattern is required"
        return 1
    fi

    # Validate path exists
    if [[ ! -d "$path" ]]; then
        echo "Error: directory not found: ${path}"
        return 1
    fi

    local raw_results

    if command -v rg >/dev/null 2>&1; then
        # Use ripgrep
        local -a rg_cmd=(rg --no-heading --line-number --color never)

        # Add exclude dirs
        for dir in "${_SEARCH_CONTENT_EXCLUDE_DIRS[@]}"; do
            rg_cmd+=(-g "!${dir}/")
        done

        # Add include filter
        if [[ -n "$include" ]]; then
            rg_cmd+=(-g "$include")
        fi

        rg_cmd+=(-- "$pattern" "$path")

        raw_results=$("${rg_cmd[@]}" 2>/dev/null) || true
    else
        # Fall back to grep -rn
        local -a grep_cmd=(grep -rn --color=never)

        # Add exclude dirs
        for dir in "${_SEARCH_CONTENT_EXCLUDE_DIRS[@]}"; do
            grep_cmd+=(--exclude-dir="$dir")
        done

        # Add include filter
        if [[ -n "$include" ]]; then
            grep_cmd+=(--include="$include")
        fi

        grep_cmd+=(-- "$pattern" "$path")

        raw_results=$("${grep_cmd[@]}" 2>/dev/null) || true
    fi

    # Handle no results
    if [[ -z "$raw_results" ]]; then
        echo "No matches found for '${pattern}' in ${path}"
        return 0
    fi

    # Make paths relative to search dir and truncate long lines
    local output=""
    local total_count=0
    local shown_count=0
    local relative_line

    while IFS= read -r line; do
        ((total_count++))

        if [[ "$shown_count" -ge "$max_results" ]]; then
            continue
        fi

        # Make path relative to search dir
        relative_line="${line#"${path}"/}"

        # Truncate lines over 2000 chars
        if [[ "${#relative_line}" -gt 2000 ]]; then
            relative_line="${relative_line:0:2000}...[truncated]"
        fi

        if [[ -n "$output" ]]; then
            output+=$'\n'
        fi
        output+="$relative_line"
        ((shown_count++))
    done <<< "$raw_results"

    # Output results with optional truncation marker
    if [[ "$total_count" -gt "$max_results" ]]; then
        printf '%s\n[truncated: showing %d of %d matches]' "$output" "$max_results" "$total_count"
    else
        echo "$output"
    fi
}
