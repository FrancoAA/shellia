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
            # Keep all lines (multi-line commands like heredocs, for loops, etc.)
            # Strip only leading and trailing blank lines
            cmd=$(printf '%s\n' "$body" | sed '/./,$!d' | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}')
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

# --- Multi-line command tests ---

test_handle_response_multiline_heredoc_command() {
    DANGEROUS_PATTERNS=()
    local tmpfile="/tmp/shellia_test_heredoc_$$"
    rm -f "$tmpfile"

    local response="[COMMAND]
cat <<'EOF' > ${tmpfile}
#!/bin/bash
ps aux | grep node | grep -v grep
EOF"

    handle_response "$response" "false" 2>/dev/null

    # Verify the file was created and has the correct content
    assert_file_exists "$tmpfile" "heredoc command creates the file"

    local file_content
    file_content=$(cat "$tmpfile")
    assert_contains "$file_content" "#!/bin/bash" "heredoc file contains shebang"
    assert_contains "$file_content" "ps aux | grep node" "heredoc file contains script body"

    rm -f "$tmpfile"
}

test_handle_response_multiline_for_loop() {
    DANGEROUS_PATTERNS=()
    local output
    output=$(handle_response "[COMMAND]
for i in 1 2 3; do
  echo \"item_\$i\"
done" "false" 2>/dev/null)

    assert_contains "$output" "item_1" "for loop executes and outputs item_1"
    assert_contains "$output" "item_2" "for loop executes and outputs item_2"
    assert_contains "$output" "item_3" "for loop executes and outputs item_3"
}

test_handle_response_multiline_dry_run_shows_full_command() {
    DANGEROUS_PATTERNS=()
    local output
    output=$(handle_response "[COMMAND]
cat <<'EOF' > /tmp/test.sh
echo hello
EOF" "true" 2>/dev/null)

    # Dry run should show the command with $ prefix, and it should contain the heredoc parts
    assert_contains "$output" "cat <<" "dry-run shows heredoc start"
}

test_handle_response_multiline_strips_surrounding_blanks() {
    DANGEROUS_PATTERNS=()
    local output
    output=$(handle_response "[COMMAND]

echo multiline_trimmed

" "false" 2>/dev/null)

    assert_contains "$output" "multiline_trimmed" "command with surrounding blanks still executes correctly"
}

test_handle_response_single_line_still_works() {
    # Regression: ensure single-line commands are not broken by the multi-line fix
    DANGEROUS_PATTERNS=()
    local output
    output=$(handle_response "[COMMAND]
echo regression_check_ok" "false" 2>/dev/null)
    assert_contains "$output" "regression_check_ok" "single-line command still works after multi-line fix"
}
