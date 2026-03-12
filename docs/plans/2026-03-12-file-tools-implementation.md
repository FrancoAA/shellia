# File Operation Tools — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add 5 file operation tools (search_files, search_content, read_file, edit_file, write_file) with built-in output control to protect the LLM context window.

**Architecture:** Each tool is a self-contained bash file in `lib/tools/` following the `tool_<name>_schema()` / `tool_<name>_execute()` convention. Tools are auto-discovered by `lib/tools.sh` at startup. Output is capped by constants (100 results, 200 lines, 50KB bytes, 2000 char lines).

**Tech Stack:** Pure bash, jq for JSON parameter extraction, standard Unix tools (find, grep/rg, awk, wc).

**Design Doc:** `docs/plans/2026-03-12-file-tools-design.md`

---

### Task 1: `search_files` tool

**Files:**
- Create: `lib/tools/search_files.sh`
- Test: `tests/test_file_tools.sh` (create — will hold all file tool tests)

**Step 1: Write the test file with search_files tests**

Create `tests/test_file_tools.sh`:

```bash
#!/usr/bin/env bash
# Tests for file operation tools (search_files, search_content, read_file, edit_file, write_file)

# --- search_files tests ---

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
}

test_search_files_finds_by_glob() {
    # Create test files
    mkdir -p "${TEST_TMP_DIR}/project/src"
    touch "${TEST_TMP_DIR}/project/src/main.py"
    touch "${TEST_TMP_DIR}/project/src/utils.py"
    touch "${TEST_TMP_DIR}/project/README.md"

    local result
    result=$(tool_search_files_execute "$(printf '{"pattern":"*.py","path":"%s"}' "${TEST_TMP_DIR}/project")" 2>/dev/null)
    assert_contains "$result" "main.py" "search_files finds main.py"
    assert_contains "$result" "utils.py" "search_files finds utils.py"
    assert_not_contains "$result" "README.md" "search_files excludes non-matching files"
}

test_search_files_defaults_to_pwd() {
    mkdir -p "${TEST_TMP_DIR}/pwd_test"
    touch "${TEST_TMP_DIR}/pwd_test/file.txt"

    local result
    result=$(cd "${TEST_TMP_DIR}/pwd_test" && tool_search_files_execute '{"pattern":"*.txt"}' 2>/dev/null)
    assert_contains "$result" "file.txt" "search_files uses PWD when no path given"
}

test_search_files_caps_results() {
    mkdir -p "${TEST_TMP_DIR}/many_files"
    for i in $(seq 1 110); do
        touch "${TEST_TMP_DIR}/many_files/file_${i}.txt"
    done

    local result
    result=$(tool_search_files_execute "$(printf '{"pattern":"*.txt","path":"%s"}' "${TEST_TMP_DIR}/many_files")" 2>/dev/null)
    assert_contains "$result" "truncated" "search_files shows truncation marker when over 100 results"
}

test_search_files_excludes_git_dir() {
    mkdir -p "${TEST_TMP_DIR}/git_test/.git/objects"
    touch "${TEST_TMP_DIR}/git_test/.git/objects/pack.idx"
    touch "${TEST_TMP_DIR}/git_test/visible.idx"

    local result
    result=$(tool_search_files_execute "$(printf '{"pattern":"*.idx","path":"%s"}' "${TEST_TMP_DIR}/git_test")" 2>/dev/null)
    assert_contains "$result" "visible.idx" "search_files shows non-git files"
    assert_not_contains "$result" "pack.idx" "search_files excludes .git directory"
}

test_search_files_no_matches() {
    mkdir -p "${TEST_TMP_DIR}/empty_search"
    touch "${TEST_TMP_DIR}/empty_search/file.txt"

    local result
    result=$(tool_search_files_execute "$(printf '{"pattern":"*.xyz","path":"%s"}' "${TEST_TMP_DIR}/empty_search")" 2>/dev/null)
    assert_contains "$result" "No files found" "search_files shows message when no matches"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh file_tools`
Expected: FAIL — `tool_search_files_schema: command not found`

**Step 3: Write the search_files implementation**

Create `lib/tools/search_files.sh`:

