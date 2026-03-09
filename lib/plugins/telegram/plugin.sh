#!/usr/bin/env bash
# Plugin: telegram — Telegram bot interface for shellia

plugin_telegram_info() {
    echo "Telegram bot interface for chatting with shellia"
}

plugin_telegram_hooks() {
    echo ""
}

# === CLI subcommand ===

cli_cmd_telegram_handler() {
    shellia_telegram "$@"
    fire_hook "shutdown"
}

cli_cmd_telegram_help() {
    echo "  telegram             Start Telegram bot"
}

cli_cmd_telegram_setup() {
    echo "config validate theme tools plugins hooks_init"
}

# === REPL command ===

repl_cmd_telegram_handler() {
    shellia_telegram "$@"
}

repl_cmd_telegram_help() {
    echo -e "  ${THEME_ACCENT}telegram${NC}          Start Telegram bot"
}

# Main telegram function
shellia_telegram() {
    local bot_token allowed_users

    bot_token=$(plugin_config_get "telegram" "bot_token" "")
    allowed_users=$(plugin_config_get "telegram" "allowed_users" "")

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token)
                bot_token="${2:-}"
                [[ -z "$bot_token" ]] && die "Usage: telegram --token <bot_token>"
                shift 2
                ;;
            --allowed-users)
                allowed_users="${2:-}"
                [[ -z "$allowed_users" ]] && die "Usage: telegram --allowed-users <id1,id2,...>"
                shift 2
                ;;
            *)
                log_warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    if [[ -z "$bot_token" ]]; then
        die "Telegram bot token is required. Set it in ~/.config/shellia/plugins/telegram/config (bot_token=...) or pass --token <token>"
    fi

    # Check python3 is available
    if ! command -v python3 &>/dev/null; then
        die "python3 is required for 'shellia telegram'. Install Python 3 and try again."
    fi

    local plugin_dir="${SHELLIA_DIR}/lib/plugins/telegram"
    local bot_script="${plugin_dir}/bot.py"

    if [[ ! -f "$bot_script" ]]; then
        die "Bot script not found: ${bot_script}"
    fi

    log_info "Starting shellia Telegram bot..."
    echo -e "  ${THEME_MUTED}Press Ctrl+C to stop${NC}"
    echo ""

    # Export config so the Python bot can access it
    export SHELLIA_TELEGRAM_BOT_TOKEN="$bot_token"
    export SHELLIA_TELEGRAM_ALLOWED_USERS="$allowed_users"
    export SHELLIA_TELEGRAM_PLUGIN_DIR="$plugin_dir"
    export SHELLIA_TELEGRAM_SHELLIA_CMD="${SHELLIA_DIR}/shellia"

    # Forward shellia config for subprocesses
    export SHELLIA_API_URL
    export SHELLIA_API_KEY
    export SHELLIA_MODEL
    export SHELLIA_DIR
    export SHELLIA_CONFIG_DIR

    # Start the Python bot (blocking)
    python3 "$bot_script"
}
