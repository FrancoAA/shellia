#!/usr/bin/env bash
set -uo pipefail

# Shellia test runner
# Creates an isolated temp environment, sources all lib files,
# discovers test_* functions from test files, runs each in a subshell.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${TESTS_DIR}/.." && pwd)"

# --- Create isolated test environment ---

TEST_TMP=$(mktemp -d)
trap "rm -rf '$TEST_TMP'" EXIT INT TERM

export SHELLIA_DIR="$PROJECT_DIR"

# Override all config paths to temp directory
export SHELLIA_CONFIG_DIR="$TEST_TMP/config"
export SHELLIA_CONFIG_FILE="$SHELLIA_CONFIG_DIR/config"
export SHELLIA_DANGEROUS_FILE="$SHELLIA_CONFIG_DIR/dangerous_commands"
export SHELLIA_USER_PROMPT_FILE="$SHELLIA_CONFIG_DIR/system_prompt"
export SHELLIA_PROFILES_FILE="$SHELLIA_CONFIG_DIR/profiles"

mkdir -p "$SHELLIA_CONFIG_DIR"

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for tests. Install it first."
    exit 1
fi

# --- Source test helpers ---

source "${TESTS_DIR}/test_helpers.sh"

# --- Source all lib files (order matters) ---

source "${PROJECT_DIR}/lib/utils.sh"
source "${PROJECT_DIR}/lib/config.sh"
source "${PROJECT_DIR}/lib/profiles.sh"
source "${PROJECT_DIR}/lib/prompt.sh"
source "${PROJECT_DIR}/lib/api.sh"
source "${PROJECT_DIR}/lib/executor.sh"
source "${PROJECT_DIR}/lib/themes.sh"
source "${PROJECT_DIR}/lib/tools.sh"
source "${PROJECT_DIR}/lib/repl.sh"
source "${PROJECT_DIR}/lib/plugins.sh"

# Disable debug noise during tests
SHELLIA_DEBUG=false

# Apply a default theme so THEME_* vars are set
apply_theme "default"

# Load tool definitions
load_tools

# --- Test discovery and execution ---

TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_COUNT=0
FAILED_FILES=()

# Filter: if args provided, only run those test files
TEST_FILTER="${1:-}"

run_test_file() {
    local test_file="$1"
    local file_name
    file_name=$(basename "$test_file" .sh)

    if [[ -n "$TEST_FILTER" && "$file_name" != *"$TEST_FILTER"* ]]; then
        return 0
    fi

    echo ""
    echo -e "${_BOLD}${_YELLOW}--- ${file_name} ---${_NC}"

    # Reset per-file counters
    TESTS_PASSED=0
    TESTS_FAILED=0
    TESTS_TOTAL=0

    # Source the test file to define its test functions
    source "$test_file"

    # Discover test_* functions defined in this file
    local test_functions
    test_functions=$(declare -F | awk '{print $3}' | grep "^test_" | sort)

    if [[ -z "$test_functions" ]]; then
        echo "  (no test functions found)"
        return 0
    fi

    # Run each test function in a subshell for isolation
    for func in $test_functions; do
        # Reset test environment for each test
        _reset_test_env

        # Run the test
        "$func"
    done

    # Accumulate totals
    ((TOTAL_PASSED += TESTS_PASSED))
    ((TOTAL_FAILED += TESTS_FAILED))
    ((TOTAL_COUNT += TESTS_TOTAL))

    if [[ $TESTS_FAILED -gt 0 ]]; then
        FAILED_FILES+=("$file_name")
    fi

    # Undefine test functions to avoid leaking between files
    for func in $test_functions; do
        unset -f "$func"
    done
}

# Reset the test environment between tests
_reset_test_env() {
    # Reset config dir contents
    rm -rf "${SHELLIA_CONFIG_DIR:?}"/*

    # Fully unset config vars so load_config can set them from file
    unset SHELLIA_API_URL SHELLIA_API_KEY SHELLIA_MODEL 2>/dev/null || true
    unset SHELLIA_PROFILE SHELLIA_THEME SHELLIA_AGENT_MODE 2>/dev/null || true

    # Set safe defaults for vars that need to exist (set -u protection)
    SHELLIA_API_URL=""
    SHELLIA_API_KEY=""
    SHELLIA_MODEL=""
    SHELLIA_PROFILE=""
    SHELLIA_THEME=""
    SHELLIA_AGENT_MODE=""
    SHELLIA_DEBUG=false

    # Reset dangerous patterns
    DANGEROUS_PATTERNS=()

    # Reset plugin state
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
    # Create per-test temp dir for plugin test isolation
    TEST_TMP_DIR=$(mktemp -d "${TEST_TMP}/test_XXXXXX")
}

# --- Run all test files ---

echo -e "${_BOLD}shellia test suite${_NC}"
echo -e "${_DIM}temp dir: ${TEST_TMP}${_NC}"

for test_file in "${TESTS_DIR}"/test_*.sh; do
    [[ "$test_file" == *"test_helpers.sh" ]] && continue
    [[ -f "$test_file" ]] || continue
    run_test_file "$test_file"
done

# --- Summary ---

echo ""
echo -e "${_BOLD}========================================${_NC}"
echo -e "${_BOLD}Total: ${TOTAL_COUNT} tests, ${_GREEN}${TOTAL_PASSED} passed${_NC}, ${_RED}${TOTAL_FAILED} failed${_NC}"

if [[ ${#FAILED_FILES[@]} -gt 0 ]]; then
    echo -e "${_RED}Failed in: ${FAILED_FILES[*]}${_NC}"
fi

echo -e "${_BOLD}========================================${_NC}"

exit $TOTAL_FAILED