```bash
#!/usr/bin/env bash
# Tool: search_files — find files by glob pattern

# Output control constants
_SEARCH_FILES_MAX_RESULTS="${SHELLIA_MAX_SEARCH_RESULTS:-100}"

tool_search_files_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "search_files",
        "description": "Find files by name/glob pattern. Returns matching file paths sorted by modification time (newest first). Use this instead of running 'find' via run_command — results are capped to prevent context overflow. Supports glob patterns like '*.py', '*.{ts,tsx}', or 'test_*.sh'.",
        "parameters": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Glob pattern to match file names (e.g. '*.py', 'src/**/*.ts', 'Makefile')"
                },
                "path": {
                    "type": "string",
                    "description": "Directory to search in. Defaults to the current working directory if not specified."
                }
            },
            "required": ["pattern"]
        }
    }
}
EOF
}

tool_search_files_execute() {
    local args_json="$1"
    local pattern path
    pattern=$(echo "$args_json" | jq -r '.pattern')
    path=$(echo "$args_json" | jq -r '.path // empty')
    path="${path:-$PWD}"

    debug_log "tool" "search_files: pattern=${pattern} path=${path}"

    # Validate path exists
    if [[ ! -d "$path" ]]; then
        echo "Error: directory not found: ${path}"
        return 1
    fi

    # Build exclusion args for find
    local exclude_args=(
        -not -path '*/.git/*'
        -not -path '*/node_modules/*'
        -not -path '*/__pycache__/*'
        -not -path '*/.venv/*'
        -not -path '*/vendor/*'
        -not -path '*/dist/*'
        -not -path '*/build/*'
        -not -path '*/.next/*'
        -not -path '*/coverage/*'
    )

    # Determine whether to use -name or -path based on pattern containing /
    local find_flag="-name"
    if [[ "$pattern" == */* ]]; then
        find_flag="-path"
        # Prepend */ so -path matches relative to search dir
        [[ "$pattern" != \** ]] && pattern="*/${pattern}"
    fi

    # Run find, sort by mtime (newest first), capture results
    local results
    results=$(find "$path" -type f "${exclude_args[@]}" "$find_flag" "$pattern" \
        -printf '%T@\t%p\n' 2>/dev/null | sort -rn | cut -f2-)

    # macOS fallback: find doesn't support -printf
    if [[ -z "$results" && $? -ne 0 ]] || [[ "$(uname)" == "Darwin" && -z "$results" ]]; then
        results=$(find "$path" -type f "${exclude_args[@]}" "$find_flag" "$pattern" 2>/dev/null)
        if [[ -n "$results" ]]; then
            # Sort by mtime on macOS using stat
            results=$(echo "$results" | while IFS= read -r f; do
                stat -f '%m %N' "$f" 2>/dev/null
            done | sort -rn | awk '{print $2}')
        fi
    fi

    if [[ -z "$results" ]]; then
        echo "No files found matching '${pattern}' in ${path}"
        return 0
    fi

    # Count total and cap results
    local total_count
    total_count=$(echo "$results" | wc -l | tr -d ' ')
    local output
    output=$(echo "$results" | head -n "$_SEARCH_FILES_MAX_RESULTS")

    # Make paths relative to search dir for readability
    output=$(echo "$output" | sed "s|^${path}/||")

    if [[ "$total_count" -gt "$_SEARCH_FILES_MAX_RESULTS" ]]; then
        printf '%s\n[truncated: showing %d of %d matches]' "$output" "$_SEARCH_FILES_MAX_RESULTS" "$total_count"
    else
        echo "$output"
    fi
}
```

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh file_tools`
Expected: All search_files tests PASS

**Step 5: Commit**

```bash
git add lib/tools/search_files.sh tests/test_file_tools.sh
git commit -m "feat: add search_files tool for glob-based file discovery"
```

---

### Task 2: `search_content` tool

**Files:**
- Create: `lib/tools/search_content.sh`
- Modify: `tests/test_file_tools.sh` (append tests)

**Step 1: Write tests for search_content**

Append to `tests/test_file_tools.sh`:

```bash
# --- search_content tests ---

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
}

test_search_content_finds_matches() {
    mkdir -p "${TEST_TMP_DIR}/grep_test"
    echo 'function hello() { return "world"; }' > "${TEST_TMP_DIR}/grep_test/app.js"
    echo 'function goodbye() { return "moon"; }' > "${TEST_TMP_DIR}/grep_test/other.js"

    local result
    result=$(tool_search_content_execute "$(printf '{"pattern":"hello","path":"%s"}' "${TEST_TMP_DIR}/grep_test")" 2>/dev/null)
    assert_contains "$result" "app.js" "search_content finds file with match"
    assert_contains "$result" "hello" "search_content shows matching content"
    assert_not_contains "$result" "goodbye" "search_content excludes non-matching content"
}

test_search_content_include_filter() {
    mkdir -p "${TEST_TMP_DIR}/filter_test"
    echo 'TODO: fix this' > "${TEST_TMP_DIR}/filter_test/code.py"
    echo 'TODO: fix that' > "${TEST_TMP_DIR}/filter_test/notes.md"

    local result
    result=$(tool_search_content_execute "$(printf '{"pattern":"TODO","path":"%s","include":"*.py"}' "${TEST_TMP_DIR}/filter_test")" 2>/dev/null)
    assert_contains "$result" "code.py" "search_content with include filter finds matching file type"
    assert_not_contains "$result" "notes.md" "search_content with include filter excludes other file types"
}

test_search_content_caps_results() {
    mkdir -p "${TEST_TMP_DIR}/many_matches"
    # Create a file with >100 matching lines
    for i in $(seq 1 110); do
        echo "match_line_${i}" >> "${TEST_TMP_DIR}/many_matches/big.txt"
    done

    local result
    result=$(tool_search_content_execute "$(printf '{"pattern":"match_line","path":"%s"}' "${TEST_TMP_DIR}/many_matches")" 2>/dev/null)
    assert_contains "$result" "truncated" "search_content shows truncation marker when over 100 matches"
}

