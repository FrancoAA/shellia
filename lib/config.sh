#!/usr/bin/env bash
# Configuration loading for shellia

SHELLIA_CONFIG_DIR="${HOME}/.shellia"
SHELLIA_CONFIG_FILE="${SHELLIA_CONFIG_DIR}/config"
SHELLIA_DANGEROUS_FILE="${SHELLIA_CONFIG_DIR}/dangerous_commands"
SHELLIA_USER_PROMPT_FILE="${SHELLIA_CONFIG_DIR}/system_prompt"

# Load config from file, then override with env vars
load_config() {
    # Defaults
    SHELLIA_API_URL="${SHELLIA_API_URL:-}"
    SHELLIA_API_KEY="${SHELLIA_API_KEY:-}"
    SHELLIA_MODEL="${SHELLIA_MODEL:-}"
    SHELLIA_THEME="${SHELLIA_THEME:-default}"

    # Load config file if it exists (env vars already set take precedence)
    if [[ -f "$SHELLIA_CONFIG_FILE" ]]; then
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            # Trim whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # Only set if not already set via env var
            if [[ -z "${!key:-}" ]]; then
                export "$key=$value"
            fi
        done < "$SHELLIA_CONFIG_FILE"
    fi

    # Re-read (env vars win over config file)
    SHELLIA_API_URL="${SHELLIA_API_URL:-}"
    SHELLIA_API_KEY="${SHELLIA_API_KEY:-}"
    SHELLIA_MODEL="${SHELLIA_MODEL:-}"
    SHELLIA_THEME="${SHELLIA_THEME:-default}"
}

# Validate that required config is present
validate_config() {
    if [[ -z "$SHELLIA_API_URL" ]]; then
        die "SHELLIA_API_URL is not set. Run 'shellia init' or set the environment variable."
    fi
    if [[ -z "$SHELLIA_API_KEY" ]]; then
        die "SHELLIA_API_KEY is not set. Run 'shellia init' or set the environment variable."
    fi
    if [[ -z "$SHELLIA_MODEL" ]]; then
        die "SHELLIA_MODEL is not set. Run 'shellia init' or set the environment variable."
    fi
}

# Interactive setup wizard
shellia_init() {
    echo -e "${BOLD}shellia init${NC}"
    echo ""

    if [[ -d "$SHELLIA_CONFIG_DIR" ]]; then
        echo "Existing configuration found at ${SHELLIA_CONFIG_DIR}"
        read -rp "Reconfigure? [y/N]: " reconfigure
        if [[ ! "$reconfigure" =~ ^[Yy]$ ]]; then
            echo "Keeping existing configuration."
            return 0
        fi
    fi

    mkdir -p "$SHELLIA_CONFIG_DIR"

    # API URL
    read -rp "API provider URL [https://openrouter.ai/api/v1]: " api_url
    api_url="${api_url:-https://openrouter.ai/api/v1}"

    # API Key
    read -rsp "API key: " api_key
    echo ""
    if [[ -z "$api_key" ]]; then
        die "API key cannot be empty."
    fi

    # Model
    read -rp "Model ID (e.g. anthropic/claude-sonnet-4, openai/gpt-4o): " model
    if [[ -z "$model" ]]; then
        die "Model ID cannot be empty."
    fi

    # Write config file
    cat > "$SHELLIA_CONFIG_FILE" <<EOF
# shellia configuration
SHELLIA_API_URL=${api_url}
SHELLIA_API_KEY=${api_key}
SHELLIA_MODEL=${model}
SHELLIA_THEME=default
EOF
    chmod 600 "$SHELLIA_CONFIG_FILE"

    # Copy dangerous commands if not present
    if [[ ! -f "$SHELLIA_DANGEROUS_FILE" ]]; then
        cp "${SHELLIA_DIR}/defaults/dangerous_commands" "$SHELLIA_DANGEROUS_FILE"
    fi

    # Create empty user system prompt if not present
    if [[ ! -f "$SHELLIA_USER_PROMPT_FILE" ]]; then
        cat > "$SHELLIA_USER_PROMPT_FILE" <<'EOF'
# Custom instructions for shellia (appended to base prompt)
# Uncomment and edit lines below, or add your own.
# Examples:
#   Prefer eza over ls
#   Use doas instead of sudo
#   Always use long flags for readability
EOF
    fi

    log_success "Configuration saved to ${SHELLIA_CONFIG_FILE}"
    echo ""
    echo "You can now use shellia:"
    echo "  shellia \"list all running docker containers\""
    echo "  shellia   (enter REPL mode)"
}
