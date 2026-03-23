#!/usr/bin/env bash
# Plugin: memory — persistent memory across sessions
# Stores timestamped facts the AI learns during conversations in a markdown file.
# Memories are injected into the system prompt so the AI recalls them in future sessions.

SHELLIA_MEMORY_FILE=""

# --- Plugin interface ---

plugin_memory_info() {
    echo "Persistent memory across sessions (save and recall facts)"
}

plugin_memory_hooks() {
    echo "init prompt_build"
}

plugin_memory_on_init() {
    SHELLIA_MEMORY_FILE="${SHELLIA_CONFIG_DIR}/memory.md"

    # Create memory file with header if it doesn't exist
    if [[ ! -f "$SHELLIA_MEMORY_FILE" ]]; then
        mkdir -p "$(dirname "$SHELLIA_MEMORY_FILE")"
        echo "# Shellia Memory" > "$SHELLIA_MEMORY_FILE"
        debug_log "plugin:memory" "created memory file: ${SHELLIA_MEMORY_FILE}"
    fi

    local entry_count
    entry_count=$(_memory_count_entries)
    debug_log "plugin:memory" "loaded ${entry_count} memory entries from ${SHELLIA_MEMORY_FILE}"
}

plugin_memory_on_prompt_build() {
    local mode="$1"
    local entries
    entries=$(_memory_get_entries)

    if [[ -n "$entries" ]]; then
        cat <<EOF

MEMORY:
The following are facts you have learned from previous conversations with this user.
Use them to provide better, more personalized assistance. If any memory is outdated
or contradicted by the user, use the memory_remove tool to delete it and optionally
save an updated version with memory_save.

${entries}
EOF
    fi
}

# --- Tools ---

tool_memory_save_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "memory_save",
        "description": "Save a fact or preference to persistent memory. Use this when you learn something useful about the user, their project, preferences, or environment that would be valuable to remember across sessions. Each memory should be a single, concise fact. Examples: 'User prefers Python 3.11 with type hints', 'Project uses PostgreSQL 15 on AWS RDS', 'User's name is Alex'.",
        "parameters": {
            "type": "object",
            "properties": {
                "content": {
                    "type": "string",
                    "description": "The fact or preference to remember. Should be a single, concise statement."
                }
            },
            "required": ["content"]
        }
    }
}
EOF
}

tool_memory_save_execute() {
    local args_json="$1"
    local content
    content=$(echo "$args_json" | jq -r '.content')

    if [[ -z "$content" || "$content" == "null" ]]; then
        echo "Error: memory content is required."
        return 1
    fi

    # Prevent multi-line entries
    if [[ "$content" == *$'\n'* ]]; then
        echo "Error: memory content must be a single line."
        return 1
    fi

    if [[ -z "$SHELLIA_MEMORY_FILE" ]]; then
        echo "Error: memory plugin not initialized."
        return 1
    fi

    local timestamp
    timestamp=$(date +%Y-%m-%d)

    # Append the new memory entry
    echo "- [${timestamp}] ${content}" >> "$SHELLIA_MEMORY_FILE"

    local total
    total=$(_memory_count_entries)
    debug_log "plugin:memory" "saved memory: ${content}"

    echo "Memory saved (${total} total): ${content}"
}

tool_memory_remove_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "memory_remove",
        "description": "Remove a memory entry that is outdated, incorrect, or no longer relevant. Provide the exact text content of the memory to remove (without the date prefix and bullet point).",
        "parameters": {
            "type": "object",
            "properties": {
                "content": {
                    "type": "string",
                    "description": "The exact text of the memory entry to remove (without the date prefix '- [YYYY-MM-DD] ')."
                }
            },
            "required": ["content"]
        }
    }
}
EOF
}

tool_memory_remove_execute() {
    local args_json="$1"
    local content
    content=$(echo "$args_json" | jq -r '.content')

    if [[ -z "$content" || "$content" == "null" ]]; then
        echo "Error: memory content to remove is required."
        return 1
    fi

    if [[ -z "$SHELLIA_MEMORY_FILE" || ! -f "$SHELLIA_MEMORY_FILE" ]]; then
        echo "Error: memory file not found."
        return 1
    fi

    # Escape special characters for grep
    local escaped_content
    escaped_content=$(printf '%s' "$content" | sed 's/[.[\*^$()+?{|]/\\&/g')

    # Check if the entry exists
    if ! grep -q "^\- \[.*\] ${escaped_content}$" "$SHELLIA_MEMORY_FILE" 2>/dev/null; then
        echo "Memory not found: ${content}"
        return 1
    fi

    # Remove the matching line(s)
    local tmp_file="${SHELLIA_MEMORY_FILE}.tmp.$$"
    grep -v "^\- \[.*\] ${escaped_content}$" "$SHELLIA_MEMORY_FILE" > "$tmp_file"
    mv "$tmp_file" "$SHELLIA_MEMORY_FILE"

    local total
    total=$(_memory_count_entries)
    debug_log "plugin:memory" "removed memory: ${content}"

    echo "Memory removed (${total} remaining): ${content}"
}

