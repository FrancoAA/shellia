#!/usr/bin/env bash
# Configuration loading for bashia

BASHIA_CONFIG_DIR="${HOME}/.bashia"
BASHIA_CONFIG_FILE="${BASHIA_CONFIG_DIR}/config"
BASHIA_DANGEROUS_FILE="${BASHIA_CONFIG_DIR}/dangerous_commands"
BASHIA_USER_PROMPT_FILE="${BASHIA_CONFIG_DIR}/system_prompt"

# Load config from file, then override with env vars
load_config() {
    # Defaults
    BASHIA_API_URL="${BASHIA_API_URL:-}"
    BASHIA_API_KEY="${BASHIA_API_KEY:-}"
    BASHIA_MODEL="${BASHIA_MODEL:-}"

    # Load config file if it exists (env vars already set take precedence)
    if [[ -f "$BASHIA_CONFIG_FILE" ]]; then
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
        done < "$BASHIA_CONFIG_FILE"
    fi

    # Re-read (env vars win over config file)
    BASHIA_API_URL="${BASHIA_API_URL:-}"
    BASHIA_API_KEY="${BASHIA_API_KEY:-}"
    BASHIA_MODEL="${BASHIA_MODEL:-}"
}

# Validate that required config is present
validate_config() {
    if [[ -z "$BASHIA_API_URL" ]]; then
        die "BASHIA_API_URL is not set. Run 'bashia init' or set the environment variable."
    fi
    if [[ -z "$BASHIA_API_KEY" ]]; then
        die "BASHIA_API_KEY is not set. Run 'bashia init' or set the environment variable."
    fi
    if [[ -z "$BASHIA_MODEL" ]]; then
        die "BASHIA_MODEL is not set. Run 'bashia init' or set the environment variable."
    fi
}

# Interactive setup wizard
bashia_init() {
    echo -e "${BOLD}bashia init${NC}"
    echo ""

    if [[ -d "$BASHIA_CONFIG_DIR" ]]; then
        echo "Existing configuration found at ${BASHIA_CONFIG_DIR}"
        read -rp "Reconfigure? [y/N]: " reconfigure
        if [[ ! "$reconfigure" =~ ^[Yy]$ ]]; then
            echo "Keeping existing configuration."
            return 0
        fi
    fi

    mkdir -p "$BASHIA_CONFIG_DIR"

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
    cat > "$BASHIA_CONFIG_FILE" <<EOF
# bashia configuration
BASHIA_API_URL=${api_url}
BASHIA_API_KEY=${api_key}
BASHIA_MODEL=${model}
EOF
    chmod 600 "$BASHIA_CONFIG_FILE"

    # Copy dangerous commands if not present
    if [[ ! -f "$BASHIA_DANGEROUS_FILE" ]]; then
        cp "${BASHIA_DIR}/defaults/dangerous_commands" "$BASHIA_DANGEROUS_FILE"
    fi

    # Create empty user system prompt if not present
    if [[ ! -f "$BASHIA_USER_PROMPT_FILE" ]]; then
        cat > "$BASHIA_USER_PROMPT_FILE" <<'EOF'
# Custom instructions for bashia (appended to base prompt)
# Uncomment and edit lines below, or add your own.
# Examples:
#   Prefer eza over ls
#   Use doas instead of sudo
#   Always use long flags for readability
EOF
    fi

    log_success "Configuration saved to ${BASHIA_CONFIG_FILE}"
    echo ""
    echo "You can now use bashia:"
    echo "  bashia \"list all running docker containers\""
    echo "  bashia   (enter REPL mode)"
}
