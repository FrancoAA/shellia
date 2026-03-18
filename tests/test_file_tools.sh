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

test_search_files_invalid_directory() {
    local result
    local exit_code=0
    result=$(tool_search_files_execute '{"pattern":"*.py","path":"/nonexistent/fake/dir"}' 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "1" "search_files returns exit code 1 for invalid directory"
    assert_contains "$result" "Error: directory not found" "search_files shows error for invalid directory"
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

# --- search_content schema tests ---

test_search_content_schema_valid() {
    local schema
    schema=$(tool_search_content_schema)
    assert_valid_json "$schema" "search_content schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "search_content" "search_content schema has correct name"

    local required
    required=$(echo "$schema" | jq -r '.function.parameters.required[0]')
    assert_eq "$required" "pattern" "search_content requires 'pattern' parameter"

    local has_path
    has_path=$(echo "$schema" | jq '.function.parameters.properties | has("path")')
    assert_eq "$has_path" "true" "search_content schema has 'path' parameter"

    local has_include
    has_include=$(echo "$schema" | jq '.function.parameters.properties | has("include")')
    assert_eq "$has_include" "true" "search_content schema has 'include' parameter"
}

# --- search_content execution tests ---

test_search_content_basic_matching() {
    mkdir -p "${TEST_TMP_DIR}/project"
    echo 'function hello() { return "world"; }' > "${TEST_TMP_DIR}/project/app.js"
    echo 'function goodbye() { return "moon"; }' > "${TEST_TMP_DIR}/project/util.js"
    echo 'no match here' > "${TEST_TMP_DIR}/project/readme.txt"

    local result
    result=$(tool_search_content_execute "{\"pattern\":\"function\",\"path\":\"${TEST_TMP_DIR}/project\"}" 2>/dev/null)

    assert_contains "$result" "app.js" "search_content finds match in app.js"
    assert_contains "$result" "util.js" "search_content finds match in util.js"
    assert_not_contains "$result" "readme.txt" "search_content excludes non-matching file"
}

test_search_content_include_filter() {
    mkdir -p "${TEST_TMP_DIR}/filtered"
    echo 'hello world' > "${TEST_TMP_DIR}/filtered/file.js"
    echo 'hello world' > "${TEST_TMP_DIR}/filtered/file.py"
    echo 'hello world' > "${TEST_TMP_DIR}/filtered/file.txt"

    local result
    result=$(tool_search_content_execute "{\"pattern\":\"hello\",\"path\":\"${TEST_TMP_DIR}/filtered\",\"include\":\"*.js\"}" 2>/dev/null)

    assert_contains "$result" "file.js" "search_content include filter finds .js file"
    assert_not_contains "$result" "file.py" "search_content include filter excludes .py file"
    assert_not_contains "$result" "file.txt" "search_content include filter excludes .txt file"
}

test_search_content_caps_results() {
    mkdir -p "${TEST_TMP_DIR}/many_matches"
    # Create a file with 15 matching lines
    for i in $(seq 1 15); do
        echo "match_line_${i}" >> "${TEST_TMP_DIR}/many_matches/big.txt"
    done

    local result
    result=$(SHELLIA_MAX_SEARCH_RESULTS=5 tool_search_content_execute "{\"pattern\":\"match_line\",\"path\":\"${TEST_TMP_DIR}/many_matches\"}" 2>/dev/null)

    # Should contain truncation marker
    assert_contains "$result" "truncated" "search_content shows truncation marker when capped"
    assert_contains "$result" "5 of" "search_content shows cap count"
}

test_search_content_no_matches() {
    mkdir -p "${TEST_TMP_DIR}/nomatch"
    echo 'nothing relevant here' > "${TEST_TMP_DIR}/nomatch/file.txt"

    local result
    result=$(tool_search_content_execute "{\"pattern\":\"zzz_nonexistent_zzz\",\"path\":\"${TEST_TMP_DIR}/nomatch\"}" 2>/dev/null)

    assert_contains "$result" "No matches found" "search_content shows no-matches message"
}

test_search_content_excludes_git_dir() {
    mkdir -p "${TEST_TMP_DIR}/repo2/.git/refs"
    echo 'secret_content' > "${TEST_TMP_DIR}/repo2/.git/refs/heads"
    echo 'secret_content' > "${TEST_TMP_DIR}/repo2/main.py"

    local result
    result=$(tool_search_content_execute "{\"pattern\":\"secret_content\",\"path\":\"${TEST_TMP_DIR}/repo2\"}" 2>/dev/null)

    assert_contains "$result" "main.py" "search_content finds match in main.py"
    assert_not_contains "$result" ".git" "search_content excludes .git directory contents"
}

test_search_content_invalid_directory() {
    local result
    local exit_code=0
    result=$(tool_search_content_execute '{"pattern":"hello","path":"/nonexistent/fake/dir"}' 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "1" "search_content returns exit code 1 for invalid directory"
    assert_contains "$result" "Error: directory not found" "search_content shows error for invalid directory"
}

# --- read_file schema tests ---

test_read_file_schema_valid() {
    local schema
    schema=$(tool_read_file_schema)
    assert_valid_json "$schema" "read_file schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "read_file" "read_file schema has correct name"

    local required
    required=$(echo "$schema" | jq -r '.function.parameters.required[0]')
    assert_eq "$required" "path" "read_file requires 'path' parameter"

    local has_offset
    has_offset=$(echo "$schema" | jq '.function.parameters.properties | has("offset")')
    assert_eq "$has_offset" "true" "read_file schema has 'offset' parameter"

    local has_limit
    has_limit=$(echo "$schema" | jq '.function.parameters.properties | has("limit")')
    assert_eq "$has_limit" "true" "read_file schema has 'limit' parameter"
}

# --- read_file execution tests ---

test_read_file_basic_with_line_numbers() {
    # Create a test file with known content
    printf 'line one\nline two\nline three\n' > "${TEST_TMP_DIR}/basic.txt"

    local result
    result=$(tool_read_file_execute "{\"path\":\"${TEST_TMP_DIR}/basic.txt\"}" 2>/dev/null)

    assert_contains "$result" "1: line one" "read_file shows line 1 with number prefix"
    assert_contains "$result" "2: line two" "read_file shows line 2 with number prefix"
    assert_contains "$result" "3: line three" "read_file shows line 3 with number prefix"
    assert_contains "$result" "[lines 1-3 of 3 total]" "read_file shows header with line range"
}

test_read_file_with_offset_and_limit() {
    # Create a file with 10 lines
    for i in $(seq 1 10); do
        echo "content line ${i}"
    done > "${TEST_TMP_DIR}/tenlines.txt"

    local result
    result=$(tool_read_file_execute "{\"path\":\"${TEST_TMP_DIR}/tenlines.txt\",\"offset\":3,\"limit\":4}" 2>/dev/null)

    assert_contains "$result" "3: content line 3" "read_file offset shows line 3"
    assert_contains "$result" "6: content line 6" "read_file offset shows line 6"
    assert_not_contains "$result" "2: content line 2" "read_file offset excludes line 2"
    assert_not_contains "$result" "7: content line 7" "read_file offset excludes line 7"
    assert_contains "$result" "[lines 3-6 of 10 total]" "read_file shows correct header with offset/limit"
}

test_read_file_with_float_offset_and_limit() {
    # Create a file with 10 lines
    for i in $(seq 1 10); do
        echo "content line ${i}"
    done > "${TEST_TMP_DIR}/tenlines.txt"

    local result
    # Test with float values (e.g., 3.0 and 4.5) - should be converted to integers
    result=$(tool_read_file_execute "{\"path\":\"${TEST_TMP_DIR}/tenlines.txt\",\"offset\":3.0,\"limit\":4.5}" 2>/dev/null)

    assert_contains "$result" "3: content line 3" "read_file handles float offset 3.0"
    assert_contains "$result" "6: content line 6" "read_file handles float limit 4.5"
    assert_contains "$result" "[lines 3-6 of 10 total]" "read_file shows correct header with float offset/limit"
}

test_read_file_with_integer_float_equivalents() {
    # Create a file with 10 lines
    for i in $(seq 1 10); do
        echo "content line ${i}"
    done > "${TEST_TMP_DIR}/tenlines.txt"

    local result
    # Test with integer-like floats (e.g., 2.0 and 5.0) - should work the same as integers
    result=$(tool_read_file_execute "{\"path\":\"${TEST_TMP_DIR}/tenlines.txt\",\"offset\":2.0,\"limit\":5.0}" 2>/dev/null)

    assert_contains "$result" "2: content line 2" "read_file handles integer float offset 2.0"
    assert_contains "$result" "6: content line 6" "read_file handles integer float limit 5.0"
    assert_contains "$result" "[lines 2-6 of 10 total]" "read_file shows correct header with integer float values"
}

test_read_file_not_found() {
    local result
    local exit_code=0
    result=$(tool_read_file_execute "{\"path\":\"${TEST_TMP_DIR}/nonexistent_file.txt\"}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "1" "read_file returns exit code 1 for missing file"
    assert_contains "$result" "Error: file not found" "read_file shows error for missing file"
}

test_read_file_binary_detection() {
    # Create a binary file with some non-text bytes
    printf '\x00\x01\x02\x03\xff\xfe' > "${TEST_TMP_DIR}/binary.dat"

    local result
    result=$(tool_read_file_execute "{\"path\":\"${TEST_TMP_DIR}/binary.dat\"}" 2>/dev/null)

    assert_contains "$result" "[binary file:" "read_file detects binary file"
    assert_contains "$result" "bytes]" "read_file shows size for binary file"
}

test_read_file_line_truncation() {
    # Create a file with a line longer than 2000 characters
    local long_line
    long_line=$(printf '%0.sa' $(seq 1 2500))
    echo "$long_line" > "${TEST_TMP_DIR}/longline.txt"

    local result
    result=$(SHELLIA_MAX_LINE_LENGTH=2000 tool_read_file_execute "{\"path\":\"${TEST_TMP_DIR}/longline.txt\"}" 2>/dev/null)

    assert_contains "$result" "...[truncated]" "read_file truncates long lines"
}

test_read_file_default_limit_caps_output() {
    # Create a file with 250 lines
    for i in $(seq 1 250); do
        echo "row ${i}"
    done > "${TEST_TMP_DIR}/manylines.txt"

    local result
    result=$(SHELLIA_MAX_READ_LINES=200 tool_read_file_execute "{\"path\":\"${TEST_TMP_DIR}/manylines.txt\"}" 2>/dev/null)

    # Should only show 200 lines (1-200), not line 201
    assert_contains "$result" "200: row 200" "read_file shows line 200"
    assert_not_contains "$result" "201: row 201" "read_file caps at default 200 lines"
    assert_contains "$result" "[lines 1-200 of 250 total]" "read_file header reflects capped output"
}

test_read_file_empty_file() {
    # Create an empty file — should not be detected as binary
    touch "${TEST_TMP_DIR}/empty.txt"

    local result
    local exit_code=0
    result=$(tool_read_file_execute "{\"path\":\"${TEST_TMP_DIR}/empty.txt\"}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "0" "read_file returns exit code 0 for empty file"
    assert_contains "$result" "(empty file)" "read_file shows empty file message"
    assert_contains "$result" "[lines 0-0 of 0 total]" "read_file shows correct header for empty file"
    assert_not_contains "$result" "binary" "read_file does not flag empty file as binary"
}

test_read_file_directory_listing() {
    # Create a directory structure
    mkdir -p "${TEST_TMP_DIR}/mydir/subdir"
    touch "${TEST_TMP_DIR}/mydir/file1.txt"
    touch "${TEST_TMP_DIR}/mydir/file2.py"

    local result
    result=$(tool_read_file_execute "{\"path\":\"${TEST_TMP_DIR}/mydir\"}" 2>/dev/null)

    assert_contains "$result" "subdir/" "read_file marks subdirectories with trailing /"
    assert_contains "$result" "file1.txt" "read_file lists files in directory"
    assert_contains "$result" "file2.py" "read_file lists all files in directory"
}

# --- edit_file schema tests ---

test_edit_file_schema_valid() {
    local schema
    schema=$(tool_edit_file_schema)
    assert_valid_json "$schema" "edit_file schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "edit_file" "edit_file schema has correct name"

    local required
    required=$(echo "$schema" | jq -r '.function.parameters.required | sort | join(",")')
    assert_eq "$required" "new_string,old_string,path" "edit_file requires path, old_string, new_string"

    local has_replace_all
    has_replace_all=$(echo "$schema" | jq '.function.parameters.properties | has("replace_all")')
    assert_eq "$has_replace_all" "true" "edit_file schema has 'replace_all' parameter"
}

# --- edit_file execution tests ---

test_edit_file_single_replacement() {
    printf 'hello world\ngoodbye world\n' > "${TEST_TMP_DIR}/edit1.txt"

    local result
    local exit_code=0
    result=$(tool_edit_file_execute "{\"path\":\"${TEST_TMP_DIR}/edit1.txt\",\"old_string\":\"hello\",\"new_string\":\"hi\"}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "0" "edit_file single replacement exits 0"
    assert_contains "$result" "OK: replaced 1 occurrence(s)" "edit_file reports 1 replacement"

    local content
    content=$(cat "${TEST_TMP_DIR}/edit1.txt")
    assert_contains "$content" "hi world" "edit_file replaced hello with hi"
    assert_contains "$content" "goodbye world" "edit_file left other line untouched"
}

test_edit_file_multiline_replacement() {
    printf 'line one\nline two\nline three\n' > "${TEST_TMP_DIR}/edit_multi.txt"

    local old_str='line one
line two'
    local new_str='replaced first
replaced second'

    # Build JSON with jq to handle multiline strings safely
    local args_json
    args_json=$(jq -n \
        --arg path "${TEST_TMP_DIR}/edit_multi.txt" \
        --arg old "$old_str" \
        --arg new "$new_str" \
        '{path: $path, old_string: $old, new_string: $new}')

    local result
    local exit_code=0
    result=$(tool_edit_file_execute "$args_json" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "0" "edit_file multiline replacement exits 0"
    assert_contains "$result" "OK: replaced 1 occurrence(s)" "edit_file reports 1 multiline replacement"

    local content
    content=$(cat "${TEST_TMP_DIR}/edit_multi.txt")
    assert_contains "$content" "replaced first" "edit_file multiline: first replacement line present"
    assert_contains "$content" "replaced second" "edit_file multiline: second replacement line present"
    assert_contains "$content" "line three" "edit_file multiline: untouched line preserved"
    assert_not_contains "$content" "line one" "edit_file multiline: old first line removed"
}

test_edit_file_not_found() {
    local result
    local exit_code=0
    result=$(tool_edit_file_execute "{\"path\":\"${TEST_TMP_DIR}/nonexistent.txt\",\"old_string\":\"x\",\"new_string\":\"y\"}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "1" "edit_file returns exit code 1 for missing file"
    assert_contains "$result" "Error: file not found" "edit_file shows error for missing file"
}

test_edit_file_old_string_not_found() {
    printf 'some content here\n' > "${TEST_TMP_DIR}/edit_nomatch.txt"

    local result
    local exit_code=0
    result=$(tool_edit_file_execute "{\"path\":\"${TEST_TMP_DIR}/edit_nomatch.txt\",\"old_string\":\"zzz_missing_zzz\",\"new_string\":\"replacement\"}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "1" "edit_file returns exit code 1 when old_string not found"
    assert_contains "$result" "Error: old_string not found" "edit_file shows error when old_string not found"
}

test_edit_file_multiple_matches_blocked() {
    printf 'foo bar foo baz foo\n' > "${TEST_TMP_DIR}/edit_multi_match.txt"

    local result
    local exit_code=0
    result=$(tool_edit_file_execute "{\"path\":\"${TEST_TMP_DIR}/edit_multi_match.txt\",\"old_string\":\"foo\",\"new_string\":\"qux\"}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "1" "edit_file returns exit code 1 for multiple matches without replace_all"
    assert_contains "$result" "found 3 matches" "edit_file reports match count"
    assert_contains "$result" "replace_all" "edit_file suggests replace_all"

    # File should be unchanged
    local content
    content=$(cat "${TEST_TMP_DIR}/edit_multi_match.txt")
    assert_contains "$content" "foo bar foo baz foo" "edit_file leaves file unchanged on multiple match error"
}

test_edit_file_replace_all() {
    printf 'foo bar foo baz foo\n' > "${TEST_TMP_DIR}/edit_all.txt"

    local result
    local exit_code=0
    result=$(tool_edit_file_execute "{\"path\":\"${TEST_TMP_DIR}/edit_all.txt\",\"old_string\":\"foo\",\"new_string\":\"qux\",\"replace_all\":true}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "0" "edit_file replace_all exits 0"
    assert_contains "$result" "OK: replaced 3 occurrence(s)" "edit_file reports 3 replacements"

    local content
    content=$(cat "${TEST_TMP_DIR}/edit_all.txt")
    assert_eq "$content" "qux bar qux baz qux" "edit_file replace_all replaced all occurrences"
}

test_edit_file_preserves_permissions() {
    printf '#!/bin/bash\necho hello\n' > "${TEST_TMP_DIR}/edit_perms.sh"
    chmod 755 "${TEST_TMP_DIR}/edit_perms.sh"

    local result
    local exit_code=0
    result=$(tool_edit_file_execute "{\"path\":\"${TEST_TMP_DIR}/edit_perms.sh\",\"old_string\":\"hello\",\"new_string\":\"world\"}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "0" "edit_file preserves permissions: exits 0"

    # Check permissions are still 755
    local perms
    perms=$(stat -f '%Lp' "${TEST_TMP_DIR}/edit_perms.sh" 2>/dev/null || stat -c '%a' "${TEST_TMP_DIR}/edit_perms.sh" 2>/dev/null)
    assert_eq "$perms" "755" "edit_file preserves 755 permissions after edit"
}

test_edit_file_identical_strings_error() {
    printf 'some content\n' > "${TEST_TMP_DIR}/edit_same.txt"

    local result
    local exit_code=0
    result=$(tool_edit_file_execute "{\"path\":\"${TEST_TMP_DIR}/edit_same.txt\",\"old_string\":\"some\",\"new_string\":\"some\"}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "1" "edit_file returns exit code 1 when old_string equals new_string"
    assert_contains "$result" "old_string and new_string are identical" "edit_file shows error for identical strings"
}

# --- write_file schema tests ---

test_write_file_schema_valid() {
    local schema
    schema=$(tool_write_file_schema)
    assert_valid_json "$schema" "write_file schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "write_file" "write_file schema has correct name"

    local required
    required=$(echo "$schema" | jq -r '.function.parameters.required | sort | join(",")')
    assert_eq "$required" "content,path" "write_file requires path and content"
}

# --- write_file execution tests ---

test_write_file_creates_new_file() {
    local target="${TEST_TMP_DIR}/newfile.txt"

    local result
    local exit_code=0
    result=$(tool_write_file_execute "{\"path\":\"${target}\",\"content\":\"hello world\"}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "0" "write_file exits 0 for new file"
    assert_file_exists "$target" "write_file created the file"

    local content
    content=$(cat "$target")
    assert_eq "$content" "hello world" "write_file wrote correct content"

    assert_contains "$result" "OK: wrote" "write_file reports OK"
    assert_contains "$result" "11 bytes" "write_file reports correct byte count"
    assert_not_contains "$result" "overwriting" "write_file does not mention overwriting for new file"
}

test_write_file_creates_parent_directories() {
    local target="${TEST_TMP_DIR}/deep/nested/dir/file.txt"

    local result
    local exit_code=0
    result=$(tool_write_file_execute "{\"path\":\"${target}\",\"content\":\"nested content\"}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "0" "write_file exits 0 when creating parent dirs"
    assert_file_exists "$target" "write_file created file in nested directory"

    local content
    content=$(cat "$target")
    assert_eq "$content" "nested content" "write_file wrote correct content in nested dir"
}

test_write_file_overwrites_existing_file() {
    local target="${TEST_TMP_DIR}/existing.txt"
    printf 'old content' > "$target"

    local result
    local exit_code=0
    result=$(tool_write_file_execute "{\"path\":\"${target}\",\"content\":\"new content\"}" 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "0" "write_file exits 0 when overwriting"
    assert_contains "$result" "overwriting existing file" "write_file notes overwriting"

    local content
    content=$(cat "$target")
    assert_eq "$content" "new content" "write_file overwrote with new content"
}

test_write_file_reports_byte_count() {
    local target="${TEST_TMP_DIR}/bytes.txt"

    local result
    result=$(tool_write_file_execute "{\"path\":\"${target}\",\"content\":\"abc\"}" 2>/dev/null)

    assert_contains "$result" "3 bytes" "write_file reports 3 bytes for 'abc'"
}
