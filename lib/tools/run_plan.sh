#!/usr/bin/env bash
# Tool: run_plan — execute a multi-step plan

tool_run_plan_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "run_plan",
        "description": "Execute a multi-step plan of sequential shell commands. Each step has a description and a command. All steps are shown to the user for review before execution. Use this when a task requires multiple coordinated commands that should be reviewed as a whole before running.",
        "parameters": {
            "type": "object",
            "properties": {
                "steps": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "description": {
                                "type": "string",
                                "description": "What this step does and why"
                            },
                            "command": {
                                "type": "string",
                                "description": "The shell command to execute"
                            }
                        },
                        "required": ["description", "command"]
                    },
                    "description": "Ordered list of steps to execute sequentially"
                }
            },
            "required": ["steps"]
        }
    }
}
EOF
}

tool_run_plan_execute() {
    local args_json="$1"
    local plan_json
    plan_json=$(echo "$args_json" | jq '.steps')
    local step_count
    step_count=$(echo "$plan_json" | jq 'length')

    echo -e "${THEME_HEADER}Plan (${step_count} steps):${NC}" >&2
    echo "" >&2

    # Display all steps
    for ((i = 0; i < step_count; i++)); do
        local desc cmd
        desc=$(echo "$plan_json" | jq -r ".[$i].description")
        cmd=$(echo "$plan_json" | jq -r ".[$i].command")
        printf "  %d. %-35s -> %s\n" "$((i + 1))" "$desc" "$cmd" >&2
    done
    echo "" >&2

    # Dry-run check
    if [[ "${SHELLIA_DRY_RUN:-false}" == "true" ]]; then
        log_info "(dry-run: not executing)"
        echo "(dry-run: plan not executed)"
        return 0
    fi

    read -rp "Run all? [y/N]: " confirm </dev/tty
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_warn "Cancelled."
        echo "Plan cancelled by user."
        return 0
    fi

    echo "" >&2

    local results=""
    local shell_cmd
    shell_cmd=$(detect_shell)

    for ((i = 0; i < step_count; i++)); do
        local desc cmd
        desc=$(echo "$plan_json" | jq -r ".[$i].description")
        cmd=$(echo "$plan_json" | jq -r ".[$i].command")

        echo -e "${THEME_ACCENT}Step $((i + 1))/${step_count}: ${desc}${NC}" >&2

        local output
        local exit_code=0
        output=$("$shell_cmd" -c "$cmd" </dev/null 2>&1) || exit_code=$?

        if [[ -n "$output" ]]; then
            echo "$output" >&2
        fi

        if [[ $exit_code -ne 0 ]]; then
            echo -e "  ${THEME_ERROR}✗ Failed (exit code ${exit_code})${NC}" >&2

            # Show remaining steps
            if [[ $((i + 1)) -lt $step_count ]]; then
                log_warn "Remaining steps not executed:"
                for ((j = i + 1; j < step_count; j++)); do
                    local rdesc rcmd
                    rdesc=$(echo "$plan_json" | jq -r ".[$j].description")
                    rcmd=$(echo "$plan_json" | jq -r ".[$j].command")
                    printf "  %d. %-35s -> %s\n" "$((j + 1))" "$rdesc" "$rcmd" >&2
                done
            fi

            results="${results}Step $((i + 1)) (${desc}): FAILED (exit code ${exit_code})"
            [[ -n "$output" ]] && results="${results}\nOutput: ${output}"
            results="${results}\n"
            printf '%b' "$results"
            return $exit_code
        else
            echo -e "  ${THEME_SUCCESS}✓ Done${NC}" >&2
            results="${results}Step $((i + 1)) (${desc}): OK"
            [[ -n "$output" ]] && results="${results}\nOutput: ${output}"
            results="${results}\n"
        fi
    done

    echo "" >&2
    log_success "All ${step_count} steps completed successfully."
    printf '%b' "$results"
}
