#!/usr/bin/env bash
# REPL mode for shellia

# Start the REPL
repl_start() {
    local system_prompt
    system_prompt=$(build_system_prompt)

    # Create conversation temp file
    local conv_file
    conv_file="/tmp/shellia_conv_$(date +%s).json"
    echo '[]' > "$conv_file"

    # Cleanup on exit
    trap "rm -f '$conv_file'" EXIT INT TERM

    local dry_run_mode=false

    echo -e "${THEME_HEADER}shellia${NC} ${THEME_ACCENT}v${SHELLIA_VERSION}${NC} ${THEME_SEPARATOR}|${NC} model: ${THEME_ACCENT}${SHELLIA_MODEL}${NC} ${THEME_SEPARATOR}|${NC} type ${THEME_ACCENT}help${NC} for commands"
    echo -e "${THEME_SEPARATOR}$(printf '%.0s─' {1..50})${NC}"
    echo ""

    # Command history tracking (commands executed this session)
    local -a executed_commands=()

    # If piped input was provided, note it for the user
    if [[ -n "${PIPED_INPUT:-}" ]]; then
        log_info "Piped input received. It will be included as context for your first prompt."
    fi

    while true; do
        # Read user input
        local input
        if ! read -rep "$(echo -e "${THEME_PROMPT}shellia>${NC}") " input; then
            # Ctrl+D
            echo ""
            log_info "Goodbye."
            break
        fi

        # Skip empty input
        [[ -z "$input" ]] && continue

        # Handle built-in commands
        case "$input" in
            help)
                repl_help
                continue
                ;;
            reset)
                echo '[]' > "$conv_file"
                log_info "Conversation cleared."
                continue
                ;;
            history)
                repl_show_history "${executed_commands[@]+"${executed_commands[@]}"}"
                continue
                ;;
            exit|quit)
                log_info "Goodbye."
                break
                ;;
            model\ *)
                local new_model="${input#model }"
                SHELLIA_MODEL="$new_model"
                log_info "Switched to model: ${SHELLIA_MODEL}"
                continue
                ;;
            "dry-run on")
                dry_run_mode=true
                log_info "Dry-run mode enabled."
                continue
                ;;
            "dry-run off")
                dry_run_mode=false
                log_info "Dry-run mode disabled."
                continue
                ;;
            "debug on")
                SHELLIA_DEBUG=true
                log_info "Debug mode enabled."
                continue
                ;;
            "debug off")
                SHELLIA_DEBUG=false
                log_info "Debug mode disabled."
                continue
                ;;
            themes)
                list_themes
                continue
                ;;
            theme\ *)
                local new_theme="${input#theme }"
                SHELLIA_THEME="$new_theme"
                apply_theme "$new_theme"
                log_info "Switched to theme: ${new_theme}"
                continue
                ;;
        esac

        # Build the actual user message
        local user_message="$input"

        # Include piped input on first prompt only
        if [[ -n "${PIPED_INPUT:-}" ]]; then
            user_message="${input}

The following is the content piped as input for context:
${PIPED_INPUT}"
            PIPED_INPUT=""  # Clear after first use
        fi

        # Token estimate warning
        local conv_size
        conv_size=$(wc -c < "$conv_file")
        local token_estimate=$(( conv_size / 4 ))
        if [[ $token_estimate -gt 10000 ]]; then
            log_warn "Conversation is getting long (~${token_estimate} tokens). Consider 'reset' to start fresh."
        fi

        # Build messages with conversation history
        debug_log "repl" "user_message='${input}'"
        debug_log "repl" "conv_size=${conv_size} bytes (~${token_estimate} tokens)"
        local messages
        messages=$(build_conversation_messages "$system_prompt" "$conv_file" "$user_message")

        # Call API
        spinner_start "Thinking..."
        local response
        local api_exit=0
        response=$(api_chat "$messages") || api_exit=$?
        spinner_stop
        if [[ $api_exit -ne 0 ]]; then
            continue
        fi

        # Append user message and assistant response to conversation
        local updated
        updated=$(jq \
            --arg usr "$user_message" \
            --arg asst "$response" \
            '. + [{"role": "user", "content": $usr}, {"role": "assistant", "content": $asst}]' \
            "$conv_file")
        echo "$updated" > "$conv_file"

        # Handle the response
        echo ""
        handle_response "$response" "$dry_run_mode"

        # Track executed commands
        local first_line
        first_line=$(echo "$response" | head -n 1)
        if [[ "$first_line" == "[COMMAND]" ]]; then
            local cmd
            cmd=$(echo "$response" | tail -n +2 | sed '/^[[:space:]]*$/d' | head -n 1)
            executed_commands+=("$cmd")
        fi

        echo ""
    done
}

repl_help() {
    echo -e "${THEME_HEADER}Built-in commands:${NC}"
    echo -e "  ${THEME_ACCENT}help${NC}            Show this help"
    echo -e "  ${THEME_ACCENT}reset${NC}           Clear conversation history"
    echo -e "  ${THEME_ACCENT}history${NC}         Show commands executed this session"
    echo -e "  ${THEME_ACCENT}model ${THEME_MUTED}<id>${NC}      Switch model"
    echo -e "  ${THEME_ACCENT}dry-run ${THEME_MUTED}on/off${NC}  Toggle dry-run mode"
    echo -e "  ${THEME_ACCENT}themes${NC}          List available themes"
    echo -e "  ${THEME_ACCENT}theme ${THEME_MUTED}<name>${NC}    Switch theme"
    echo -e "  ${THEME_ACCENT}debug ${THEME_MUTED}on/off${NC}    Toggle debug mode"
    echo -e "  ${THEME_ACCENT}exit${NC} / ${THEME_ACCENT}quit${NC}     Exit shellia"
}

repl_show_history() {
    if [[ $# -eq 0 ]]; then
        echo "No commands executed this session."
        return
    fi
    echo "Commands executed this session:"
    local i=1
    for cmd in "$@"; do
        printf "  %d. %s\n" "$i" "$cmd"
        ((i++))
    done
}