test_search_content_no_matches() {
    mkdir -p "${TEST_TMP_DIR}/no_match"
    echo 'some content' > "${TEST_TMP_DIR}/no_match/file.txt"

    local result
    result=$(tool_search_content_execute "$(printf '{"pattern":"zzz_nonexistent","path":"%s"}' "${TEST_TMP_DIR}/no_match")" 2>/dev/null)
    assert_contains "$result" "No matches found" "search_content shows message when no matches"
}

test_search_content_excludes_git_dir() {
    mkdir -p "${TEST_TMP_DIR}/git_grep/.git/refs"
    echo 'secret_token' > "${TEST_TMP_DIR}/git_grep/.git/refs/heads"
    echo 'secret_token' > "${TEST_TMP_DIR}/git_grep/visible.txt"

    local result
    result=$(tool_search_content_execute "$(printf '{"pattern":"secret_token","path":"%s"}' "${TEST_TMP_DIR}/git_grep")" 2>/dev/null)
    assert_contains "$result" "visible.txt" "search_content shows non-git matches"
    assert_not_contains "$result" ".git" "search_content excludes .git directory"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh file_tools`
Expected: search_content tests FAIL — `tool_search_content_schema: command not found`

**Step 3: Write the search_content implementation**

Create `lib/tools/search_content.sh`:

```bash
#!/usr/bin/env bash
# Tool: search_content — search file contents by regex

# Output control constants
_SEARCH_CONTENT_MAX_RESULTS="${SHELLIA_MAX_SEARCH_RESULTS:-100}"
_SEARCH_CONTENT_MAX_LINE_LENGTH="${SHELLIA_MAX_LINE_LENGTH:-2000}"

tool_search_content_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "search_content",
        "description": "Search file contents using a regular expression. Returns matching lines as 'filepath:line_number: content'. Use this instead of running 'grep' via run_command — results are capped and common noise directories are excluded automatically.",
        "parameters": {
            "type": "object",
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Regular expression pattern to search for in file contents"
                },
                "path": {
                    "type": "string",
                    "description": "Directory to search in. Defaults to the current working directory."
                },
                "include": {
                    "type": "string",
                    "description": "File glob filter to limit search scope (e.g. '*.js', '*.{ts,tsx}')"
                }
            },
            "required": ["pattern"]
        }
    }
}
EOF
}

tool_search_content_execute() {
    local args_json="$1"
    local pattern path include
    pattern=$(echo "$args_json" | jq -r '.pattern')
    path=$(echo "$args_json" | jq -r '.path // empty')
    path="${path:-$PWD}"
    include=$(echo "$args_json" | jq -r '.include // empty')

    debug_log "tool" "search_content: pattern=${pattern} path=${path} include=${include}"

    # Validate path exists
    if [[ ! -d "$path" ]]; then
        echo "Error: directory not found: ${path}"
        return 1
    fi

    local results
    local total_count=0

    # Common exclusion dirs
    local exclude_dirs=(.git node_modules __pycache__ .venv vendor dist build .next coverage)

    if command -v rg >/dev/null 2>&1; then
        # Use ripgrep if available (respects .gitignore, faster)
        local rg_args=(-n --no-heading --color never)
        for d in "${exclude_dirs[@]}"; do
            rg_args+=(--glob "!${d}")
        done
        [[ -n "$include" ]] && rg_args+=(--glob "$include")

        results=$(rg "${rg_args[@]}" "$pattern" "$path" 2>/dev/null) || true
    else
        # Fallback to grep
        local grep_args=(-rn --color=never)
        for d in "${exclude_dirs[@]}"; do
            grep_args+=(--exclude-dir="$d")
        done
        [[ -n "$include" ]] && grep_args+=(--include="$include")

        results=$(grep "${grep_args[@]}" "$pattern" "$path" 2>/dev/null) || true
    fi

    if [[ -z "$results" ]]; then
        echo "No matches found for '${pattern}' in ${path}"
        return 0
    fi

    # Make paths relative to search dir
    results=$(echo "$results" | sed "s|^${path}/||")

    # Truncate long lines
    results=$(echo "$results" | awk -v max="$_SEARCH_CONTENT_MAX_LINE_LENGTH" \
        '{ if (length > max) print substr($0, 1, max) "...[truncated]"; else print }')

    # Count total and cap results
    total_count=$(echo "$results" | wc -l | tr -d ' ')
    local output
    output=$(echo "$results" | head -n "$_SEARCH_CONTENT_MAX_RESULTS")

    if [[ "$total_count" -gt "$_SEARCH_CONTENT_MAX_RESULTS" ]]; then
        printf '%s\n[truncated: showing %d of %d matches]' "$output" "$_SEARCH_CONTENT_MAX_RESULTS" "$total_count"
    else
        echo "$output"
    fi
}
```

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh file_tools`
Expected: All search_content tests PASS

**Step 5: Commit**

```bash
git add lib/tools/search_content.sh tests/test_file_tools.sh
git commit -m "feat: add search_content tool for regex-based content search"
```

---

### Task 3: `read_file` tool

**Files:**
- Create: `lib/tools/read_file.sh`
- Modify: `tests/test_file_tools.sh` (append tests)