# --- REPL commands ---

repl_cmd_memory_handler() {
    local args="$*"
    local subcmd="${args%% *}"
    local remainder=""
    if [[ "$args" != "$subcmd" ]]; then
        remainder="${args#* }"
    fi

    case "$subcmd" in
        ""|show)
            _memory_show
            ;;
        edit)
            _memory_edit
            ;;
        add)
            _memory_add "$remainder"
            ;;
        remove|rm)
            _memory_remove_interactive "$remainder"
            ;;
        reset)
            _memory_reset
            ;;
        file)
            echo "$SHELLIA_MEMORY_FILE"
            ;;
        *)
            echo -e "${THEME_WARN}Unknown subcommand: ${subcmd}${NC}"
            echo "Usage: memory [show|edit|add <text>|remove <text>|reset|file]"
            ;;
    esac
}

repl_cmd_memory_help() {
    echo -e "  ${THEME_ACCENT}memory${NC}            View and manage persistent memories"
}

# --- Internal helpers ---

_memory_get_entries() {
    [[ -f "$SHELLIA_MEMORY_FILE" ]] || return 0
    # Return only bullet-point lines (memory entries)
    grep '^- \[' "$SHELLIA_MEMORY_FILE" 2>/dev/null || true
}

_memory_count_entries() {
    [[ -f "$SHELLIA_MEMORY_FILE" ]] || { echo 0; return 0; }
    local count
    count=$(grep -c '^- \[' "$SHELLIA_MEMORY_FILE" 2>/dev/null || echo 0)
    echo "$count"
}

_memory_show() {
    if [[ ! -f "$SHELLIA_MEMORY_FILE" ]]; then
        echo "No memories stored yet."
        return 0
    fi

    local entries
    entries=$(_memory_get_entries)

    if [[ -z "$entries" ]]; then
        echo "No memories stored yet."
        return 0
    fi

    local count
    count=$(_memory_count_entries)
    echo -e "${THEME_ACCENT}Memories (${count}):${NC}"
    echo "$entries"
    echo ""
    echo -e "${THEME_MUTED}File: ${SHELLIA_MEMORY_FILE}${NC}"
}

_memory_edit() {
    local editor="${EDITOR:-${VISUAL:-vi}}"
    if [[ -z "$SHELLIA_MEMORY_FILE" ]]; then
        log_warn "Memory file not initialized."
        return 1
    fi
    "$editor" "$SHELLIA_MEMORY_FILE"
    local count
    count=$(_memory_count_entries)
    log_info "Memory file saved (${count} entries)."
}

_memory_add() {
    local text="$1"
    if [[ -z "$text" ]]; then
        log_warn "Usage: memory add <text>"
        return 1
    fi

    local timestamp
    timestamp=$(date +%Y-%m-%d)
    echo "- [${timestamp}] ${text}" >> "$SHELLIA_MEMORY_FILE"

    local count
    count=$(_memory_count_entries)
    log_info "Memory saved (${count} total): ${text}"
}

_memory_remove_interactive() {
    local text="$1"
    if [[ -z "$text" ]]; then
        log_warn "Usage: memory remove <text>"
        echo "Provide the memory text to remove (without the date prefix)."
        return 1
    fi

    local escaped_text
    escaped_text=$(printf '%s' "$text" | sed 's/[.[\*^$()+?{|]/\\&/g')

    if ! grep -q "^\- \[.*\] ${escaped_text}$" "$SHELLIA_MEMORY_FILE" 2>/dev/null; then
        log_warn "Memory not found: ${text}"
        return 1
    fi

    local tmp_file="${SHELLIA_MEMORY_FILE}.tmp.$$"
    grep -v "^\- \[.*\] ${escaped_text}$" "$SHELLIA_MEMORY_FILE" > "$tmp_file"
    mv "$tmp_file" "$SHELLIA_MEMORY_FILE"

    local count
    count=$(_memory_count_entries)
    log_info "Memory removed (${count} remaining): ${text}"
}

_memory_reset() {
    if [[ ! -f "$SHELLIA_MEMORY_FILE" ]]; then
        echo "No memory file to reset."
        return 0
    fi

    local count
    count=$(_memory_count_entries)
    echo "# Shellia Memory" > "$SHELLIA_MEMORY_FILE"
    log_info "Cleared ${count} memories."
}
