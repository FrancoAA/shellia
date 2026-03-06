#!/usr/bin/env bash
# Multi-profile management for shellia
# Profiles file: ~/.shellia/profiles (JSON)
# Format: {"profile_name": {"api_url": "...", "api_key": "...", "model": "..."}, ...}

SHELLIA_PROFILES_FILE="${SHELLIA_PROFILES_FILE:-${SHELLIA_CONFIG_DIR:-${HOME}/.shellia}/profiles}"

# Check if a profile exists
# Args: $1 = profile name
# Returns 0 if exists, 1 if not
profile_exists() {
    local name="$1"
    [[ -f "$SHELLIA_PROFILES_FILE" ]] || return 1
    jq -e --arg name "$name" 'has($name)' "$SHELLIA_PROFILES_FILE" >/dev/null 2>&1
}

# Load a profile's settings into SHELLIA_API_URL, SHELLIA_API_KEY, SHELLIA_MODEL
# Args: $1 = profile name
# Returns 1 on failure
load_profile() {
    local name="$1"

    if [[ ! -f "$SHELLIA_PROFILES_FILE" ]]; then
        log_error "No profiles file found. Run 'shellia init' to set up."
        return 1
    fi

    if ! profile_exists "$name"; then
        log_error "Profile '${name}' not found."
        log_info "Available profiles: $(list_profile_names)"
        return 1
    fi

    SHELLIA_API_URL=$(jq -r --arg name "$name" '.[$name].api_url' "$SHELLIA_PROFILES_FILE")
    SHELLIA_API_KEY=$(jq -r --arg name "$name" '.[$name].api_key' "$SHELLIA_PROFILES_FILE")
    SHELLIA_MODEL=$(jq -r --arg name "$name" '.[$name].model' "$SHELLIA_PROFILES_FILE")
    SHELLIA_PROFILE="$name"

    debug_log "profile" "loaded '${name}' (model=${SHELLIA_MODEL})"
}

# List all profile names (space-separated, for error messages)
list_profile_names() {
    if [[ ! -f "$SHELLIA_PROFILES_FILE" ]]; then
        echo "(none)"
        return
    fi
    jq -r 'keys | join(", ")' "$SHELLIA_PROFILES_FILE"
}

# List profiles with details (formatted for display)
list_profiles() {
    if [[ ! -f "$SHELLIA_PROFILES_FILE" ]]; then
        echo "No profiles configured. Run 'shellia init' to set up."
        return
    fi

    local profiles
    profiles=$(jq -r 'keys[]' "$SHELLIA_PROFILES_FILE")

    if [[ -z "$profiles" ]]; then
        echo "No profiles configured. Run 'shellia profile add <name>' to create one."
        return
    fi

    local current="${SHELLIA_PROFILE:-default}"

    echo -e "${THEME_HEADER}Profiles:${NC}"
    while IFS= read -r name; do
        local model
        model=$(jq -r --arg name "$name" '.[$name].model' "$SHELLIA_PROFILES_FILE")
        local api_url
        api_url=$(jq -r --arg name "$name" '.[$name].api_url' "$SHELLIA_PROFILES_FILE")

        if [[ "$name" == "$current" ]]; then
            echo -e "  ${THEME_ACCENT}* ${name}${NC}  model: ${model}  url: ${api_url}"
        else
            echo -e "    ${name}  model: ${model}  url: ${api_url}"
        fi
    done <<< "$profiles"
}

# Interactive wizard to add a new profile
# Args: $1 = profile name
add_profile() {
    local name="$1"

    if profile_exists "$name"; then
        log_warn "Profile '${name}' already exists."
        read -rp "Overwrite? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Cancelled."
            return 0
        fi
    fi

    # API URL
    read -rp "API provider URL [https://openrouter.ai/api/v1]: " api_url
    api_url="${api_url:-https://openrouter.ai/api/v1}"

    # API Key
    read -rsp "API key: " api_key
    echo ""
    if [[ -z "$api_key" ]]; then
        log_error "API key cannot be empty."
        return 1
    fi

    # Model
    read -rp "Model ID (e.g. anthropic/claude-sonnet-4, openai/gpt-4o): " model
    if [[ -z "$model" ]]; then
        log_error "Model ID cannot be empty."
        return 1
    fi

    # Ensure profiles file exists
    if [[ ! -f "$SHELLIA_PROFILES_FILE" ]]; then
        echo '{}' > "$SHELLIA_PROFILES_FILE"
        chmod 600 "$SHELLIA_PROFILES_FILE"
    fi

    # Write profile to file
    local updated
    updated=$(jq \
        --arg name "$name" \
        --arg url "$api_url" \
        --arg key "$api_key" \
        --arg model "$model" \
        '.[$name] = {"api_url": $url, "api_key": $key, "model": $model}' \
        "$SHELLIA_PROFILES_FILE")
    echo "$updated" > "$SHELLIA_PROFILES_FILE"

    log_success "Profile '${name}' saved."
}

# Remove a profile
# Args: $1 = profile name
remove_profile() {
    local name="$1"

    if ! profile_exists "$name"; then
        log_error "Profile '${name}' not found."
        return 1
    fi

    # Count remaining profiles
    local count
    count=$(jq 'keys | length' "$SHELLIA_PROFILES_FILE")
    if [[ "$count" -le 1 ]]; then
        log_error "Cannot remove the last profile. Add another profile first."
        return 1
    fi

    read -rp "Remove profile '${name}'? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        return 0
    fi

    local updated
    updated=$(jq --arg name "$name" 'del(.[$name])' "$SHELLIA_PROFILES_FILE")
    echo "$updated" > "$SHELLIA_PROFILES_FILE"

    log_success "Profile '${name}' removed."

    # If the removed profile was active, switch to the first available
    if [[ "${SHELLIA_PROFILE:-}" == "$name" ]]; then
        local first
        first=$(jq -r 'keys[0]' "$SHELLIA_PROFILES_FILE")
        log_info "Switched to profile: ${first}"
        SHELLIA_PROFILE="$first"
    fi
}
