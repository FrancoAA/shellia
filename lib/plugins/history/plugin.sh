#!/usr/bin/env bash
# Plugin: history — persistent conversation history

SHELLIA_HISTORY_DIR=""
SHELLIA_HISTORY_SESSION_FILE=""

plugin_history_info() {
    echo "Persistent conversation history with session management"
}

plugin_history_hooks() {
    echo "init user_message assistant_message shutdown conversation_reset"
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
    local subcmd="$1"
    case "$subcmd" in
        list|"")
            _history_list_sessions
            ;;
        clear)
            _history_clear
            ;;
        *)
            log_warn "Usage: history [list|clear]"
            ;;
    esac
}

repl_cmd_history_help() {
    echo -e "  ${THEME_ACCENT}history${NC}           List/manage conversation history"
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
