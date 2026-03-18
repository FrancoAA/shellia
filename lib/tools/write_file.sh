#!/usr/bin/env bash
# Tool: write_file — create or overwrite a file

tool_write_file_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "write_file",
        "description": "Create or overwrite a file with the given content. Creates parent directories as needed.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "File path to write"
                },
                "content": {
                    "type": "string",
                    "description": "The content to write"
                }
            },
            "required": ["path", "content"]
        }
    }
}
EOF
}

tool_write_file_execute() {
    local args_json="$1"

    local file_path content
    file_path=$(printf '%s' "$args_json" | jq -r '.path')
    content=$(printf '%s' "$args_json" | jq -r '.content')

    debug_log "tool" "write_file: path=${file_path}"
    tool_trace "write_file: ${file_path}"

    local existed=false
    [[ -f "$file_path" ]] && existed=true

    # Create parent directories
    local parent_dir
    parent_dir=$(dirname "$file_path")
    if ! mkdir -p "$parent_dir" 2>/dev/null; then
        echo "Error: could not create directory: ${parent_dir}"
        return 1
    fi

    # Write content
    if ! printf '%s' "$content" > "$file_path"; then
        echo "Error: could not write to: ${file_path}"
        return 1
    fi

    # Report byte count
    local byte_count
    byte_count=$(wc -c < "$file_path" | tr -d ' ')

    if [[ "$existed" == true ]]; then
        echo "OK: wrote ${byte_count} bytes to ${file_path} [overwriting existing file]"
    else
        echo "OK: wrote ${byte_count} bytes to ${file_path}"
    fi
}
