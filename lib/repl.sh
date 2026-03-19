#!/usr/bin/env bash
# REPL mode for shellia

# Global conversation file (accessible by plugins)
SHELLIA_CONV_FILE=""
SHELLIA_REPL_INTERRUPTED=false

_repl_cleanup() {
    spinner_stop
    [[ -n "${SHELLIA_CONV_FILE:-}" ]] && rm -f "$SHELLIA_CONV_FILE"
}

_repl_handle_sigint() {
    SHELLIA_REPL_INTERRUPTED=true
    spinner_stop
    echo "" >&2
    log_info "Cancelled."
}

_repl_read_input() {
    local prompt="$1"
    local continuation_prompt="$2"
    local line

    if ! read -rep "$prompt" line; then
        if [[ "${SHELLIA_REPL_INTERRUPTED:-false}" == "true" ]]; then
            return 130
        fi
        return 1
    fi

    local message="$line"
    while [[ "$line" == *\\ ]]; do
        message="${message%\\}"
        message+=$'\n'

        if ! read -rep "$continuation_prompt" line; then
            if [[ "${SHELLIA_REPL_INTERRUPTED:-false}" == "true" ]]; then
                return 130
            fi
            return 1
        fi

        message+="$line"
    done

    printf '%s' "$message"
}

_repl_prompt_label() {
    local mode_label="${SHELLIA_AGENT_MODE:-build}"
    local mode_color="\033[0;35m"
    local mode_segment="(mode: ${mode_color}${mode_label}${THEME_PROMPT})"

    if [[ "${SHELLIA_DOCKER_SANDBOX_ACTIVE:-false}" == "true" ]]; then
        echo "${mode_segment} ${THEME_WARN}(sandboxed)${THEME_PROMPT}"
    else
        echo "${mode_segment}"
    fi
}

# Start the REPL
repl_start() {
    # Create conversation temp file (global so plugins can access it)
    SHELLIA_CONV_FILE="/tmp/shellia_conv_$(date +%s).json"
    echo '[]' > "$SHELLIA_CONV_FILE"

    # Cleanup and signal handling
    trap '_repl_cleanup' EXIT TERM
    trap '_repl_handle_sigint' INT

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
        local _repl_label
        _repl_label=$(_repl_prompt_label)
        local _repl_prompt
        _repl_prompt=$(echo -e "${THEME_PROMPT}${_repl_label} >${NC} ")
        local _repl_continue_prompt
        _repl_continue_prompt=$(echo -e "${THEME_MUTED}...>${NC} ")
        local read_exit=0
        input=$(_repl_read_input "$_repl_prompt" "$_repl_continue_prompt") || read_exit=$?
        if [[ $read_exit -ne 0 ]]; then
            if [[ $read_exit -eq 130 ]]; then
                SHELLIA_REPL_INTERRUPTED=false
                continue
            fi
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
            SHELLIA_REPL_INTERRUPTED=false
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