**Step 1: Write tests for read_file**

Append to `tests/test_file_tools.sh`:

```bash
# --- read_file tests ---

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
}

test_read_file_basic() {
    local test_file="${TEST_TMP_DIR}/read_basic.txt"
    printf 'line one\nline two\nline three\n' > "$test_file"

    local result
    result=$(tool_read_file_execute "$(printf '{"path":"%s"}' "$test_file")" 2>/dev/null)
    assert_contains "$result" "1: line one" "read_file prefixes line numbers"
    assert_contains "$result" "2: line two" "read_file shows line 2"
    assert_contains "$result" "3: line three" "read_file shows line 3"
    assert_contains "$result" "[lines 1-3 of 3 total]" "read_file shows line range header"
}

test_read_file_with_offset_and_limit() {
    local test_file="${TEST_TMP_DIR}/read_offset.txt"
    for i in $(seq 1 20); do
        echo "line number ${i}" >> "$test_file"
    done

    local result
    result=$(tool_read_file_execute "$(printf '{"path":"%s","offset":5,"limit":3}' "$test_file")" 2>/dev/null)
    assert_contains "$result" "5: line number 5" "read_file respects offset"
    assert_contains "$result" "7: line number 7" "read_file shows up to limit"
    assert_not_contains "$result" "8: line number 8" "read_file stops at limit"
    assert_contains "$result" "[lines 5-7 of 20 total]" "read_file header shows correct range"
}

test_read_file_not_found() {
    local result
    local exit_code=0
    result=$(tool_read_file_execute '{"path":"/nonexistent/file.txt"}' 2>/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "read_file returns error for missing file"
    assert_contains "$result" "Error" "read_file shows error for missing file"
}

test_read_file_binary_detection() {
    local test_file="${TEST_TMP_DIR}/binary_file.bin"
    printf '\x00\x01\x02\x03\x04' > "$test_file"

    local result
    result=$(tool_read_file_execute "$(printf '{"path":"%s"}' "$test_file")" 2>/dev/null)
    assert_contains "$result" "binary" "read_file detects binary files"
}

test_read_file_truncates_long_lines() {
    local test_file="${TEST_TMP_DIR}/long_lines.txt"
    # Create a line longer than 2000 chars
    python3 -c "print('x' * 3000)" > "$test_file"

    local result
    result=$(tool_read_file_execute "$(printf '{"path":"%s"}' "$test_file")" 2>/dev/null)
    assert_contains "$result" "truncated" "read_file truncates lines over 2000 chars"
}

test_read_file_default_limit_caps() {
    local test_file="${TEST_TMP_DIR}/big_file.txt"
    for i in $(seq 1 250); do
        echo "line ${i}" >> "$test_file"
    done

    local result
    result=$(tool_read_file_execute "$(printf '{"path":"%s"}' "$test_file")" 2>/dev/null)
    assert_contains "$result" "[lines 1-200 of 250 total]" "read_file defaults to 200 line limit"
    assert_not_contains "$result" "line 201" "read_file stops at default limit"
}

test_read_file_directory_listing() {
    mkdir -p "${TEST_TMP_DIR}/dir_test/subdir"
    touch "${TEST_TMP_DIR}/dir_test/file1.txt"
    touch "${TEST_TMP_DIR}/dir_test/file2.txt"

    local result
    result=$(tool_read_file_execute "$(printf '{"path":"%s"}' "${TEST_TMP_DIR}/dir_test")" 2>/dev/null)
    assert_contains "$result" "file1.txt" "read_file lists directory contents"
    assert_contains "$result" "subdir/" "read_file marks subdirectories with trailing /"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh file_tools`
Expected: read_file tests FAIL

**Step 3: Write the read_file implementation**

Create `lib/tools/read_file.sh`:

