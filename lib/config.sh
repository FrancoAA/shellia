#!/usr/bin/env bash
# Configuration loading for shellia

SHELLIA_CONFIG_DIR="${SHELLIA_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/shellia}"
SHELLIA_CONFIG_FILE="${SHELLIA_CONFIG_FILE:-${SHELLIA_CONFIG_DIR}/config}"
SHELLIA_DANGEROUS_FILE="${SHELLIA_DANGEROUS_FILE:-${SHELLIA_CONFIG_DIR}/dangerous_commands}"
SHELLIA_USER_PROMPT_FILE="${SHELLIA_USER_PROMPT_FILE:-${SHELLIA_CONFIG_DIR}/system_prompt}"

ensure_default_plugin_configs() {
    local defaults_root="${SHELLIA_DIR}/defaults/plugins"
    [[ -d "$defaults_root" ]] || return 0

    local plugin_dir
    for plugin_dir in "$defaults_root"/*; do
        [[ -d "$plugin_dir" ]] || continue

        local plugin_name
        plugin_name=$(basename "$plugin_dir")
        local example_file="${plugin_dir}/config.example"
        [[ -f "$example_file" ]] || continue

        local target_dir="${SHELLIA_CONFIG_DIR}/plugins/${plugin_name}"
        local target_file="${target_dir}/config"

        if [[ ! -f "$target_file" ]]; then
            mkdir -p "$target_dir"
            cp "$example_file" "$target_file"
        fi
    done
}

# Load config from file, env vars, and profiles
load_config() {
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

    # Apply defaults for settings not set by env vars or config file
    SHELLIA_THEME="${SHELLIA_THEME:-default}"
    SHELLIA_PROFILE="${SHELLIA_PROFILE:-default}"

    # Initialize API vars (prevents unbound variable errors with set -u)
    SHELLIA_API_URL="${SHELLIA_API_URL:-}"
    SHELLIA_API_KEY="${SHELLIA_API_KEY:-}"
    SHELLIA_MODEL="${SHELLIA_MODEL:-}"

    # Load API settings from profile if profiles file exists
    if [[ -f "$SHELLIA_PROFILES_FILE" ]]; then
        # Only load profile if API vars aren't already set via env
        if [[ -z "$SHELLIA_API_URL" && -z "$SHELLIA_API_KEY" ]]; then
            if profile_exists "$SHELLIA_PROFILE"; then
                load_profile "$SHELLIA_PROFILE"
            else
                log_error "Profile '${SHELLIA_PROFILE}' not found."
                log_info "Available profiles: $(list_profile_names)"
            fi
        fi
    fi
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

    # Write config file (only non-API settings now)
    cat > "$SHELLIA_CONFIG_FILE" <<EOF
# shellia configuration
SHELLIA_PROFILE=default
SHELLIA_THEME=default
EOF
    chmod 600 "$SHELLIA_CONFIG_FILE"

    # Create profiles file with "default" profile
    local profiles_json
    profiles_json=$(jq -n \
        --arg url "$api_url" \
        --arg key "$api_key" \
        --arg model "$model" \
        '{"default": {"api_url": $url, "api_key": $key, "model": $model}}')
    echo "$profiles_json" > "$SHELLIA_PROFILES_FILE"
    chmod 600 "$SHELLIA_PROFILES_FILE"

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

    ensure_default_plugin_configs

    log_success "Configuration saved."
    echo ""
    echo "Profile 'default' created with model: ${model}"
    echo ""
    echo "You can now use shellia:"
    echo "  shellia \"list all running docker containers\""
    echo "  shellia   (enter REPL mode)"
    echo ""
    echo "Add more profiles with: shellia profile add <name>"
}
