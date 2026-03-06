#!/usr/bin/env bash
# Tests for lib/profiles.sh

_create_test_profiles() {
    cat > "$SHELLIA_PROFILES_FILE" <<'EOF'
{
    "default": {"api_url": "https://openrouter.ai/api/v1", "api_key": "key-default", "model": "anthropic/claude-haiku-4.5"},
    "openai": {"api_url": "https://api.openai.com/v1", "api_key": "key-openai", "model": "gpt-4o"},
    "local": {"api_url": "http://localhost:11434/v1", "api_key": "none", "model": "llama3"}
}
EOF
}

test_profile_exists_returns_true_for_existing() {
    _create_test_profiles
    profile_exists "default"
    local result=$?
    assert_eq "$result" "0" "profile_exists returns 0 for existing profile"
}

test_profile_exists_returns_false_for_missing() {
    _create_test_profiles
    profile_exists "nonexistent"
    local result=$?
    assert_eq "$result" "1" "profile_exists returns 1 for missing profile"
}

test_profile_exists_returns_false_when_no_file() {
    rm -f "$SHELLIA_PROFILES_FILE"
    profile_exists "default"
    local result=$?
    assert_eq "$result" "1" "profile_exists returns 1 when no profiles file"
}

test_load_profile_sets_api_vars() {
    _create_test_profiles
    load_profile "openai" 2>/dev/null
    assert_eq "$SHELLIA_API_URL" "https://api.openai.com/v1" "load_profile sets API URL"
    assert_eq "$SHELLIA_API_KEY" "key-openai" "load_profile sets API key"
    assert_eq "$SHELLIA_MODEL" "gpt-4o" "load_profile sets model"
    assert_eq "$SHELLIA_PROFILE" "openai" "load_profile sets SHELLIA_PROFILE"
}

test_load_profile_fails_for_missing_profile() {
    _create_test_profiles
    local exit_code=0
    load_profile "nonexistent" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "load_profile returns 1 for missing profile"
}

test_load_profile_fails_when_no_file() {
    rm -f "$SHELLIA_PROFILES_FILE"
    local exit_code=0
    load_profile "default" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "load_profile returns 1 when no profiles file"
}

test_list_profile_names_returns_all_names() {
    _create_test_profiles
    local names
    names=$(list_profile_names)
    assert_contains "$names" "default" "list_profile_names includes 'default'"
    assert_contains "$names" "openai" "list_profile_names includes 'openai'"
    assert_contains "$names" "local" "list_profile_names includes 'local'"
}

test_list_profile_names_returns_none_when_no_file() {
    rm -f "$SHELLIA_PROFILES_FILE"
    local names
    names=$(list_profile_names)
    assert_eq "$names" "(none)" "list_profile_names returns '(none)' when no file"
}

test_list_profiles_shows_all_profiles() {
    _create_test_profiles
    SHELLIA_PROFILE="default"
    local output
    output=$(list_profiles 2>/dev/null)
    assert_contains "$output" "default" "list_profiles shows default"
    assert_contains "$output" "openai" "list_profiles shows openai"
    assert_contains "$output" "local" "list_profiles shows local"
}

test_list_profiles_marks_active_profile() {
    _create_test_profiles
    SHELLIA_PROFILE="openai"
    local output
    output=$(list_profiles 2>/dev/null)
    assert_contains "$output" "* openai" "list_profiles marks active profile with *"
}

test_remove_profile_blocks_last_profile() {
    # Create profiles with only one entry
    cat > "$SHELLIA_PROFILES_FILE" <<'EOF'
{"default": {"api_url": "https://test/v1", "api_key": "key", "model": "model"}}
EOF
    local exit_code=0
    remove_profile "default" 2>/dev/null <<< "y" || exit_code=$?
    assert_eq "$exit_code" "1" "remove_profile blocks removing last profile"
}

test_remove_profile_removes_profile() {
    _create_test_profiles
    # Answer "y" to confirmation
    remove_profile "local" 2>/dev/null <<< "y"
    local exists_after=0
    profile_exists "local" || exists_after=$?
    assert_eq "$exists_after" "1" "remove_profile removes the profile"
}

test_remove_profile_switches_active_when_removed() {
    _create_test_profiles
    SHELLIA_PROFILE="local"
    remove_profile "local" 2>/dev/null <<< "y"
    assert_not_eq_local "$SHELLIA_PROFILE" "local" "active profile changes after removal"
}

# Helper (not a test)
assert_not_eq_local() {
    local actual="$1"
    local not_expected="$2"
    local desc="${3:-assert_not_eq}"

    if [[ "$actual" != "$not_expected" ]]; then
        _pass "$desc"
    else
        _fail "$desc" "expected NOT '${not_expected}', but got it"
    fi
}