```bash
#!/usr/bin/env bash
# Tool: read_file — read a file with offset/limit and line numbers

# Output control constants
_READ_FILE_MAX_LINES="${SHELLIA_MAX_READ_LINES:-200}"
_READ_FILE_MAX_BYTES="${SHELLIA_MAX_OUTPUT_BYTES:-51200}"
_READ_FILE_MAX_LINE_LENGTH="${SHELLIA_MAX_LINE_LENGTH:-2000}"

tool_read_file_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "read_file",
        "description": "Read a file's contents with line numbers, offset, and limit. Use this instead of 'cat' via run_command — output is capped to prevent context overflow. For directories, returns a listing of entries. Supports reading specific sections of large files via offset/limit.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Absolute or relative path to the file or directory to read"
                },
                "offset": {
                    "type": "integer",
                    "description": "Line number to start reading from (1-indexed, default: 1)"
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of lines to return (default: 200)"
                }
            },
            "required": ["path"]
        }
    }
}
EOF
}

tool_read_file_execute() {
    local args_json="$1"
    local path offset limit
    path=$(echo "$args_json" | jq -r '.path')
    offset=$(echo "$args_json" | jq -r '.offset // 1')
    limit=$(echo "$args_json" | jq -r '.limit // empty')
    limit="${limit:-$_READ_FILE_MAX_LINES}"

    debug_log "tool" "read_file: path=${path} offset=${offset} limit=${limit}"

    # Handle directory listing
    if [[ -d "$path" ]]; then
        local listing
        listing=$(ls -1 "$path" 2>/dev/null | while IFS= read -r entry; do
            if [[ -d "${path}/${entry}" ]]; then
                echo "${entry}/"
            else
                echo "$entry"
            fi
        done)
        if [[ -z "$listing" ]]; then
            echo "(empty directory)"
        else
            echo "$listing"
        fi
        return 0
    fi

    # Validate file exists
    if [[ ! -f "$path" ]]; then
        echo "Error: file not found: ${path}"
        return 1
    fi

    # Binary file detection
    local mime_type
    mime_type=$(file --mime-type -b "$path" 2>/dev/null)
    if [[ "$mime_type" != text/* && "$mime_type" != application/json && "$mime_type" != application/xml && "$mime_type" != application/javascript ]]; then
        local file_size
        file_size=$(wc -c < "$path" | tr -d ' ')
        echo "[binary file: ${mime_type}, ${file_size} bytes]"
        return 0
    fi

    # Count total lines
    local total_lines
    total_lines=$(wc -l < "$path" | tr -d ' ')
    # wc -l doesn't count a final line without a newline, handle that
    [[ "$total_lines" -eq 0 && -s "$path" ]] && total_lines=1

    # Calculate end line
    local end_line=$((offset + limit - 1))
    [[ $end_line -gt $total_lines ]] && end_line=$total_lines

    # Extract the window with line numbers, truncate long lines
    local content
    content=$(awk -v start="$offset" -v end="$end_line" -v maxlen="$_READ_FILE_MAX_LINE_LENGTH" \
        'NR >= start && NR <= end {
            line = $0
            if (length(line) > maxlen) {
                line = substr(line, 1, maxlen) "...[truncated]"
            }
            printf "%d: %s\n", NR, line
        }' "$path")

    # Check byte cap
    local byte_count=${#content}
    if [[ $byte_count -gt $_READ_FILE_MAX_BYTES ]]; then
        content="${content:0:$_READ_FILE_MAX_BYTES}"
        content="${content}
...[output truncated at ${_READ_FILE_MAX_BYTES} bytes]"
    fi

    # Build header
    local header="[lines ${offset}-${end_line} of ${total_lines} total]"

    printf '%s\n%s' "$header" "$content"
}
```

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh file_tools`
Expected: All read_file tests PASS

**Step 5: Commit**

```bash
git add lib/tools/read_file.sh tests/test_file_tools.sh
git commit -m "feat: add read_file tool with offset/limit and binary detection"
```

---

### Task 4: `edit_file` tool

**Files:**
- Create: `lib/tools/edit_file.sh`
- Modify: `tests/test_file_tools.sh` (append tests)

**Step 1: Write tests for edit_file**

Append to `tests/test_file_tools.sh`:

```bash
# --- edit_file tests ---

test_edit_file_schema_valid() {
    local schema
    schema=$(tool_edit_file_schema)
    assert_valid_json "$schema" "edit_file schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "edit_file" "edit_file schema has correct name"

    # Check required params
    local required
    required=$(echo "$schema" | jq -r '.function.parameters.required | sort | join(",")')
    assert_contains "$required" "old_string" "edit_file requires old_string"
    assert_contains "$required" "new_string" "edit_file requires new_string"
    assert_contains "$required" "path" "edit_file requires path"
}

test_edit_file_single_replacement() {
    local test_file="${TEST_TMP_DIR}/edit_single.txt"
    printf 'hello world\ngoodbye world\n' > "$test_file"

    local result
    result=$(tool_edit_file_execute "$(jq -n --arg p "$test_file" --arg o "hello" --arg n "hi" \
        '{path: $p, old_string: $o, new_string: $n}')" 2>/dev/null)
    assert_contains "$result" "OK" "edit_file reports success"

    local content
    content=$(cat "$test_file")
    assert_contains "$content" "hi world" "edit_file replaced old_string"
    assert_contains "$content" "goodbye world" "edit_file didn't touch other lines"
}

test_edit_file_multiline_replacement() {
    local test_file="${TEST_TMP_DIR}/edit_multi.txt"
    printf 'function old() {\n    return 1;\n}\n' > "$test_file"

    local result
    result=$(tool_edit_file_execute "$(jq -n --arg p "$test_file" \
        --arg o "function old() {\n    return 1;\n}" \
        --arg n "function new() {\n    return 2;\n}" \
        '{path: $p, old_string: $o, new_string: $n}')" 2>/dev/null)
    assert_contains "$result" "OK" "edit_file handles multiline replacement"
}

