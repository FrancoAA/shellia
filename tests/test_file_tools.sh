#!/usr/bin/env bash
# Tests for file tools (lib/tools/search_files.sh)

# --- search_files schema tests ---

test_search_files_schema_valid() {
    local schema
    schema=$(tool_search_files_schema)
    assert_valid_json "$schema" "search_files schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "search_files" "search_files schema has correct name"

    local required
    required=$(echo "$schema" | jq -r '.function.parameters.required[0]')
    assert_eq "$required" "pattern" "search_files requires 'pattern' parameter"

    local has_path
    has_path=$(echo "$schema" | jq '.function.parameters.properties | has("path")')
    assert_eq "$has_path" "true" "search_files schema has 'path' parameter"
}

# --- search_files execution tests ---

test_search_files_basic_glob() {
    # Create test files
    mkdir -p "${TEST_TMP_DIR}/project"
    touch "${TEST_TMP_DIR}/project/foo.py"
    touch "${TEST_TMP_DIR}/project/bar.py"
    touch "${TEST_TMP_DIR}/project/baz.txt"

    local result
    result=$(tool_search_files_execute "{\"pattern\":\"*.py\",\"path\":\"${TEST_TMP_DIR}/project\"}" 2>/dev/null)

    assert_contains "$result" "foo.py" "search_files finds foo.py"
    assert_contains "$result" "bar.py" "search_files finds bar.py"
    assert_not_contains "$result" "baz.txt" "search_files excludes non-matching baz.txt"
}

test_search_files_defaults_to_pwd() {
    # Create test files in TEST_TMP_DIR, then run from there
    mkdir -p "${TEST_TMP_DIR}/subdir"
    touch "${TEST_TMP_DIR}/hello.sh"
    touch "${TEST_TMP_DIR}/subdir/world.sh"

    local result
    result=$(cd "${TEST_TMP_DIR}" && tool_search_files_execute '{"pattern":"*.sh"}' 2>/dev/null)

    assert_contains "$result" "hello.sh" "search_files finds files in PWD when no path given"
}

test_search_files_caps_at_max_results() {
    # Create more than max results (override to a small number for testing)
    mkdir -p "${TEST_TMP_DIR}/many"
    for i in $(seq 1 15); do
        touch "${TEST_TMP_DIR}/many/file_${i}.txt"
    done

    local result
    result=$(SHELLIA_MAX_SEARCH_RESULTS=10 tool_search_files_execute "{\"pattern\":\"*.txt\",\"path\":\"${TEST_TMP_DIR}/many\"}" 2>/dev/null)

    # Count lines of actual file paths (not the truncation marker)
    local file_count
    file_count=$(echo "$result" | grep -c "\.txt$" || true)

    local capped=false
    [[ "$file_count" -le 10 ]] && capped=true
    assert_eq "$capped" "true" "search_files caps results (got ${file_count}, max 10)"

    assert_contains "$result" "truncated" "search_files shows truncation marker when capped"
}

test_search_files_excludes_git_dir() {
    mkdir -p "${TEST_TMP_DIR}/repo/.git/objects"
    touch "${TEST_TMP_DIR}/repo/.git/objects/abc123"
    touch "${TEST_TMP_DIR}/repo/main.py"

    local result
    result=$(tool_search_files_execute "{\"pattern\":\"*\",\"path\":\"${TEST_TMP_DIR}/repo\"}" 2>/dev/null)

    assert_contains "$result" "main.py" "search_files finds main.py"
    assert_not_contains "$result" "abc123" "search_files excludes .git directory contents"
}

test_search_files_excludes_node_modules() {
    mkdir -p "${TEST_TMP_DIR}/webapp/node_modules/pkg"
    touch "${TEST_TMP_DIR}/webapp/node_modules/pkg/index.js"
    touch "${TEST_TMP_DIR}/webapp/app.js"

    local result
    result=$(tool_search_files_execute "{\"pattern\":\"*.js\",\"path\":\"${TEST_TMP_DIR}/webapp\"}" 2>/dev/null)

    assert_contains "$result" "app.js" "search_files finds app.js"
    assert_not_contains "$result" "index.js" "search_files excludes node_modules contents"
}

test_search_files_no_matches() {
    mkdir -p "${TEST_TMP_DIR}/empty"
    touch "${TEST_TMP_DIR}/empty/readme.md"

    local result
    result=$(tool_search_files_execute "{\"pattern\":\"*.xyz\",\"path\":\"${TEST_TMP_DIR}/empty\"}" 2>/dev/null)

    assert_contains "$result" "No files found" "search_files shows message when no matches"
}

test_search_files_path_pattern_with_slash() {
    # Patterns containing / should use -path instead of -name
    mkdir -p "${TEST_TMP_DIR}/src/components"
    touch "${TEST_TMP_DIR}/src/components/Button.tsx"
    touch "${TEST_TMP_DIR}/src/components/Card.tsx"
    touch "${TEST_TMP_DIR}/src/index.ts"

    local result
    result=$(tool_search_files_execute "{\"pattern\":\"src/**/*.tsx\",\"path\":\"${TEST_TMP_DIR}\"}" 2>/dev/null)

    assert_contains "$result" "Button.tsx" "search_files finds Button.tsx with path pattern"
    assert_contains "$result" "Card.tsx" "search_files finds Card.tsx with path pattern"
    assert_not_contains "$result" "index.ts" "search_files excludes non-matching index.ts"
}
