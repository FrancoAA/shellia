#!/usr/bin/env bash
# Plugin: history — persistent conversation history

SHELLIA_HISTORY_DIR=""
SHELLIA_HISTORY_SESSION_FILE=""

plugin_history_info() {
    echo "Persistent conversation history with session management"
}

plugin_history_hooks() {
    echo "init prompt_build user_message assistant_message shutdown conversation_reset"
}

plugin_history_on_init() {
    SHELLIA_HISTORY_DIR="${SHELLIA_CONFIG_DIR}/history"
    mkdir -p "$SHELLIA_HISTORY_DIR"

    # Start a new session file
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    SHELLIA_HISTORY_SESSION_FILE="${SHELLIA_HISTORY_DIR}/session_${timestamp}.jsonl"
    debug_log "plugin:history" "session file: ${SHELLIA_HISTORY_SESSION_FILE}"
}

plugin_history_on_prompt_build() {
    local mode="$1"
    [[ -z "$SHELLIA_HISTORY_DIR" || ! -d "$SHELLIA_HISTORY_DIR" ]] && return 0

    # Collect past session files (excluding the current one), sorted by name (chronological)
    local past_sessions=()
    local f
    for f in "${SHELLIA_HISTORY_DIR}"/session_*.jsonl; do
        [[ -f "$f" ]] || continue
        [[ -s "$f" ]] || continue
        # Skip the current session
        [[ "$f" == "$SHELLIA_HISTORY_SESSION_FILE" ]] && continue
        past_sessions+=("$f")
    done

    local total=${#past_sessions[@]}
    [[ $total -eq 0 ]] && return 0

    # Take the last 2 sessions (most recent)
    local start=0
    if [[ $total -gt 2 ]]; then
        start=$((total - 2))
    fi

    local recap=""
    local i
    for ((i = start; i < total; i++)); do
        local session_file="${past_sessions[$i]}"
        local session_name
        session_name=$(basename "$session_file" .jsonl | sed 's/session_//')

        # Format date from filename: 20260323_141500 -> 2026-03-23 14:15
        local formatted_date
        formatted_date=$(echo "$session_name" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\).*/\1-\2-\3 \4:\5/')

        local msg_count
        msg_count=$(wc -l < "$session_file" | tr -d ' ')

        # Extract first 3 user messages, truncate each to 120 chars
        local topics
        topics=$(jq -r 'select(.role == "user") | .content' "$session_file" 2>/dev/null \
            | head -3 \
            | while IFS= read -r line; do
                if [[ ${#line} -gt 120 ]]; then
                    printf '  - %s...\n' "${line:0:120}"
                else
                    printf '  - %s\n' "$line"
                fi
            done)

        recap="${recap}Session ${formatted_date} (${msg_count} messages):\n${topics}\n"
    done

    [[ -z "$recap" ]] && return 0

    printf '\nRECENT CONVERSATION HISTORY (for context only — do not repeat or reference explicitly):\n'
    printf '%b' "$recap"
}

plugin_history_on_user_message() {
    local message="$1"
    [[ -z "$SHELLIA_HISTORY_SESSION_FILE" ]] && return 0
    local entry
    entry=$(jq -nc --arg role "user" --arg content "$message" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{timestamp: $ts, role: $role, content: $content}')
    echo "$entry" >> "$SHELLIA_HISTORY_SESSION_FILE"
}

plugin_history_on_assistant_message() {
    local message="$1"
    [[ -z "$SHELLIA_HISTORY_SESSION_FILE" ]] && return 0
    [[ -z "$message" ]] && return 0
    local entry
    entry=$(jq -nc --arg role "assistant" --arg content "$message" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{timestamp: $ts, role: $role, content: $content}')
    echo "$entry" >> "$SHELLIA_HISTORY_SESSION_FILE"
}

plugin_history_on_shutdown() {
    # Remove empty session files
    if [[ -n "$SHELLIA_HISTORY_SESSION_FILE" && -f "$SHELLIA_HISTORY_SESSION_FILE" ]]; then
        if [[ ! -s "$SHELLIA_HISTORY_SESSION_FILE" ]]; then
            rm -f "$SHELLIA_HISTORY_SESSION_FILE"
            debug_log "plugin:history" "removed empty session file"
        else
            debug_log "plugin:history" "session saved: ${SHELLIA_HISTORY_SESSION_FILE}"
        fi
    fi
}

plugin_history_on_conversation_reset() {
    # Start a new session file on reset
    if [[ -n "$SHELLIA_HISTORY_DIR" ]]; then
        local timestamp
        timestamp=$(date +%Y%m%d_%H%M%S)
        SHELLIA_HISTORY_SESSION_FILE="${SHELLIA_HISTORY_DIR}/session_${timestamp}.jsonl"
        debug_log "plugin:history" "new session after reset: ${SHELLIA_HISTORY_SESSION_FILE}"
    fi
}

# REPL command: history
repl_cmd_history_handler() {
    local args="$*"
    local subcmd="${args%% *}"
    local remainder=""
    if [[ "$args" != "$subcmd" ]]; then
        remainder="${args#* }"
    fi

    case "$subcmd" in
        list|"")
            _history_list_sessions
            ;;
        resume)
            _history_resume_session "$remainder"
            ;;
        clear)
            _history_clear
            ;;
        *)
            log_warn "Usage: history [list|resume [session]|clear]"
            ;;
    esac
}

repl_cmd_history_help() {
    echo -e "  ${THEME_ACCENT}history${NC}           List/manage conversation history"
}

_history_resume_session() {
    local selector="$1"

    if [[ -z "${SHELLIA_CONV_FILE:-}" || ! -f "$SHELLIA_CONV_FILE" ]]; then
        log_warn "Conversation file not found; cannot resume history."
        return 1
    fi

    local session_file
    session_file=$(_history_resolve_session_file "$selector") || return 1

    local restored
    restored=$(jq -s '[.[] | {role, content}]' "$session_file" 2>/dev/null)
    if [[ -z "$restored" ]]; then
        log_warn "Failed to parse history session: $(basename "$session_file")"
        return 1
    fi

    printf '%s\n' "$restored" > "$SHELLIA_CONV_FILE"

    local message_count
    message_count=$(jq 'length' "$SHELLIA_CONV_FILE" 2>/dev/null || echo 0)

    fire_hook "conversation_reset"
    log_info "Resumed $(basename "$session_file") (${message_count} messages loaded)."
}

_history_resolve_session_file() {
    local selector="$1"

    if [[ ! -d "$SHELLIA_HISTORY_DIR" ]]; then
        log_warn "No history directory found."
        return 1
    fi

    local files=("${SHELLIA_HISTORY_DIR}"/session_*.jsonl)
    if [[ ! -f "${files[0]}" ]]; then
        log_warn "No history sessions found."
        return 1
    fi

    if [[ -z "$selector" || "$selector" == "latest" ]]; then
        local latest_file=""
        local f
        for f in "${files[@]}"; do
            [[ -f "$f" ]] || continue
            latest_file="$f"
        done
        if [[ -n "$latest_file" ]]; then
            printf '%s\n' "$latest_file"
            return 0
        fi
        log_warn "No history sessions found."
        return 1
    fi

    local candidate="$selector"
    if [[ "$candidate" != session_* ]]; then
        candidate="session_${candidate}"
    fi
    candidate="${candidate%.jsonl}.jsonl"

    local exact_path="${SHELLIA_HISTORY_DIR}/${candidate}"
    if [[ -f "$exact_path" ]]; then
        printf '%s\n' "$exact_path"
        return 0
    fi

    log_warn "History session not found: ${selector}"
    log_info "Use 'history list' to find valid session names."
    return 1
}

_history_list_sessions() {
    if [[ ! -d "$SHELLIA_HISTORY_DIR" ]]; then
        echo "No history directory found."
        return 0
    fi

    local count=0
    for f in "${SHELLIA_HISTORY_DIR}"/session_*.jsonl; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f" .jsonl)
        local lines
        lines=$(wc -l < "$f" | tr -d ' ')
        local size
        size=$(wc -c < "$f" | tr -d ' ')
        echo -e "  ${THEME_ACCENT}${name}${NC}  (${lines} messages, ${size} bytes)"
        ((count++))
    done

    if [[ $count -eq 0 ]]; then
        echo "No history sessions found."
    else
        echo ""
        echo "${count} session(s) total."
        echo "Use 'history resume <session>' or 'history resume' for latest."
    fi
}

_history_clear() {
    if [[ -d "$SHELLIA_HISTORY_DIR" ]]; then
        local count
        count=$(find "$SHELLIA_HISTORY_DIR" -name "session_*.jsonl" | wc -l | tr -d ' ')
        rm -f "${SHELLIA_HISTORY_DIR}"/session_*.jsonl
        log_info "Cleared ${count} session(s)."
    fi
}
