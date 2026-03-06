#!/usr/bin/env bash
# Tests for lib/executor.sh

test_load_dangerous_commands_from_defaults() {
    # Copy defaults to the test config dir
    cp "${SHELLIA_DIR}/defaults/dangerous_commands" "$SHELLIA_DANGEROUS_FILE"
    load_dangerous_commands

    local count=${#DANGEROUS_PATTERNS[@]}
    assert_not_empty "$count" "DANGEROUS_PATTERNS array is populated"
    # Default file has at least rm, sudo, mkfs
    local found_rm=false
    for p in "${DANGEROUS_PATTERNS[@]}"; do
        [[ "$p" == "rm" ]] && found_rm=true
    done
    if $found_rm; then
        _pass "DANGEROUS_PATTERNS includes 'rm'"
    else
        _fail "DANGEROUS_PATTERNS includes 'rm'" "pattern 'rm' not found"
    fi
}

test_load_dangerous_commands_skips_comments() {
    cat > "$SHELLIA_DANGEROUS_FILE" <<'EOF'
# comment
rm
# another comment
sudo
EOF
    load_dangerous_commands

    assert_eq "${#DANGEROUS_PATTERNS[@]}" "2" "load skips comments, keeps 2 patterns"
}

test_load_dangerous_commands_skips_empty_lines() {
    cat > "$SHELLIA_DANGEROUS_FILE" <<'EOF'
rm

sudo

EOF
    load_dangerous_commands

    assert_eq "${#DANGEROUS_PATTERNS[@]}" "2" "load skips blank lines, keeps 2 patterns"
}

test_is_dangerous_matches_dangerous_command() {
    DANGEROUS_PATTERNS=("rm" "sudo" "mkfs")

    is_dangerous "rm -rf /tmp/test"
    local result=$?
    assert_eq "$result" "0" "is_dangerous returns 0 for 'rm -rf /tmp/test'"

    is_dangerous "sudo apt update"
    result=$?
    assert_eq "$result" "0" "is_dangerous returns 0 for 'sudo apt update'"
}

test_is_dangerous_passes_safe_command() {
    DANGEROUS_PATTERNS=("rm" "sudo" "mkfs")

    is_dangerous "ls -la"
    local result=$?
    assert_eq "$result" "1" "is_dangerous returns 1 for 'ls -la'"

    is_dangerous "echo hello"
    result=$?
    assert_eq "$result" "1" "is_dangerous returns 1 for 'echo hello'"
}

test_is_dangerous_empty_patterns() {
    DANGEROUS_PATTERNS=()

    is_dangerous "rm -rf /"
    local result=$?
    assert_eq "$result" "1" "is_dangerous returns 1 when no patterns loaded"
}

test_execute_command_runs_safe_command() {
    DANGEROUS_PATTERNS=()
    local output
    output=$(execute_command "echo test_output_xyz" "false" 2>/dev/null)
    assert_contains "$output" "test_output_xyz" "execute_command runs and captures output"
}

test_execute_command_dry_run_shows_prefix() {
    DANGEROUS_PATTERNS=()
    local output
    output=$(execute_command "echo hello" "true" 2>/dev/null)
    assert_contains "$output" "$ echo hello" "dry-run shows the command with $ prefix"
}

test_execute_command_dry_run_does_not_produce_output() {
    DANGEROUS_PATTERNS=()
    # Use a marker that only appears if the command actually runs
    local output
    output=$(execute_command "echo MARKER_unique_42" "true" 2>/dev/null)
    # The $ prefix line will contain the command text, but the actual
    # execution output line (without $) should not appear
    local lines_without_prefix
    lines_without_prefix=$(echo "$output" | grep -v '^\$' | grep -c "MARKER_unique_42" || true)
    assert_eq "$lines_without_prefix" "0" "dry-run does not execute the command"
}

test_execute_plan_dry_run_shows_plan() {
    DANGEROUS_PATTERNS=()
    local plan='[{"description":"Create dir","command":"mkdir -p /tmp/test_shellia"},{"description":"List files","command":"ls /tmp"}]'

    local output
    output=$(execute_plan "$plan" "true" 2>&1)
    assert_contains "$output" "Plan (2 steps)" "execute_plan shows step count"
    assert_contains "$output" "Create dir" "execute_plan shows step descriptions"
    assert_contains "$output" "List files" "execute_plan shows all step descriptions"
    assert_contains "$output" "dry-run" "execute_plan notes dry-run mode"
}
