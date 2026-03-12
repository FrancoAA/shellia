#!/usr/bin/env bash
# Tool: edit_file — exact string replacement in files

tool_edit_file_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "edit_file",
        "description": "Perform exact string replacement in a file. Finds old_string and replaces it with new_string. By default, only a single unique match is allowed; use replace_all=true to replace all occurrences.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "File path to edit"
                },
                "old_string": {
                    "type": "string",
                    "description": "Exact text to find in the file"
                },
                "new_string": {
                    "type": "string",
                    "description": "Replacement text"
                },
                "replace_all": {
                    "type": "boolean",
                    "description": "Replace all occurrences (default: false)"
                }
            },
            "required": ["path", "old_string", "new_string"]
        }
    }
}
EOF
}

tool_edit_file_execute() {
    local args_json="$1"

    local file_path old_string new_string replace_all
    file_path=$(printf '%s' "$args_json" | jq -r '.path')
    old_string=$(printf '%s' "$args_json" | jq -r '.old_string')
    new_string=$(printf '%s' "$args_json" | jq -r '.new_string')
    replace_all=$(printf '%s' "$args_json" | jq -r '.replace_all // false')

    debug_log "tool" "edit_file: path=${file_path} replace_all=${replace_all}"
    echo -e "${THEME_CMD:-}edit_file: ${file_path}${NC:-}" >&2

    # Validate file exists
    if [[ ! -f "$file_path" ]]; then
        echo "Error: file not found: ${file_path}"
        return 1
    fi

    # Validate old_string != new_string
    if [[ "$old_string" == "$new_string" ]]; then
        echo "Error: old_string and new_string are identical"
        return 1
    fi

    # Read the entire file content (preserving trailing newlines with sentinel)
    local content
    content=$(cat "$file_path" && printf 'x')
    content="${content%x}"

    # Count occurrences using bash parameter expansion
    # Remove all occurrences of old_string and compare lengths
    local stripped="${content//"$old_string"/}"
    local old_len=${#old_string}

    if [[ "$old_len" -eq 0 ]]; then
        echo "Error: old_string not found in ${file_path}"
        return 1
    fi

    local original_len=${#content}
    local stripped_len=${#stripped}
    local diff=$((original_len - stripped_len))
    local count=$((diff / old_len))

    # Validate old_string exists in file
    if [[ "$count" -eq 0 ]]; then
        echo "Error: old_string not found in ${file_path}"
        return 1
    fi

    # If multiple matches and replace_all is not true, error out
    if [[ "$count" -gt 1 && "$replace_all" != "true" ]]; then
        echo "Error: found ${count} matches for old_string in ${file_path}. Use replace_all=true to replace all, or provide more surrounding context to match uniquely."
        return 1
    fi

    # Perform replacement
    # NOTE: In bash 3.2 (macOS), the replacement part of ${var/pat/rep}
    # must NOT be quoted — quoting it embeds literal quote characters.
    # The pattern part IS quoted to ensure literal (not glob) matching.
    local new_content
    if [[ "$replace_all" == "true" ]]; then
        new_content="${content//"$old_string"/$new_string}"
    else
        new_content="${content/"$old_string"/$new_string}"
    fi

    # Write atomically via temp file + mv, preserving original permissions
    local tmp_file
    tmp_file=$(mktemp "${file_path}.tmp.XXXXXX")
    printf '%s' "$new_content" > "$tmp_file"

    # Preserve original file permissions (portable: macOS stat vs GNU stat)
    local original_perms
    original_perms=$(stat -f '%Lp' "$file_path" 2>/dev/null || stat -c '%a' "$file_path" 2>/dev/null)
    [[ -n "$original_perms" ]] && chmod "$original_perms" "$tmp_file"

    mv "$tmp_file" "$file_path"

    echo "OK: replaced ${count} occurrence(s) in ${file_path}"
}
