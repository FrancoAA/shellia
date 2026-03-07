#!/usr/bin/env bash
# Tool: run_command — execute a shell command

tool_run_command_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "run_command",
        "description": "Execute a shell command in the user's terminal. Use this for any single command, pipeline, loop, heredoc, or script. The command runs in the user's current shell and working directory. Output (stdout and stderr) is captured and returned.",
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
    echo -e "${THEME_CMD}\$ ${cmd}${NC}" >&2

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

    local output
    local exit_code=0
    output=$("$shell_cmd" -c "$cmd" 2>&1) || exit_code=$?

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