test_edit_file_not_found() {
    local result
    local exit_code=0
    result=$(tool_edit_file_execute "$(jq -n '{path: "/nonexistent.txt", old_string: "x", new_string: "y"}')" 2>/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "edit_file returns error for missing file"
    assert_contains "$result" "Error" "edit_file shows error for missing file"
}

test_edit_file_old_string_not_found() {
    local test_file="${TEST_TMP_DIR}/edit_missing.txt"
    printf 'some content\n' > "$test_file"

    local result
    local exit_code=0
    result=$(tool_edit_file_execute "$(jq -n --arg p "$test_file" \
        '{path: $p, old_string: "nonexistent", new_string: "replacement"}')" 2>/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "edit_file returns error when old_string not found"
    assert_contains "$result" "not found" "edit_file shows not-found error"
}

test_edit_file_multiple_matches_blocked() {
    local test_file="${TEST_TMP_DIR}/edit_multi_match.txt"
    printf 'foo bar\nfoo baz\n' > "$test_file"

    local result
    local exit_code=0
    result=$(tool_edit_file_execute "$(jq -n --arg p "$test_file" \
        '{path: $p, old_string: "foo", new_string: "qux"}')" 2>/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "edit_file returns error for multiple matches"
    assert_contains "$result" "multiple" "edit_file shows multiple-matches error"
}

test_edit_file_replace_all() {
    local test_file="${TEST_TMP_DIR}/edit_all.txt"
    printf 'foo bar\nfoo baz\n' > "$test_file"

    local result
    result=$(tool_edit_file_execute "$(jq -n --arg p "$test_file" \
        '{path: $p, old_string: "foo", new_string: "qux", replace_all: true}')" 2>/dev/null)
    assert_contains "$result" "OK" "edit_file replace_all succeeds"
    assert_contains "$result" "2" "edit_file reports 2 replacements"

    local content
    content=$(cat "$test_file")
    assert_not_contains "$content" "foo" "edit_file replace_all removed all occurrences"
    assert_contains "$content" "qux bar" "edit_file replaced first occurrence"
    assert_contains "$content" "qux baz" "edit_file replaced second occurrence"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh file_tools`
Expected: edit_file tests FAIL

**Step 3: Write the edit_file implementation**

Create `lib/tools/edit_file.sh`:

```bash
#!/usr/bin/env bash
# Tool: edit_file — exact string replacement in files

tool_edit_file_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "edit_file",
        "description": "Replace an exact string in a file. Safer and more precise than sed — no regex escaping needed. By default, fails if the old_string matches more than once (to prevent accidental mass edits). Use replace_all=true to replace all occurrences.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path to the file to edit"
                },
                "old_string": {
                    "type": "string",
                    "description": "The exact text to find and replace"
                },
                "new_string": {
                    "type": "string",
                    "description": "The replacement text"
                },
                "replace_all": {
                    "type": "boolean",
                    "description": "If true, replace all occurrences. If false (default), fail when multiple matches exist."
                }
            },
            "required": ["path", "old_string", "new_string"]
        }
    }
}
EOF
}

tool_edit_file_execute() {
    local args_json="$1"
    local path old_string new_string replace_all
    path=$(echo "$args_json" | jq -r '.path')
    old_string=$(echo "$args_json" | jq -r '.old_string')
    new_string=$(echo "$args_json" | jq -r '.new_string')
    replace_all=$(echo "$args_json" | jq -r '.replace_all // false')

    debug_log "tool" "edit_file: path=${path} replace_all=${replace_all}"

    # Validate file exists
    if [[ ! -f "$path" ]]; then
        echo "Error: file not found: ${path}"
        return 1
    fi

    # Read entire file content
    local content
    content=$(cat "$path")

    # Check old_string equals new_string
    if [[ "$old_string" == "$new_string" ]]; then
        echo "Error: old_string and new_string are identical"
        return 1
    fi

    # Count occurrences using awk (handles multiline via slurp)
    local count
    count=$(awk -v s="$old_string" 'BEGIN{RS="\0"; c=0} {n=split($0,a,s); c=n-1} END{print c}' "$path")

    if [[ "$count" -eq 0 ]]; then
        echo "Error: old_string not found in ${path}"
        return 1
    fi

    if [[ "$count" -gt 1 && "$replace_all" != "true" ]]; then
        echo "Error: found ${count} matches for old_string in ${path}. Use replace_all=true to replace all, or provide more surrounding context to match uniquely."
        return 1
    fi

    # Perform the replacement using awk (exact string, not regex)
    local tmpfile
    tmpfile=$(mktemp)

    if [[ "$replace_all" == "true" ]]; then
        awk -v old="$old_string" -v new="$new_string" \
            'BEGIN{RS="\0"; ORS=""} {gsub(old, new); print}' "$path" > "$tmpfile"
    else
        # Replace only first occurrence
        awk -v old="$old_string" -v new="$new_string" \
            'BEGIN{RS="\0"; ORS=""} {
                idx = index($0, old)
                if (idx > 0) {
                    print substr($0, 1, idx-1) new substr($0, idx+length(old))
                } else {
                    print
                }
            }' "$path" > "$tmpfile"
    fi

    # Atomic replace
    mv "$tmpfile" "$path"

    local replaced_count
    if [[ "$replace_all" == "true" ]]; then
        replaced_count=$count
    else
        replaced_count=1
    fi

    echo "OK: replaced ${replaced_count} occurrence(s) in ${path}"
}
```

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh file_tools`
Expected: All edit_file tests PASS

