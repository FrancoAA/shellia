#!/usr/bin/env bash
# REPL mode for bashia

# Start the REPL
repl_start() {
    local system_prompt
    system_prompt=$(build_system_prompt)

    # Create conversation temp file
    local conv_file
    conv_file="/tmp/bashia_conv_$(date +%s).json"
    echo '[]' > "$conv_file"

    # Cleanup on exit
    trap "rm -f '$conv_file'" EXIT INT TERM

    local dry_run_mode=false

    echo -e "${BOLD}bashia v${BASHIA_VERSION}${NC} | model: ${BASHIA_MODEL} | type 'help' for commands"
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
        if ! read -rep "bashia> " input; then
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
                BASHIA_MODEL="$new_model"
                log_info "Switched to model: ${BASHIA_MODEL}"
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
    echo "Built-in commands:"
    echo "  help            Show this help"
    echo "  reset           Clear conversation history"
    echo "  history         Show commands executed this session"
    echo "  model <id>      Switch model"
    echo "  dry-run on/off  Toggle dry-run mode"
    echo "  exit / quit     Exit bashia"
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
