#!/usr/bin/env bash
# Test assertion helpers for shellia test suite

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0
CURRENT_TEST=""

# Colors for test output (always enabled in test runner)
_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[0;33m'
_BOLD='\033[1m'
_DIM='\033[2m'
_NC='\033[0m'

_pass() {
    ((TESTS_PASSED++))
    ((TESTS_TOTAL++))
    echo -e "  ${_GREEN}PASS${_NC} $1"
}

_fail() {
    ((TESTS_FAILED++))
    ((TESTS_TOTAL++))
    echo -e "  ${_RED}FAIL${_NC} $1"
    if [[ -n "${2:-}" ]]; then
        echo -e "       ${_DIM}$2${_NC}"
    fi
}

# Assert string equality
# Usage: assert_eq "$actual" "$expected" "description"
assert_eq() {
    local actual="$1"
    local expected="$2"
    local desc="${3:-assert_eq}"

    if [[ "$actual" == "$expected" ]]; then
        _pass "$desc"
    else
        _fail "$desc" "expected: '${expected}', got: '${actual}'"
    fi
}

# Assert string is not empty
# Usage: assert_not_empty "$value" "description"
assert_not_empty() {
    local value="$1"
    local desc="${2:-assert_not_empty}"

    if [[ -n "$value" ]]; then
        _pass "$desc"
    else
        _fail "$desc" "expected non-empty string, got empty"
    fi
}

# Assert string contains substring
# Usage: assert_contains "$string" "$substring" "description"
assert_contains() {
    local string="$1"
    local substring="$2"
    local desc="${3:-assert_contains}"

    if [[ "$string" == *"$substring"* ]]; then
        _pass "$desc"
    else
        _fail "$desc" "expected to contain: '${substring}'"
    fi
}

# Assert string does NOT contain substring
# Usage: assert_not_contains "$string" "$substring" "description"
assert_not_contains() {
    local string="$1"
    local substring="$2"
    local desc="${3:-assert_not_contains}"

    if [[ "$string" != *"$substring"* ]]; then
        _pass "$desc"
    else
        _fail "$desc" "expected NOT to contain: '${substring}'"
    fi
}

# Assert command exits with expected code
# Usage: assert_exit_code <expected_code> <command...>
assert_exit_code() {
    local expected="$1"
    shift
    local desc="exit code ${expected}: $*"

    local actual=0
    ("$@") >/dev/null 2>&1 || actual=$?

    if [[ "$actual" -eq "$expected" ]]; then
        _pass "$desc"
    else
        _fail "$desc" "expected exit code ${expected}, got ${actual}"
    fi
}

# Assert command stdout contains substring
# Usage: assert_stdout_contains <substring> <command...>
assert_stdout_contains() {
    local substring="$1"
    shift
    local desc="stdout contains '${substring}': $*"

    local output
    output=$("$@" 2>/dev/null) || true

    if [[ "$output" == *"$substring"* ]]; then
        _pass "$desc"
    else
        _fail "$desc" "stdout was: '${output}'"
    fi
}

# Assert command stderr contains substring
# Usage: assert_stderr_contains <substring> <command...>
assert_stderr_contains() {
    local substring="$1"
    shift
    local desc="stderr contains '${substring}': $*"

    local output
    output=$("$@" 2>&1 >/dev/null) || true

    if [[ "$output" == *"$substring"* ]]; then
        _pass "$desc"
    else
        _fail "$desc" "stderr was: '${output}'"
    fi
}

# Assert a file exists
# Usage: assert_file_exists "$path" "description"
assert_file_exists() {
    local path="$1"
    local desc="${2:-file exists: ${path}}"

    if [[ -f "$path" ]]; then
        _pass "$desc"
    else
        _fail "$desc" "file not found: ${path}"
    fi
}

# Assert valid JSON
# Usage: assert_valid_json "$string" "description"
assert_valid_json() {
    local string="$1"
    local desc="${2:-valid JSON}"

    if echo "$string" | jq . >/dev/null 2>&1; then
        _pass "$desc"
    else
        _fail "$desc" "invalid JSON: '${string}'"
    fi
}

# Unconditional failure
# Usage: fail "message"
fail() {
    _fail "${1:-unconditional failure}"
}

# Print test summary and return appropriate exit code
print_summary() {
    echo ""
    echo -e "${_BOLD}Results: ${TESTS_TOTAL} tests, ${_GREEN}${TESTS_PASSED} passed${_NC}, ${_RED}${TESTS_FAILED} failed${_NC}"
    return $TESTS_FAILED
}
