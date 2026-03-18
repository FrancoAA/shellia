#!/usr/bin/env bash
# Tool: run_command — execute a shell command

tool_run_command_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "run_command",
        "description": "Execute a shell command in the user's terminal. Use this for any single command, pipeline, loop, heredoc, or script. The command runs in the user's current shell and working directory. Output (stdout and stderr) is captured and returned. IMPORTANT: Commands run non-interactively with no stdin — interactive prompts will receive EOF immediately. Always use non-interactive flags (e.g. npx --yes, apt-get -y, pip install --no-input, git commit -m 'msg') to avoid failures.",
        "parameters": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The shell command to execute"
                }
            },
            "required": ["command"]
        }
    }
}
EOF
}

tool_run_command_execute() {
    local args_json="$1"
    local cmd
    cmd=$(echo "$args_json" | jq -r '.command')

    debug_log "tool" "run_command: ${cmd}"
    tool_trace "\$ ${cmd}"

    # Dry-run check
    if [[ "${SHELLIA_DRY_RUN:-false}" == "true" ]]; then
        debug_log "tool" "skipped (dry-run)"
        echo "(dry-run: command not executed)"
        return 0
    fi

    # Execute
    local shell_cmd
    shell_cmd=$(detect_shell)
    debug_log "tool" "shell=${shell_cmd}"

    local timeout_secs="${SHELLIA_CMD_TIMEOUT:-120}"
    local tmpfile
    tmpfile=$(mktemp)

    # Run command in background with stdin closed (/dev/null)
    "$shell_cmd" -c "$cmd" </dev/null >"$tmpfile" 2>&1 &
    local cmd_pid=$!

    # Wait for command or timeout
    local elapsed=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
        if [[ $elapsed -ge $timeout_secs ]]; then
            kill -TERM "$cmd_pid" 2>/dev/null
            sleep 1
            kill -9 "$cmd_pid" 2>/dev/null
            wait "$cmd_pid" 2>/dev/null
            local output
            output=$(cat "$tmpfile")
            rm -f "$tmpfile"

            echo -e "${THEME_ERROR}Command timed out after ${timeout_secs}s${NC}" >&2
            if [[ -n "$output" ]]; then
                echo "$output" >&2
            fi

            if [[ -n "$output" ]]; then
                printf '%s\n[timed out after %ds — command killed]' "$output" "$timeout_secs"
            else
                printf '[timed out after %ds — command killed]' "$timeout_secs"
            fi
            return 1
        fi
        sleep 1
        ((elapsed++))
    done

    local exit_code=0
    wait "$cmd_pid" || exit_code=$?

    local output
    output=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if [[ $exit_code -ne 0 ]]; then
        echo -e "${THEME_ERROR}Command exited with code ${exit_code}${NC}" >&2
    fi

    # Print output to stderr so the user sees it
    if [[ -n "$output" ]]; then
        echo "$output" >&2
    fi

    # Return output + exit code to the LLM
    if [[ -n "$output" ]]; then
        printf '%s\n[exit code: %d]' "$output" "$exit_code"
    else
        printf '[exit code: %d]' "$exit_code"
    fi
}
