#!/usr/bin/env bash
# Tests for lib/config.sh

test_load_config_reads_config_file() {
    # Create a config file with known values
    cat > "$SHELLIA_CONFIG_FILE" <<'EOF'
SHELLIA_THEME=ocean
SHELLIA_PROFILE=myprofile
EOF

    # Fully unset so config file values win
    # load_config uses ${VAR:-default} which treats empty as unset,
    # so we must truly unset (not just set to empty)
    unset SHELLIA_THEME SHELLIA_PROFILE 2>/dev/null || true

    load_config
    assert_eq "$SHELLIA_THEME" "ocean" "load_config reads SHELLIA_THEME from file"
    assert_eq "$SHELLIA_PROFILE" "myprofile" "load_config reads SHELLIA_PROFILE from file"
}

test_load_config_env_vars_override_file() {
    cat > "$SHELLIA_CONFIG_FILE" <<'EOF'
SHELLIA_THEME=ocean
EOF

    # Set env var — should override config file
    export SHELLIA_THEME="forest"
    load_config
    assert_eq "$SHELLIA_THEME" "forest" "env var overrides config file value"
    unset SHELLIA_THEME
}

test_load_config_skips_comments_and_blanks() {
    cat > "$SHELLIA_CONFIG_FILE" <<'EOF'
# This is a comment
SHELLIA_THEME=sunset

  # Another comment

EOF

    unset SHELLIA_THEME 2>/dev/null || true
    load_config
    assert_eq "$SHELLIA_THEME" "sunset" "load_config skips comments and blank lines"
}

test_load_config_defaults_when_no_file() {
    # No config file exists (reset clears it)
    unset SHELLIA_THEME SHELLIA_PROFILE 2>/dev/null || true
    load_config
    assert_eq "$SHELLIA_THEME" "default" "SHELLIA_THEME defaults to 'default'"
    assert_eq "$SHELLIA_PROFILE" "default" "SHELLIA_PROFILE defaults to 'default'"
}

test_load_config_loads_profile_when_profiles_file_exists() {
    # Create a profiles file
    cat > "$SHELLIA_PROFILES_FILE" <<'EOF'
{"default": {"api_url": "https://test.api/v1", "api_key": "test-key-123", "model": "test/model"}}
EOF
    cat > "$SHELLIA_CONFIG_FILE" <<'EOF'
SHELLIA_PROFILE=default
EOF

    unset SHELLIA_API_URL SHELLIA_API_KEY SHELLIA_MODEL SHELLIA_PROFILE SHELLIA_THEME 2>/dev/null || true
    load_config
    assert_eq "$SHELLIA_API_URL" "https://test.api/v1" "load_config loads api_url from profile"
    assert_eq "$SHELLIA_API_KEY" "test-key-123" "load_config loads api_key from profile"
    assert_eq "$SHELLIA_MODEL" "test/model" "load_config loads model from profile"
}

test_load_config_env_api_vars_override_profile() {
    cat > "$SHELLIA_PROFILES_FILE" <<'EOF'
{"default": {"api_url": "https://profile.api/v1", "api_key": "profile-key", "model": "profile/model"}}
EOF

    export SHELLIA_API_URL="https://env.api/v1"
    export SHELLIA_API_KEY="env-key"
    unset SHELLIA_MODEL SHELLIA_PROFILE SHELLIA_THEME 2>/dev/null || true
    load_config
    assert_eq "$SHELLIA_API_URL" "https://env.api/v1" "env SHELLIA_API_URL overrides profile"
    assert_eq "$SHELLIA_API_KEY" "env-key" "env SHELLIA_API_KEY overrides profile"
    unset SHELLIA_API_URL SHELLIA_API_KEY
}

test_load_config_backwards_compat_no_profiles_file() {
    # Config file has API vars directly (old format)
    cat > "$SHELLIA_CONFIG_FILE" <<'EOF'
SHELLIA_API_URL=https://old.api/v1
SHELLIA_API_KEY=old-key
SHELLIA_MODEL=old/model
EOF
    # No profiles file
    rm -f "$SHELLIA_PROFILES_FILE"

    unset SHELLIA_API_URL SHELLIA_API_KEY SHELLIA_MODEL SHELLIA_THEME SHELLIA_PROFILE 2>/dev/null || true
    load_config
    assert_eq "$SHELLIA_API_URL" "https://old.api/v1" "backwards compat: reads API URL from config"
    assert_eq "$SHELLIA_API_KEY" "old-key" "backwards compat: reads API key from config"
    assert_eq "$SHELLIA_MODEL" "old/model" "backwards compat: reads model from config"
}

test_validate_config_passes_with_all_vars() {
    SHELLIA_API_URL="https://test.api/v1"
    SHELLIA_API_KEY="test-key"
    SHELLIA_MODEL="test/model"

    local exit_code=0
    (validate_config) 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "0" "validate_config passes when all vars set"
}

test_validate_config_dies_on_missing_api_url() {
    SHELLIA_API_URL=""
    SHELLIA_API_KEY="test-key"
    SHELLIA_MODEL="test/model"

    local exit_code=0
    (validate_config) 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_config dies when SHELLIA_API_URL is empty"
}

test_validate_config_dies_on_missing_api_key() {
    SHELLIA_API_URL="https://test.api/v1"
    SHELLIA_API_KEY=""
    SHELLIA_MODEL="test/model"

    local exit_code=0
    (validate_config) 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_config dies when SHELLIA_API_KEY is empty"
}

test_validate_config_dies_on_missing_model() {
    SHELLIA_API_URL="https://test.api/v1"
    SHELLIA_API_KEY="test-key"
    SHELLIA_MODEL=""

    local exit_code=0
    (validate_config) 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_config dies when SHELLIA_MODEL is empty"
}