**Step 5: Commit**

```bash
git add lib/tools/edit_file.sh tests/test_file_tools.sh
git commit -m "feat: add edit_file tool for exact string replacement"
```

---

### Task 5: `write_file` tool

**Files:**
- Create: `lib/tools/write_file.sh`
- Modify: `tests/test_file_tools.sh` (append tests)

**Step 1: Write tests for write_file**

Append to `tests/test_file_tools.sh`:

```bash
# --- write_file tests ---

test_write_file_schema_valid() {
    local schema
    schema=$(tool_write_file_schema)
    assert_valid_json "$schema" "write_file schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "write_file" "write_file schema has correct name"
}

test_write_file_creates_new_file() {
    local test_file="${TEST_TMP_DIR}/write_new.txt"

    local result
    result=$(tool_write_file_execute "$(jq -n --arg p "$test_file" --arg c "hello world" \
        '{path: $p, content: $c}')" 2>/dev/null)
    assert_contains "$result" "OK" "write_file reports success"
    assert_file_exists "$test_file" "write_file created the file"

    local content
    content=$(cat "$test_file")
    assert_eq "$content" "hello world" "write_file wrote correct content"
}

test_write_file_creates_parent_dirs() {
    local test_file="${TEST_TMP_DIR}/deep/nested/dir/file.txt"

    local result
    result=$(tool_write_file_execute "$(jq -n --arg p "$test_file" --arg c "nested content" \
        '{path: $p, content: $c}')" 2>/dev/null)
    assert_contains "$result" "OK" "write_file succeeds with nested dirs"
    assert_file_exists "$test_file" "write_file created file in nested dirs"
}

test_write_file_overwrites_existing() {
    local test_file="${TEST_TMP_DIR}/write_overwrite.txt"
    echo "old content" > "$test_file"

    local result
    result=$(tool_write_file_execute "$(jq -n --arg p "$test_file" --arg c "new content" \
        '{path: $p, content: $c}')" 2>/dev/null)
    assert_contains "$result" "OK" "write_file succeeds overwriting"
    assert_contains "$result" "overwriting" "write_file notes overwrite"

    local content
    content=$(cat "$test_file")
    assert_eq "$content" "new content" "write_file overwrote with new content"
}

test_write_file_reports_byte_count() {
    local test_file="${TEST_TMP_DIR}/write_bytes.txt"

    local result
    result=$(tool_write_file_execute "$(jq -n --arg p "$test_file" --arg c "12345" \
        '{path: $p, content: $c}')" 2>/dev/null)
    assert_contains "$result" "5 bytes" "write_file reports correct byte count"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh file_tools`
Expected: write_file tests FAIL

**Step 3: Write the write_file implementation**

Create `lib/tools/write_file.sh`:

```bash
#!/usr/bin/env bash
# Tool: write_file — create or overwrite a file

tool_write_file_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "write_file",
        "description": "Write content to a file, creating it if it doesn't exist or overwriting if it does. Creates parent directories automatically. Use this instead of heredocs via run_command for cleaner file creation.",
        "parameters": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Path to the file to write"
                },
                "content": {
                    "type": "string",
                    "description": "The content to write to the file"
                }
            },
            "required": ["path", "content"]
        }
    }
}
EOF
}

tool_write_file_execute() {
    local args_json="$1"
    local path content
    path=$(echo "$args_json" | jq -r '.path')
    content=$(echo "$args_json" | jq -r '.content')

    debug_log "tool" "write_file: path=${path}"

    local overwrite_note=""
    if [[ -f "$path" ]]; then
        overwrite_note=" [overwriting existing file]"
    fi

    # Create parent directories if needed
    local parent_dir
    parent_dir=$(dirname "$path")
    if [[ ! -d "$parent_dir" ]]; then
        mkdir -p "$parent_dir" || {
            echo "Error: could not create directory: ${parent_dir}"
            return 1
        }
    fi

    # Write content
    printf '%s' "$content" > "$path" || {
        echo "Error: could not write to: ${path}"
        return 1
    }

    # Report byte count
    local byte_count
    byte_count=$(wc -c < "$path" | tr -d ' ')

    echo "OK: wrote ${byte_count} bytes to ${path}${overwrite_note}"
}
```

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh file_tools`
Expected: All write_file tests PASS

**Step 5: Commit**

```bash
git add lib/tools/write_file.sh tests/test_file_tools.sh
git commit -m "feat: add write_file tool for file creation and overwriting"
```

---

### Task 6: Update system prompt

**Files:**
- Modify: `defaults/system_prompt.txt` (add file tool instructions after existing tool list)

**Step 1: Update the system prompt**

In `defaults/system_prompt.txt`, after the existing tool list (line 9: `- When a question only needs...`), add file tool instructions. The updated tool list section should read:

```
You have access to tools that let you interact with the user's system. Use them when appropriate:
- Use the run_command tool to execute shell commands
- Use the run_plan tool when a task requires multiple coordinated steps that should be reviewed together
- Use the ask_user tool when you need clarification or a decision before proceeding
- Use search_files to find files by name/glob pattern (instead of find via run_command)
- Use search_content to search file contents by regex (instead of grep via run_command)
- Use read_file to read files with controlled output (instead of cat via run_command)
- Use edit_file for precise text replacements in files (instead of sed via run_command)
- Use write_file to create or overwrite files (instead of heredocs via run_command)
- Prefer the dedicated file tools over run_command for file operations — they have built-in output limits that prevent context overflow
- When a question only needs an explanation or analysis, respond with plain text (no tool needed)
```

**Step 2: Verify prompt still loads correctly**

Run: `bash tests/run_tests.sh prompt`
Expected: All prompt tests PASS

**Step 3: Commit**

```bash
git add defaults/system_prompt.txt
git commit -m "docs: update system prompt with file tool instructions"
```

---

### Task 7: Update safety plugin

**Files:**
- Modify: `lib/plugins/safety/plugin.sh:17-39` (extend `plugin_safety_on_before_tool_call`)

**Step 1: Write a test for safety plugin + file tools**

Append to `tests/test_file_tools.sh`:

```bash
# --- safety integration tests ---

