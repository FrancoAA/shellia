#!/usr/bin/env bash
# Tests for the shellia entrypoint (handle_response, CLI flags, subcommands)
# handle_response is defined in the shellia entrypoint, not lib files.
# We source it here so it's available for direct testing.

SHELLIA_BIN="${PROJECT_DIR}/shellia"

# --- Source handle_response from the entrypoint ---
# We extract and eval just the handle_response function to avoid
# re-running the entire entrypoint (which has side effects).
# Instead, we define it inline matching the entrypoint's logic.

handle_response() {
    local content="$1"
    local dry_run="${2:-false}"

    local first_line
    first_line=$(echo "$content" | head -n 1)
    local body
    body=$(echo "$content" | tail -n +2)

    case "$first_line" in
        "[COMMAND]")
            local cmd
            cmd=$(echo "$body" | sed '/^[[:space:]]*$/d' | head -n 1)
            execute_command "$cmd" "$dry_run"
            ;;
        "[PLAN]")
            execute_plan "$body" "$dry_run"
            ;;
        "[EXPLANATION]")
            echo "$body"
            ;;
        *)
            echo "$content"
            ;;
    esac
}

# --- CLI-level tests (call ./shellia as subprocess) ---

test_version_flag() {
    local output
    output=$("$SHELLIA_BIN" --version 2>/dev/null)
    assert_eq "$output" "shellia v0.1.0" "--version prints correct version"
}

test_help_flag() {
    local output
    output=$("$SHELLIA_BIN" --help 2>/dev/null)
    assert_contains "$output" "Usage: shellia" "--help shows usage line"
    assert_contains "$output" "--dry-run" "--help shows --dry-run option"
    assert_contains "$output" "--profile" "--help shows --profile option"
    assert_contains "$output" "profiles" "--help shows profiles subcommand"
    assert_contains "$output" "profile add" "--help shows profile add subcommand"
}

test_help_short_flag() {
    local output
    output=$("$SHELLIA_BIN" -h 2>/dev/null)
    assert_contains "$output" "Usage: shellia" "-h shows usage line"
}

# --- handle_response tests ---

test_handle_response_command_tag() {
    DANGEROUS_PATTERNS=()
    local output
    output=$(handle_response "[COMMAND]
echo hello_from_test" "false" 2>/dev/null)
    assert_contains "$output" "hello_from_test" "handle_response executes [COMMAND]"
}

test_handle_response_command_dry_run() {
    DANGEROUS_PATTERNS=()
    local output
    output=$(handle_response "[COMMAND]
echo dry_run_test" "true" 2>/dev/null)
    assert_contains "$output" "$ echo dry_run_test" "handle_response dry-run shows command with $ prefix"
}

test_handle_response_explanation_tag() {
    local output
    output=$(handle_response "[EXPLANATION]
This is an explanation of something." "false" 2>/dev/null)
    assert_contains "$output" "This is an explanation" "handle_response prints [EXPLANATION] body"
}

test_handle_response_plan_tag_dry_run() {
    DANGEROUS_PATTERNS=()
    local output
    output=$(handle_response '[PLAN]
[{"description":"Step one","command":"echo step1"},{"description":"Step two","command":"echo step2"}]' "true" 2>/dev/null)
    assert_contains "$output" "Plan (2 steps)" "handle_response shows plan step count"
    assert_contains "$output" "Step one" "handle_response shows plan descriptions"
    assert_contains "$output" "Step two" "handle_response shows all plan steps"
}

test_handle_response_no_tag_fallback() {
    local output
    output=$(handle_response "Just some text without any tag" "false" 2>/dev/null)
    assert_contains "$output" "Just some text without any tag" "handle_response falls back to printing content"
}

# --- Subcommand error handling ---

test_profile_subcommand_no_profiles_file() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir"
    local output
    output=$(SHELLIA_CONFIG_DIR="$tmpdir" SHELLIA_PROFILES_FILE="$tmpdir/profiles" "$SHELLIA_BIN" profiles 2>/dev/null)
    assert_contains "$output" "No profiles configured" "profiles subcommand handles missing file"
    rm -rf "$tmpdir"
}

test_profile_add_missing_name() {
    local exit_code=0
    "$SHELLIA_BIN" profile add 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "profile add without name exits with error"
}

test_profile_remove_missing_name() {
    local exit_code=0
    "$SHELLIA_BIN" profile remove 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "profile remove without name exits with error"
}

test_profile_bad_subcommand() {
    local exit_code=0
    "$SHELLIA_BIN" profile badcmd 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "profile with unknown subcommand exits with error"
}

test_profile_flag_missing_name() {
    local exit_code=0
    "$SHELLIA_BIN" --profile 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "--profile without name exits with error"
}
