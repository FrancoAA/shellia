#!/usr/bin/env bash
# Plugin: ralp — LLM-driven PRD interview + Claude iteration loop

plugin_ralp_info() {
    echo "LLM-driven PRD interview that feeds into a Claude iteration loop"
}

plugin_ralp_hooks() {
    echo ""
}

# Parse ralp command arguments
# Usage: _ralp_parse_args <topic_var> <max_iter_var> [args...]
# Sets topic_var to the topic string (may be empty)
# Sets max_iter_var to the resolved max iterations
_ralp_parse_args() {
    local __topic_var="$1"
    local __max_iter_var="$2"
    shift 2

    local __topic=""
    local __max_iter
    __max_iter=$(plugin_config_get "ralp" "max_iterations" "5")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-iterations=*)
                local __extracted="${1#*=}"
                if [[ -n "$__extracted" ]]; then
                    __max_iter="$__extracted"
                fi
                shift
                ;;
            --max-iterations)
                if [[ $# -ge 2 ]]; then
                    __max_iter="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            *)
                if [[ -z "$__topic" ]]; then
                    __topic="$1"
                fi
                shift
                ;;
        esac
    done

    printf -v "$__topic_var" '%s' "$__topic"
    printf -v "$__max_iter_var" '%s' "$__max_iter"
}

# Generate a URL-friendly slug from PRD content
# Looks for the first "# PRD: <title>" line; falls back to timestamp
_ralp_prd_slug() {
    local prd_content="$1"
    local title

    # Try to extract title from "# PRD: <title>" line
    title=$(echo "$prd_content" | grep -m1 '^# PRD:' | sed 's/^# PRD:[[:space:]]*//')

    if [[ -z "$title" ]]; then
        # Fallback: use timestamp
        echo "prd-$(date +%Y%m%d-%H%M%S)"
        return 0
    fi

    # Slugify: lowercase, replace non-alphanumeric runs with hyphens, trim hyphens
    echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//;s/-$//'
}

# Write the PRD content to a file in the given directory
# Prints the full path of the written file on stdout
_ralp_write_prd() {
    local prd_content="$1"
    local outdir="${2:-.}"

    mkdir -p "$outdir" || { log_error "ralp: cannot create directory '${outdir}'"; return 1; }

    local slug
    slug=$(_ralp_prd_slug "$prd_content")

    local outfile="${outdir}/prd-${slug}.md"
    printf '%s\n' "$prd_content" > "$outfile"
    echo "$outfile"
}

# Check if a response contains the interview complete sentinel.
# Outputs "0" if not found, or "1" followed by the PRD content (one line per line) if found.
# The sentinel line itself is stripped from the output.
# Usage:
#   sentinel_output=$(_ralp_check_sentinel "$response")
#   found=$(echo "$sentinel_output" | head -n1)
#   prd=$(echo "$sentinel_output" | tail -n +2)
_ralp_check_sentinel() {
    local response="$1"

    if [[ "$response" != *"[INTERVIEW_COMPLETE]"* ]]; then
        echo "0"
        return 0
    fi

    local prd_content
    prd_content=$(echo "$response" | awk '/\[INTERVIEW_COMPLETE\]/{found=1; next} found{print}')

    echo "1"
    echo "$prd_content"
}

# Ensure cclean is installed; install it if not found
_ralp_ensure_cclean() {
    if ! command -v cclean &>/dev/null; then
        log_info "Installing cclean for pretty output..."
        if ! curl -fsSL https://raw.githubusercontent.com/ariel-frischer/claude-clean/main/install.sh | sh; then
            log_error "Failed to install cclean. Continuing without pretty output."
            return 1
        fi
    fi
    return 0
}

# Run the claude iteration loop with the given PRD content
# Args: $1 = prd_content, $2 = max_iterations
_ralp_run_claude_loop() {
    local prd_content="$1"
    local max_iterations="$2"

    # Validate max_iterations is a positive integer
    if ! [[ "$max_iterations" =~ ^[1-9][0-9]*$ ]]; then
        log_error "ralp: max_iterations must be a positive integer, got: '${max_iterations}'"
        return 1
    fi

    # Ensure claude is available
    if ! command -v claude &>/dev/null; then
        log_error "'claude' CLI not found. Install it from: https://claude.ai/code"
        return 1
    fi

    _ralp_ensure_cclean
    local cclean_available=0
    command -v cclean &>/dev/null && cclean_available=1

    echo -e "${THEME_HEADER}Starting Claude loop: ${max_iterations} iteration(s)${NC}"
    echo -e "${THEME_SEPARATOR}$(printf '%.0s─' {1..50})${NC}"

    local i
    for ((i=1; i<=max_iterations; i++)); do
        echo ""
        echo -e "${THEME_ACCENT}=== Iteration ${i} of ${max_iterations} ===${NC}"
        echo ""

        if [[ $cclean_available -eq 1 ]]; then
            claude -p "$prd_content" \
                --dangerously-skip-permissions \
                --output-format stream-json | cclean
            local claude_exit="${PIPESTATUS[0]}"
        else
            claude -p "$prd_content" \
                --dangerously-skip-permissions \
                --output-format stream-json
            local claude_exit=$?
        fi

        if [[ $claude_exit -ne 0 ]]; then
            log_error "claude exited with code ${claude_exit} on iteration ${i}. Stopping loop."
            return 1
        fi

        if [[ $i -lt $max_iterations ]]; then
            echo ""
            echo -e "${THEME_MUTED}--- Completed iteration ${i}, continuing... ---${NC}"
        fi
    done

    echo ""
    echo -e "${THEME_SEPARATOR}$(printf '%.0s─' {1..50})${NC}"
    echo -e "${THEME_SUCCESS}Ralph loop completed after ${max_iterations} iteration(s).${NC}"
}

# Run the PRD interview sub-loop.
# Args: $1 = initial topic (may be empty), $2 = max_iterations (unused here, for context only)
# On success: prints file path on line 1, PRD content on lines 2+, returns 0
# On abort/error: returns 1
_ralp_interview_loop() {
    local topic="$1"
    local prd_dir
    prd_dir=$(plugin_config_get "ralp" "prd_dir" ".")

    # Load the interview system prompt
    local plugin_dir
    plugin_dir="$(dirname "${BASH_SOURCE[0]}")"
    local interview_prompt_file="${plugin_dir}/interview_prompt.txt"

    if [[ ! -f "$interview_prompt_file" ]]; then
        log_error "Interview prompt not found: ${interview_prompt_file}"
        return 1
    fi

    local system_prompt
    system_prompt=$(cat "$interview_prompt_file")

    # Append current directory context
    system_prompt="${system_prompt}

CONTEXT:
- Current directory: $(pwd)
- Files in current directory: $(ls -1 2>/dev/null | head -20 | tr '\n' ', ' | sed 's/,$//')"

    # Temp conversation file for the interview
    local conv_file
    conv_file=$(mktemp /tmp/shellia_ralp_XXXXXX.json)
    echo '[]' > "$conv_file"
    trap "rm -f '$conv_file'" RETURN

    local prompt_str
    prompt_str="$(echo -e "${THEME_ACCENT}ralp>${NC}") "

    echo -e "${THEME_HEADER}RALP — PRD Interview${NC}" >&2
    echo -e "${THEME_SEPARATOR}$(printf '%.0s─' {1..50})${NC}" >&2
    echo -e "${THEME_MUTED}I'll ask you a few questions to build a PRD, then launch Claude.${NC}" >&2
    echo -e "${THEME_MUTED}Type 'abort' at any time to cancel.${NC}" >&2
    echo "" >&2

    # If a topic was provided, use it as the opening user message
    # Otherwise ask the LLM to open the interview
    local user_message
    if [[ -n "$topic" ]]; then
        user_message="$topic"
    else
        user_message="Let's start. Please ask me the first question."
    fi

    while true; do
        # Build messages with conversation history
        local messages
        messages=$(build_conversation_messages "$system_prompt" "$conv_file" "$user_message")

        # Call API
        spinner_start "Thinking..."
        local response
        local api_exit=0
        response=$(api_chat_loop "$messages" "[]") || api_exit=$?
        spinner_stop

        if [[ $api_exit -ne 0 ]]; then
            log_error "API call failed. Type 'abort' to exit or try again."
        else
            # Check for sentinel
            local sentinel_output
            sentinel_output=$(_ralp_check_sentinel "$response")
            local sentinel_found
            sentinel_found=$(echo "$sentinel_output" | head -n1)
            local prd_content
            prd_content=$(echo "$sentinel_output" | tail -n +2)

            if [[ "$sentinel_found" == "1" ]]; then
                # Guard: empty PRD body means the LLM sent sentinel prematurely
                if [[ -z "${prd_content// /}" ]]; then
                    log_error "Interview complete signal received but PRD is empty. Continuing..." >&2
                    # Don't update conv or exit — treat as a regular turn and let user respond
                else
                    # Show any text before the sentinel
                    local before_sentinel
                    before_sentinel=$(echo "$response" | awk '/\[INTERVIEW_COMPLETE\]/{exit} {print}')
                    if [[ -n "$before_sentinel" ]]; then
                        echo "" >&2
                        echo "$before_sentinel" | format_markdown >&2
                    fi

                    echo "" >&2
                    echo -e "${THEME_SUCCESS}Interview complete. Writing PRD...${NC}" >&2

                    # Write PRD file
                    local outfile
                    outfile=$(_ralp_write_prd "$prd_content" "$prd_dir")

                    echo -e "${THEME_SUCCESS}PRD saved: ${outfile}${NC}" >&2
                    echo "" >&2

                    # Update conversation file
                    local updated
                    updated=$(jq \
                        --arg usr "$user_message" \
                        --arg asst "$response" \
                        '. + [{"role": "user", "content": $usr}, {"role": "assistant", "content": $asst}]' \
                        "$conv_file")
                    echo "$updated" > "$conv_file"

                    # Output: line 1 = file path, rest = PRD content
                    echo "$outfile"
                    echo "$prd_content"
                    return 0
                fi
            else
                # No sentinel — display response and continue
                echo "" >&2
                echo "$response" | format_markdown >&2
                echo "" >&2

                # Update conversation history
                local updated
                updated=$(jq \
                    --arg usr "$user_message" \
                    --arg asst "$response" \
                    '. + [{"role": "user", "content": $usr}, {"role": "assistant", "content": $asst}]' \
                    "$conv_file")
                echo "$updated" > "$conv_file"
            fi
        fi

        # Read next user input
        local line
        if ! read -rep "$prompt_str" line; then
            # Ctrl+D
            echo "" >&2
            log_info "Interview aborted."
            return 1
        fi

        [[ -z "$line" ]] && continue

        if [[ "$line" == "abort" || "$line" == "quit" || "$line" == "exit" ]]; then
            log_info "Interview aborted."
            return 1
        fi

        user_message="$line"
    done
}

# REPL command: ralp [topic] [--max-iterations=N]
repl_cmd_ralp_handler() {
    local args="${1:-}"

    # Parse args (REPL dispatch passes all args as a single string in $1)
    local topic max_iterations
    # shellcheck disable=SC2086
    _ralp_parse_args topic max_iterations $args

    # Run the interview loop
    # stdout: line 1 = PRD file path, lines 2+ = PRD content
    # stderr: all UX output
    local interview_output
    local interview_exit=0
    interview_output=$(_ralp_interview_loop "$topic") || interview_exit=$?

    if [[ $interview_exit -ne 0 ]]; then
        return 0  # Aborted cleanly — not an error from the user's perspective
    fi

    # Parse the output
    local prd_file
    prd_file=$(echo "$interview_output" | head -n1)
    local prd_content
    prd_content=$(echo "$interview_output" | tail -n +2)

    # Confirm before launching claude loop
    local confirm
    read -rp "$(echo -e "${THEME_ACCENT}Launch Claude loop (${max_iterations} iterations)? [Y/n]:${NC} ")" confirm
    confirm="${confirm:-Y}"

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        _ralp_run_claude_loop "$prd_content" "$max_iterations"
    else
        log_info "Claude loop skipped. PRD is at: ${prd_file}"
    fi
}

repl_cmd_ralp_help() {
    echo -e "  ${THEME_ACCENT}ralp [topic] [--max-iterations=N]${NC}  PRD interview + Claude loop"
}
