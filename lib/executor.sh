#!/usr/bin/env bash
# Command execution and safety checks for bashia

# Load dangerous commands patterns into an array
load_dangerous_commands() {
    DANGEROUS_PATTERNS=()
    local danger_file="${BASHIA_DANGEROUS_FILE:-${BASHIA_DIR}/defaults/dangerous_commands}"

    if [[ -f "$danger_file" ]]; then
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
            DANGEROUS_PATTERNS+=("$pattern")
        done < "$danger_file"
    fi
}

# Check if a command matches any dangerous pattern
# Returns 0 if dangerous, 1 if safe
is_dangerous() {
    local cmd="$1"
    for pattern in "${DANGEROUS_PATTERNS[@]}"; do
        if [[ "$cmd" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

# Execute a single command with safety check
# Args: $1 = command string, $2 = dry_run (true/false, optional)
execute_command() {
    local cmd="$1"
    local dry_run="${2:-false}"

    echo -e "${DIM}\$ ${cmd}${NC}"

    if [[ "$dry_run" == "true" ]]; then
        return 0
    fi

    # Safety check
    if is_dangerous "$cmd"; then
        echo -e "${YELLOW}Warning: This command matches a dangerous pattern.${NC}"
        read -rp "Run this? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_warn "Skipped."
            return 0
        fi
    fi

    # Detect shell and execute
    local shell_cmd
    shell_cmd=$(detect_shell)

    local exit_code=0
    "$shell_cmd" -c "$cmd" || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error "Command exited with code ${exit_code}"
    fi

    return $exit_code
}

# Execute a multi-step plan
# Args: $1 = JSON plan array string, $2 = dry_run (true/false, optional)
execute_plan() {
    local plan_json="$1"
    local dry_run="${2:-false}"

    local step_count
    step_count=$(echo "$plan_json" | jq 'length')

    echo -e "${BOLD}Plan (${step_count} steps):${NC}"
    echo ""

    # Display all steps
    for ((i = 0; i < step_count; i++)); do
        local desc cmd
        desc=$(echo "$plan_json" | jq -r ".[$i].description")
        cmd=$(echo "$plan_json" | jq -r ".[$i].command")
        printf "  %d. %-35s -> %s\n" "$((i + 1))" "$desc" "$cmd"
    done

    echo ""

    if [[ "$dry_run" == "true" ]]; then
        log_info "(dry-run: not executing)"
        return 0
    fi

    read -rp "Run all? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_warn "Cancelled."
        return 0
    fi

    echo ""

    # Execute each step
    for ((i = 0; i < step_count; i++)); do
        local desc cmd
        desc=$(echo "$plan_json" | jq -r ".[$i].description")
        cmd=$(echo "$plan_json" | jq -r ".[$i].command")

        echo -e "${BOLD}Step $((i + 1))/${step_count}: ${desc}${NC}"

        local shell_cmd
        shell_cmd=$(detect_shell)

        local exit_code=0
        "$shell_cmd" -c "$cmd" || exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            echo -e "  ${RED}✗ Failed (exit code ${exit_code})${NC}"
            echo ""

            # Show remaining steps
            if [[ $((i + 1)) -lt $step_count ]]; then
                log_warn "Remaining steps not executed:"
                for ((j = i + 1; j < step_count; j++)); do
                    local rdesc rcmd
                    rdesc=$(echo "$plan_json" | jq -r ".[$j].description")
                    rcmd=$(echo "$plan_json" | jq -r ".[$j].command")
                    printf "  %d. %-35s -> %s\n" "$((j + 1))" "$rdesc" "$rcmd"
                done
            fi
            return $exit_code
        else
            echo -e "  ${GREEN}✓ Done${NC}"
        fi
    done

    echo ""
    log_success "All ${step_count} steps completed successfully."
}
