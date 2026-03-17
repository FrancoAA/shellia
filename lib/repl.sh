#!/usr/bin/env bash
# REPL mode for shellia

# Global conversation file (accessible by plugins)
SHELLIA_CONV_FILE=""

# Start the REPL
repl_start() {
    # Create conversation temp file (global so plugins can access it)
    SHELLIA_CONV_FILE="/tmp/shellia_conv_$(date +%s).json"
    echo '[]' > "$SHELLIA_CONV_FILE"

    # Cleanup on exit
    trap 'rm -f "$SHELLIA_CONV_FILE"' EXIT INT TERM

    # Build tools array (rebuilt each turn in case mode changes)
    local tools
    tools=$(build_tools_array)

    local profile_label=""
    if [[ -f "$SHELLIA_PROFILES_FILE" ]]; then
        profile_label=" ${THEME_SEPARATOR}|${NC} profile: ${THEME_ACCENT}${SHELLIA_PROFILE:-default}${NC}"
    fi
    echo -e "${THEME_HEADER}shellia${NC} ${THEME_ACCENT}v${SHELLIA_VERSION}${NC} ${THEME_SEPARATOR}|${NC} model: ${THEME_ACCENT}${SHELLIA_MODEL}${NC}${profile_label} ${THEME_SEPARATOR}|${NC} mode: ${THEME_ACCENT}${SHELLIA_AGENT_MODE:-build}${NC} ${THEME_SEPARATOR}|${NC} type ${THEME_ACCENT}help${NC} for commands"
    echo -e "${THEME_SEPARATOR}$(printf '%.0s─' {1..50})${NC}"
    echo ""

    # If piped input was provided, note it for the user
    if [[ -n "${PIPED_INPUT:-}" ]]; then
        log_info "Piped input received. It will be included as context for your first prompt."
    fi

    while true; do
        # Read user input
        local input
        local _repl_label="shellia"
        if [[ "${SHELLIA_DOCKER_SANDBOX_ACTIVE:-false}" == "true" ]]; then
            _repl_label="shellia ${THEME_WARN}(sandboxed)${THEME_PROMPT}"
        fi
        if ! read -rep "$(echo -e "${THEME_PROMPT}${_repl_label}>${NC}") " input; then
            # Ctrl+D
            echo ""
            fire_hook "shutdown"
            log_info "Goodbye."
            break
        fi

        # Skip empty input
        [[ -z "$input" ]] && continue

        # Handle built-in commands (structural — not pluggable)
        case "$input" in
            help)
                repl_help
                continue
                ;;
            reset)
                echo '[]' > "$SHELLIA_CONV_FILE"
                fire_hook "conversation_reset"
                log_info "Conversation cleared."
                continue
                ;;
            reload)
                repl_reload
                # Rebuild tools array with freshly loaded code
                tools=$(build_tools_array)
                continue
                ;;
            exit|quit)
                fire_hook "shutdown"
                log_info "Goodbye."
                break
                ;;
        esac

        # Try plugin REPL commands
        local cmd_word="${input%% *}"
        local cmd_args="${input#* }"
        [[ "$cmd_word" == "$input" ]] && cmd_args=""
        if dispatch_repl_command "$cmd_word" "$cmd_args"; then
            continue
        fi

        # Rebuild tools every turn so runtime mode switches apply immediately.
        tools=$(build_tools_array)

        # Build a fresh system prompt for this turn (to include one-shot skill context if set).
        local system_prompt
        system_prompt=$(build_system_prompt "interactive")
        SHELLIA_LOADED_SKILL_CONTENT=""
        SHELLIA_LOADED_SKILL_NAME=""

        # Build the actual user message
        local user_message="$input"

        # Include piped input on first prompt only
        if [[ -n "${PIPED_INPUT:-}" ]]; then
            user_message="${input}

The following is the content piped as input for context:
${PIPED_INPUT}"
            PIPED_INPUT=""  # Clear after first use
        fi

        fire_hook "user_message" "$user_message"

        # Token estimate warning
        local conv_size
        conv_size=$(wc -c < "$SHELLIA_CONV_FILE")
        local token_estimate=$(( conv_size / 4 ))
        if [[ $token_estimate -gt 10000 ]]; then
            log_warn "Conversation is getting long (~${token_estimate} tokens). Consider 'reset' to start fresh."
        fi

        # Build messages with conversation history
        debug_log "repl" "user_message='${input}'"
        debug_log "repl" "conv_size=${conv_size} bytes (~${token_estimate} tokens)"
        local messages
        messages=$(build_conversation_messages "$system_prompt" "$SHELLIA_CONV_FILE" "$user_message")

        # Call API with tool loop
        spinner_start "Thinking..."
        local response
        local api_exit=0
        response=$(api_chat_loop "$messages" "$tools") || api_exit=$?
        spinner_stop
        if [[ $api_exit -ne 0 ]]; then
            continue
        fi

        fire_hook "assistant_message" "$response"

        # Update conversation history with user message and final assistant response
        local assistant_content="${response:-}"
        local updated
        updated=$(jq \
            --arg usr "$user_message" \
            --arg asst "$assistant_content" \
            '. + [{"role": "user", "content": $usr}, {"role": "assistant", "content": $asst}]' \
            "$SHELLIA_CONV_FILE")
        echo "$updated" > "$SHELLIA_CONV_FILE"

        # Display the final text response with markdown formatting
        echo ""
        if [[ -n "$response" ]]; then
            echo "$response" | format_markdown
        fi

        echo ""
    done
}

repl_reload() {
    # Re-source all library modules to pick up code changes
    local modules=(
        utils.sh config.sh profiles.sh prompt.sh api.sh
        executor.sh themes.sh tools.sh repl.sh plugins.sh
    )
    local mod
    for mod in "${modules[@]}"; do
        source "${SHELLIA_DIR}/lib/${mod}"
    done

    # Reload plugins (handles re-registration of hooks)
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
    load_plugins

    # Reload config, theme, and tools
    load_config
    apply_theme "${SHELLIA_THEME:-default}"
    load_tools
    fire_hook "init"

    log_info "Reloaded all modules, plugins, config, and tools."
}

repl_help() {
    echo -e "${THEME_HEADER}Built-in commands:${NC}"
    echo -e "  ${THEME_ACCENT}help${NC}              Show this help"
    echo -e "  ${THEME_ACCENT}reset${NC}             Clear conversation history"
    echo -e "  ${THEME_ACCENT}reload${NC}            Reload all scripts and plugins"
    echo -e "  ${THEME_ACCENT}exit${NC} / ${THEME_ACCENT}quit${NC}       Exit shellia"

    local plugin_help
    plugin_help=$(get_plugin_repl_help)
    if [[ -n "$plugin_help" ]]; then
        echo ""
        echo -e "${THEME_HEADER}Plugin commands:${NC}"
        echo "$plugin_help"
    fi
}
