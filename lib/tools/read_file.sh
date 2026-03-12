#!/usr/bin/env bash
# Tool: read_file — read a file with offset/limit and line numbers

tool_read_file_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "read_file",
        "description": "Read a file with line numbers. Returns content with line number prefixes (e.g. '1: content'). Supports offset/limit for pagination. Detects binary files and can list directory entries. Lines over 2000 chars are truncated.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "File path to read"
                },
                "offset": {
                    "type": "integer",
                    "description": "Starting line number, 1-indexed (default: 1)"
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of lines to return (default: 200)"
                }
            },
            "required": ["path"]
        }
    }
}
EOF
}

# Known text-like application MIME types
_READ_FILE_TEXT_MIMES=(
    application/json
    application/xml
    application/javascript
    application/x-shellscript
    application/x-perl
    application/x-ruby
    application/x-python
    application/x-awk
    application/x-sh
    application/xhtml+xml
    application/svg+xml
    application/x-httpd-php
    application/x-yaml
    application/toml
    application/x-tex
    application/sql
    application/graphql
    application/ld+json
    application/manifest+json
    application/x-ndjson
)

_is_text_mime() {
    local mime="$1"

    # text/* is always text
    if [[ "$mime" == text/* ]]; then
        return 0
    fi

    # Check known text-like application types
    local known
    for known in "${_READ_FILE_TEXT_MIMES[@]}"; do
        if [[ "$mime" == "$known" ]]; then
            return 0
        fi
    done

    return 1
}

tool_read_file_execute() {
    local args_json="$1"
    local max_lines="${SHELLIA_MAX_READ_LINES:-200}"
    local max_bytes="${SHELLIA_MAX_OUTPUT_BYTES:-51200}"
    local max_line_length="${SHELLIA_MAX_LINE_LENGTH:-2000}"

    local file_path offset limit
    file_path=$(echo "$args_json" | jq -r '.path')
    offset=$(echo "$args_json" | jq -r '.offset // empty')
    limit=$(echo "$args_json" | jq -r '.limit // empty')

    offset="${offset:-1}"
    limit="${limit:-$max_lines}"

    debug_log "tool" "read_file: path=${file_path} offset=${offset} limit=${limit}"
    echo -e "${THEME_CMD:-}read_file: ${file_path}${NC:-}" >&2

    # Check if path exists at all
    if [[ ! -e "$file_path" ]]; then
        echo "Error: file not found: ${file_path}"
        return 1
    fi

    # Handle directories
    if [[ -d "$file_path" ]]; then
        local entries=""
        local entry
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local basename
            basename=$(basename "$entry")
            if [[ -d "$entry" ]]; then
                entries+="${basename}/"$'\n'
            else
                entries+="${basename}"$'\n'
            fi
        done < <(find "$file_path" -maxdepth 1 -mindepth 1 2>/dev/null | sort)

        if [[ -z "$entries" ]]; then
            echo "(empty directory)"
        else
            printf '%s' "$entries"
        fi
        return 0
    fi

    # Check if it's a regular file
    if [[ ! -f "$file_path" ]]; then
        echo "Error: file not found: ${file_path}"
        return 1
    fi

    # Binary detection via mime type
    local mime_info mime_type
    mime_info=$(file --mime-type -b "$file_path" 2>/dev/null)
    mime_type="${mime_info%%[[:space:]]*}"

    if ! _is_text_mime "$mime_type"; then
        # Also check charset as a secondary heuristic
        local charset_info
        charset_info=$(file --mime-encoding -b "$file_path" 2>/dev/null)
        if [[ "$charset_info" == "binary" ]]; then
            local file_size
            if [[ "$(uname)" == "Darwin" ]]; then
                file_size=$(stat -f '%z' "$file_path" 2>/dev/null)
            else
                file_size=$(stat --format '%s' "$file_path" 2>/dev/null)
            fi
            echo "[binary file: ${mime_type}, ${file_size} bytes]"
            return 0
        fi
    fi

    # Count total lines in file
    local total_lines
    total_lines=$(wc -l < "$file_path" | tr -d ' ')

    # If file doesn't end with newline but has content, count that last line
    if [[ "$total_lines" -eq 0 ]] && [[ -s "$file_path" ]]; then
        total_lines=1
    elif [[ -s "$file_path" ]]; then
        # Check if the last byte is a newline
        local last_byte
        last_byte=$(tail -c 1 "$file_path" | xxd -p 2>/dev/null)
        if [[ "$last_byte" != "0a" && -n "$last_byte" ]]; then
            ((total_lines++))
        fi
    fi

    # Calculate end line
    local end_line
    end_line=$((offset + limit - 1))
    if [[ "$end_line" -gt "$total_lines" ]]; then
        end_line="$total_lines"
    fi

    # Clamp offset
    if [[ "$offset" -gt "$total_lines" ]]; then
        echo "[lines ${offset}-${offset} of ${total_lines} total]"
        echo "(offset beyond end of file)"
        return 0
    fi

    # Extract lines with awk, add line numbers, truncate long lines
    local output byte_count truncated_by_bytes=false
    output=$(awk -v start="$offset" -v end="$end_line" -v maxlen="$max_line_length" '
        NR >= start && NR <= end {
            line = $0
            if (length(line) > maxlen) {
                line = substr(line, 1, maxlen) "...[truncated]"
            }
            printf "%d: %s\n", NR, line
        }
        NR > end { exit }
    ' "$file_path")

    # Check byte cap
    byte_count=${#output}
    if [[ "$byte_count" -gt "$max_bytes" ]]; then
        output="${output:0:$max_bytes}"
        truncated_by_bytes=true
        # Trim to last complete line
        output="${output%$'\n'*}"
    fi

    # Build header
    local header="[lines ${offset}-${end_line} of ${total_lines} total]"

    # Output header then content
    echo "$header"
    if [[ -n "$output" ]]; then
        echo "$output"
    fi

    if [[ "$truncated_by_bytes" == true ]]; then
        echo "[output truncated at ${max_bytes} bytes]"
    fi
}