test_edit_file_safety_hook_fires() {
    # Verify the safety plugin's before_tool_call handles edit_file
    # by checking the case statement routes it
    source "${PROJECT_DIR}/lib/plugins/safety/plugin.sh"
    load_dangerous_commands

    # The hook should not block non-dangerous edit_file calls (no patterns match paths)
    SHELLIA_TOOL_BLOCKED=false
    plugin_safety_on_before_tool_call "edit_file" "$(jq -n '{path: "/tmp/safe.txt", old_string: "a", new_string: "b"}')" 2>/dev/null </dev/null
    assert_eq "$SHELLIA_TOOL_BLOCKED" "false" "safety plugin does not block safe edit_file paths"
}
```

**Step 2: Update safety plugin to handle file tools**

In `lib/plugins/safety/plugin.sh`, extend the case statement in `plugin_safety_on_before_tool_call` to add cases for `edit_file` and `write_file`:

```bash
plugin_safety_on_before_tool_call() {
    local tool_name="$1"
    local tool_args="$2"

    case "$tool_name" in
        run_command)
            local cmd
            cmd=$(echo "$tool_args" | jq -r '.command' 2>/dev/null)
            [[ -z "$cmd" ]] && return 0
            _safety_check_command "$cmd"
            ;;
        run_plan)
            local steps
            steps=$(echo "$tool_args" | jq -r '.steps[].command' 2>/dev/null)
            while IFS= read -r cmd; do
                [[ -z "$cmd" ]] && continue
                _safety_check_command "$cmd"
                [[ "${SHELLIA_TOOL_BLOCKED:-false}" == "true" ]] && return 0
            done <<< "$steps"
            ;;
        edit_file|write_file)
            local file_path
            file_path=$(echo "$tool_args" | jq -r '.path' 2>/dev/null)
            [[ -z "$file_path" ]] && return 0
            # Check if the file path matches a dangerous pattern (e.g. system files)
            _safety_check_command "write ${file_path}"
            ;;
    esac
}
```

**Step 3: Run tests**

Run: `bash tests/run_tests.sh file_tools && bash tests/run_tests.sh plugins`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add lib/plugins/safety/plugin.sh tests/test_file_tools.sh
git commit -m "feat: extend safety plugin to check edit_file and write_file paths"
```

---

### Task 8: Update existing tool tests for new tool count

**Files:**
- Modify: `tests/test_tools.sh:31-33` (update minimum tool count assertion)

**Step 1: Update tool count assertion**

In `tests/test_tools.sh`, the test `test_build_tools_array_contains_all_tools` asserts `count >= 3`. With 5 new tools (total 9 built-in), update to `count >= 8`:

```bash
    [[ "$count" -ge 8 ]] && has_enough=true
    assert_eq "$has_enough" "true" "build_tools_array returns at least 8 tools (got ${count})"
```

Also add assertions for the new tool names:

```bash
    assert_contains "$names" "search_files" "tools array contains search_files"
    assert_contains "$names" "search_content" "tools array contains search_content"
    assert_contains "$names" "read_file" "tools array contains read_file"
    assert_contains "$names" "edit_file" "tools array contains edit_file"
    assert_contains "$names" "write_file" "tools array contains write_file"
```

**Step 2: Run full test suite**

Run: `bash tests/run_tests.sh`
Expected: All tests PASS

**Step 3: Commit**

```bash
git add tests/test_tools.sh
git commit -m "test: update tool registry tests for new file operation tools"
```

---

### Task 9: Final verification

**Step 1: Run the full test suite**

Run: `bash tests/run_tests.sh`
Expected: All tests PASS, 0 failures

**Step 2: Verify tool schemas load correctly**

Run: `bash -c 'source shellia; load_tools; build_tools_array | jq ".[].function.name"'` (or equivalent from project root)
Expected: All 9 tool names listed including the 5 new ones

**Step 3: Verify bundle includes new tools**

Run: `bash bundle.sh /tmp/shellia_test_bundle && grep -c "tool_.*_schema" /tmp/shellia_test_bundle`
Expected: Count includes all new tool schema functions
