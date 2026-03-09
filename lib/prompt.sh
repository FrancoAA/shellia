#!/usr/bin/env bash
# System prompt assembly for bashia

# Build the full system prompt from base + user additions
# Args: $1 = mode (interactive, single-prompt, pipe)
build_system_prompt() {
    local mode="${1:-single-prompt}"
    local shell_name
    shell_name=$(detect_shell)

    local base_prompt
    base_prompt=$(cat "${SHELLIA_DIR}/defaults/system_prompt.txt")

    # Append shell context
    base_prompt="${base_prompt}

CONTEXT:
- User's shell: ${shell_name}
- Operating system: $(uname -s)
- Current directory: $(pwd)
- Mode: ${mode}
- shellia install directory: ${SHELLIA_DIR}
- shellia config directory: ${SHELLIA_CONFIG_DIR}
- User plugins directory: ${SHELLIA_CONFIG_DIR}/plugins"

    # Append user's custom prompt additions (skip comments and empty lines)
    if [[ -f "$SHELLIA_USER_PROMPT_FILE" ]]; then
        local user_additions
        user_additions=$(grep -v '^[[:space:]]*#' "$SHELLIA_USER_PROMPT_FILE" | grep -v '^[[:space:]]*$' || true)
        if [[ -n "$user_additions" ]]; then
            base_prompt="${base_prompt}

USER PREFERENCES:
${user_additions}"
        fi
    fi

    # Plugin prompt additions
    local plugin_additions
    plugin_additions=$(fire_prompt_hook "$mode")
    if [[ -n "$plugin_additions" ]]; then
        base_prompt="${base_prompt}
${plugin_additions}"
    fi

    debug_log "shell" "$shell_name"
    debug_block "system_prompt" "$base_prompt" 5

    echo "$base_prompt"
}

# Detect current shell
detect_shell() {
    local shell_path="${SHELL:-/bin/bash}"
    basename "$shell_path"
}
