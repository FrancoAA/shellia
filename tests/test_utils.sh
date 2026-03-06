#!/usr/bin/env bash
# Tests for lib/utils.sh

test_version_is_set() {
    assert_not_empty "$SHELLIA_VERSION" "SHELLIA_VERSION is defined"
    assert_eq "$SHELLIA_VERSION" "0.1.0" "SHELLIA_VERSION is 0.1.0"
}

test_require_cmd_existing_command() {
    # jq is required by the test runner, so it must exist
    local output
    local exit_code=0
    output=$(require_cmd jq 2>&1) || exit_code=$?
    assert_eq "$exit_code" "0" "require_cmd jq succeeds"
}

test_require_cmd_missing_command() {
    local exit_code=0
    (require_cmd __nonexistent_cmd_xyz__ 2>/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "require_cmd fails for missing command"
}

test_log_info_writes_to_stderr() {
    local stderr_output
    stderr_output=$(log_info "test message" 2>&1 1>/dev/null)
    assert_contains "$stderr_output" "test message" "log_info writes to stderr"
}

test_log_success_writes_to_stderr() {
    local stderr_output
    stderr_output=$(log_success "success msg" 2>&1 1>/dev/null)
    assert_contains "$stderr_output" "success msg" "log_success writes to stderr"
}

test_log_warn_writes_to_stderr() {
    local stderr_output
    stderr_output=$(log_warn "warn msg" 2>&1 1>/dev/null)
    assert_contains "$stderr_output" "warn msg" "log_warn writes to stderr"
}

test_log_error_writes_to_stderr() {
    local stderr_output
    stderr_output=$(log_error "error msg" 2>&1 1>/dev/null)
    assert_contains "$stderr_output" "error msg" "log_error writes to stderr"
}

test_die_exits_with_code_1() {
    local exit_code=0
    (die "fatal error" 2>/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "die exits with code 1"
}

test_die_prints_error_message() {
    local stderr_output
    stderr_output=$(die "fatal error" 2>&1 1>/dev/null) || true
    assert_contains "$stderr_output" "fatal error" "die prints the error message"
}

test_debug_log_silent_when_disabled() {
    SHELLIA_DEBUG=false
    local output
    output=$(debug_log "tag" "message" 2>&1)
    assert_eq "$output" "" "debug_log is silent when SHELLIA_DEBUG=false"
}

test_debug_log_outputs_when_enabled() {
    SHELLIA_DEBUG=true
    local output
    output=$(debug_log "tag" "message" 2>&1)
    assert_contains "$output" "[debug]" "debug_log outputs [debug] prefix"
    assert_contains "$output" "tag" "debug_log outputs the tag"
    assert_contains "$output" "message" "debug_log outputs the message"
    SHELLIA_DEBUG=false
}

test_debug_block_silent_when_disabled() {
    SHELLIA_DEBUG=false
    local output
    output=$(debug_block "label" "line1
line2
line3" 2>&1)
    assert_eq "$output" "" "debug_block is silent when SHELLIA_DEBUG=false"
}

test_debug_block_outputs_when_enabled() {
    SHELLIA_DEBUG=true
    local output
    output=$(debug_block "label" "line1
line2" 2>&1)
    assert_contains "$output" "label" "debug_block outputs the label"
    assert_contains "$output" "line1" "debug_block outputs content"
    SHELLIA_DEBUG=false
}
