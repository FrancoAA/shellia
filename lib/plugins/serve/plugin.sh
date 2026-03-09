#!/usr/bin/env bash
# Plugin: serve — web-based chat UI for shellia

plugin_serve_info() {
    echo "Web-based chat UI accessible via browser"
}

plugin_serve_hooks() {
    echo ""
}

# === CLI subcommand ===

cli_cmd_serve_handler() {
    shellia_serve "$@"
    fire_hook "shutdown"
}

cli_cmd_serve_help() {
    echo "  serve [--port N] [--host H] Start web-based chat UI"
}

cli_cmd_serve_setup() {
    echo "config validate theme tools plugins hooks_init"
}

# === CLI flag ===

cli_flag_web_mode_handler() {
    SHELLIA_WEB_MODE=true
    echo 0
}

# === REPL command ===

repl_cmd_serve_handler() {
    shellia_serve "$@"
}

repl_cmd_serve_help() {
    echo -e "  ${THEME_ACCENT}serve${NC}             Start web UI (serve [--port 8080] [--host 0.0.0.0])"
}

# Main serve function
shellia_serve() {
    local port host
    port=$(plugin_config_get "serve" "port" "8080")
    host=$(plugin_config_get "serve" "host" "0.0.0.0")

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)
                port="${2:-}"
                [[ -z "$port" ]] && die "Usage: serve --port <number>"
                shift 2
                ;;
            --host)
                host="${2:-}"
                [[ -z "$host" ]] && die "Usage: serve --host <address>"
                shift 2
                ;;
            *)
                log_warn "Unknown option: $1"
                shift
                ;;
        esac
    done

    # Check python3 is available
    if ! command -v python3 &>/dev/null; then
        die "python3 is required for 'shellia serve'. Install Python 3 and try again."
    fi

    local plugin_dir="${SHELLIA_DIR}/lib/plugins/serve"
    local server_script="${plugin_dir}/server.py"

    if [[ ! -f "$server_script" ]]; then
        die "Server script not found: ${server_script}"
    fi

    # Detect local network IP for cross-device access
    local network_ip=""
    case "$(uname -s)" in
        Darwin)
            network_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
            ;;
        Linux)
            network_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
            ;;
    esac

    log_info "Starting shellia web UI..."
    if [[ "$host" == "0.0.0.0" ]]; then
        echo -e "  ${THEME_ACCENT}Local:${NC}    http://localhost:${port}"
        if [[ -n "$network_ip" ]]; then
            echo -e "  ${THEME_ACCENT}Network:${NC}  http://${network_ip}:${port}"
        fi
    else
        echo -e "  ${THEME_ACCENT}URL:${NC}  http://${host}:${port}"
    fi
    echo -e "  ${THEME_MUTED}Press Ctrl+C to stop${NC}"
    echo ""

    # Export config so the Python server can access it
    export SHELLIA_SERVE_PORT="$port"
    export SHELLIA_SERVE_HOST="$host"
    export SHELLIA_SERVE_PLUGIN_DIR="$plugin_dir"
    export SHELLIA_SERVE_SHELLIA_CMD="${SHELLIA_DIR}/shellia"

    # Forward shellia config for subprocesses
    export SHELLIA_API_URL
    export SHELLIA_API_KEY
    export SHELLIA_MODEL
    export SHELLIA_DIR
    export SHELLIA_CONFIG_DIR

    # Start the Python server (blocking)
    python3 "$server_script"
}
