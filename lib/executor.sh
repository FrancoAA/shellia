#!/usr/bin/env bash
# Command execution and safety checks for bashia

# Load dangerous commands patterns into an array
load_dangerous_commands() {
    DANGEROUS_PATTERNS=()
    local danger_file="${SHELLIA_DANGEROUS_FILE:-${SHELLIA_DIR}/defaults/dangerous_commands}"

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
    for pattern in "${DANGEROUS_PATTERNS[@]+"${DANGEROUS_PATTERNS[@]}"}"; do
        if [[ "$cmd" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

