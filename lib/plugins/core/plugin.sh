#!/usr/bin/env bash
# Plugin: core — essential CLI subcommands

plugin_core_info() {
    echo "Core CLI commands (init, plugins)"
}

plugin_core_hooks() {
    echo ""
}

# === CLI subcommands ===

# --- init ---
cli_cmd_init_handler() {
    shellia_init
}

cli_cmd_init_help() {
    echo "  init                      Run setup wizard"
}

cli_cmd_init_setup() {
    echo ""
}

# --- plugins ---
cli_cmd_plugins_handler() {
    list_plugins
}

cli_cmd_plugins_help() {
    echo "  plugins                   List loaded plugins"
}

cli_cmd_plugins_setup() {
    echo "config theme tools plugins"
}

# --- REPL: plugins (convenience alias) ---
repl_cmd_plugins_handler() {
    list_plugins
}

repl_cmd_plugins_help() {
    echo -e "  ${THEME_ACCENT}plugins${NC}           List loaded plugins"
}

_core_compact_prompt() {
    cat <<'EOF'
You are a helpful AI assistant tasked with summarizing conversations.

When asked to summarize, provide a detailed but concise summary of the conversation.
Focus on information that would be helpful for continuing the conversation, including:
- What was done
- What is currently being worked on
- Which files are being modified
- What needs to be done next
- Key user requests, constraints, or preferences that should persist
- Important technical decisions and why they were made

Your summary should be comprehensive enough to provide context but concise enough to be quickly understood.

Do not respond to any questions in the conversation, only output the summary.
EOF
}

_core_compact_transcript() {
    local conv_file="$1"

    jq -r '.[] | "\(.role):\n\(.content)\n"' "$conv_file"
}

# REPL command: compact
repl_cmd_compact_handler() {
    local args="$*"
    if [[ -n "$args" ]]; then
        log_warn "Usage: compact"
        return 1
    fi

    if [[ -z "${SHELLIA_CONV_FILE:-}" || ! -f "$SHELLIA_CONV_FILE" ]]; then
        log_warn "Conversation file not found; nothing to compact."
        return 1
    fi

    if ! jq -e 'type == "array"' "$SHELLIA_CONV_FILE" >/dev/null 2>&1; then
        log_warn "Conversation file is invalid; unable to compact."
        return 1
    fi

    if jq -e 'length == 0' "$SHELLIA_CONV_FILE" >/dev/null 2>&1; then
        log_info "Conversation is empty; nothing to compact."
        return 0
    fi

    local transcript
    transcript=$(_core_compact_transcript "$SHELLIA_CONV_FILE")

    local prompt
    prompt=$(_core_compact_prompt)

    local user_message="Summarize this conversation transcript:\n\n${transcript}"
    local messages
    messages=$(build_single_messages "$prompt" "$user_message")

    local summary
    summary=$(api_chat_loop "$messages" '[]') || {
        log_warn "Compaction failed: could not generate summary."
        return 1
    }

    if [[ -z "$summary" ]]; then
        log_warn "Compaction failed: summary was empty."
        return 1
    fi

    local updated
    updated=$(jq -n --arg asst "$summary" '[{"role":"assistant","content":$asst}]')
    printf '%s\n' "$updated" > "$SHELLIA_CONV_FILE"

    fire_hook "conversation_reset"
    log_info "Conversation compacted. Started a new context with summary."
}

repl_cmd_compact_help() {
    echo -e "  ${THEME_ACCENT}compact${NC}           Summarize and reset context"
}
