# RALP Plugin Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a `ralp` REPL command that runs an LLM-driven PRD interview, writes the PRD to a file, then launches an iterative `claude` CLI loop with that PRD as the prompt.

**Architecture:** Directory plugin at `lib/plugins/ralp/` with `plugin.sh` and `interview_prompt.txt`. Uses an embedded sub-loop (its own `while read` + conversation file) that calls shellia's existing `api_chat_loop`. Detects `[INTERVIEW_COMPLETE]` sentinel in LLM output to transition from interview to claude launch.

**Tech Stack:** Bash 3.2+, `jq`, shellia plugin API (`api_chat_loop`, `build_conversation_messages`, `plugin_config_get`, `spinner_start/stop`, `format_markdown`), `claude` CLI, `cclean`

---

## Reference files to read before starting

- `lib/plugins/skills/plugin.sh` — best reference for a complex directory plugin
- `lib/plugins/serve/plugin.sh` — reference for a plugin with a self-contained sub-routine
- `lib/api.sh` — `api_chat_loop`, `build_conversation_messages`, `build_single_messages`
- `lib/utils.sh` — `log_info`, `log_warn`, `log_error`, `spinner_start`, `spinner_stop`
- `lib/plugins.sh` — `plugin_config_get`
- `tests/test_skills.sh` — reference for test file structure
- `tests/test_helpers.sh` — assertion helpers (`assert_eq`, `assert_contains`, `assert_file_exists`, etc.)
- `tests/run_tests.sh` — how tests are discovered and run

---

## Task 1: Create plugin skeleton

**Files:**
- Create: `lib/plugins/ralp/plugin.sh`
- Create: `lib/plugins/ralp/interview_prompt.txt`

**Step 1: Create `lib/plugins/ralp/interview_prompt.txt`**

Write the file with this exact content:

```
You are a senior product manager and engineer conducting a PRD (Product Requirements Document) interview.

Your goal is to gather enough information to write a complete, actionable PRD that can be used as a prompt for an AI coding agent (Claude Code).

Rules:
- Ask ONE question at a time. Never ask multiple questions in one message.
- Start with the most important missing information (usually: what is the feature or task?).
- Adapt your questions based on the user's answers — don't follow a rigid script.
- Cover these areas before completing (not necessarily in this order):
  * Feature/task description and goal
  * Target users or audience
  * Key requirements and behaviors
  * Acceptance criteria (how do we know it's done?)
  * Out-of-scope items
  * Technical constraints or stack (if relevant)
- You may ask 4-10 questions depending on complexity. Simple tasks need fewer questions.
- When you have enough information to write a complete, actionable PRD, output EXACTLY this on its own line:
  [INTERVIEW_COMPLETE]
  Then immediately write the full PRD in markdown with these sections:
  # PRD: <Feature Name>
  ## Overview
  ## Goals
  ## Users
  ## Requirements
  ## Acceptance Criteria
  ## Out of Scope
- Do NOT output [INTERVIEW_COMPLETE] until you have at minimum: feature description, primary goal, and at least one acceptance criterion.
- Do NOT add any text after the PRD markdown.
```

**Step 2: Create `lib/plugins/ralp/plugin.sh` with the skeleton**

```bash
#!/usr/bin/env bash
# Plugin: ralp — LLM-driven PRD interview + Claude iteration loop

plugin_ralp_info() {
    echo "LLM-driven PRD interview that feeds into a Claude iteration loop"
}

plugin_ralp_hooks() {
    echo ""
}
```

**Step 3: Verify the plugin directory exists**

Run: `ls lib/plugins/ralp/`
Expected output:
```
interview_prompt.txt
plugin.sh
```

**Step 4: Commit**

```bash
git add lib/plugins/ralp/
git commit -m "feat(ralp): add plugin skeleton and interview prompt"
```

---

## Task 2: Implement argument parsing helper

**Files:**
- Modify: `lib/plugins/ralp/plugin.sh`

The `ralp` command accepts: `ralp [topic] [--max-iterations=N]`

**Step 1: Write the failing test**

Create `tests/test_ralp.sh`:

```bash
#!/usr/bin/env bash
# Tests for the ralp plugin

source "${PROJECT_DIR}/lib/plugins/ralp/plugin.sh"

test_ralp_parse_args_defaults() {
    local topic max_iter
    _ralp_parse_args topic max_iter
    assert_eq "$topic" "" "topic empty by default"
    assert_eq "$max_iter" "5" "max_iter defaults to 5"
}

test_ralp_parse_args_topic_only() {
    local topic max_iter
    _ralp_parse_args topic max_iter "add dark mode"
    assert_eq "$topic" "add dark mode" "topic captured"
    assert_eq "$max_iter" "5" "max_iter still defaults to 5"
}

test_ralp_parse_args_max_iter_flag() {
    local topic max_iter
    _ralp_parse_args topic max_iter "--max-iterations=3"
    assert_eq "$topic" "" "topic empty"
    assert_eq "$max_iter" "3" "max_iter from flag"
}

test_ralp_parse_args_topic_and_flag() {
    local topic max_iter
    _ralp_parse_args topic max_iter "add search" "--max-iterations=10"
    assert_eq "$topic" "add search" "topic captured"
    assert_eq "$max_iter" "10" "max_iter from flag"
}

test_ralp_parse_args_max_iter_space_syntax() {
    local topic max_iter
    _ralp_parse_args topic max_iter "--max-iterations" "7"
    assert_eq "$max_iter" "7" "max_iter from space-separated flag"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh tests/test_ralp.sh`
Expected: FAIL — `_ralp_parse_args: command not found`

**Step 3: Implement `_ralp_parse_args` in `plugin.sh`**

Add after the hooks function:

```bash
# Parse ralp command arguments
# Usage: _ralp_parse_args <topic_var> <max_iter_var> [args...]
# Sets topic_var to the topic string (may be empty)
# Sets max_iter_var to the resolved max iterations
_ralp_parse_args() {
    local __topic_var="$1"
    local __max_iter_var="$2"
    shift 2

    local __topic=""
    local __max_iter
    __max_iter=$(plugin_config_get "ralp" "max_iterations" "5")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max-iterations=*)
                __max_iter="${1#*=}"
                shift
                ;;
            --max-iterations)
                __max_iter="${2:-5}"
                shift 2
                ;;
            *)
                if [[ -z "$__topic" ]]; then
                    __topic="$1"
                fi
                shift
                ;;
        esac
    done

    printf -v "$__topic_var" '%s' "$__topic"
    printf -v "$__max_iter_var" '%s' "$__max_iter"
}
```

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh tests/test_ralp.sh`
Expected: all 5 tests PASS

**Step 5: Commit**

```bash
git add lib/plugins/ralp/plugin.sh tests/test_ralp.sh
git commit -m "feat(ralp): add argument parsing with tests"
```

---

## Task 3: Implement sentinel detection helper

**Files:**
- Modify: `lib/plugins/ralp/plugin.sh`
- Modify: `tests/test_ralp.sh`

The sentinel is `[INTERVIEW_COMPLETE]` on its own line. After detection, everything following it is the PRD content.

**Step 1: Add failing tests to `tests/test_ralp.sh`**

```bash
test_ralp_sentinel_not_present() {
    local prd
    local found
    found=$(_ralp_check_sentinel "Just a normal question." prd)
    assert_eq "$found" "0" "no sentinel returns 0"
    assert_eq "$prd" "" "prd empty when no sentinel"
}

test_ralp_sentinel_present() {
    local prd
    local response="[INTERVIEW_COMPLETE]
# PRD: Dark Mode
## Overview
Add dark mode."
    local found
    found=$(_ralp_check_sentinel "$response" prd)
    assert_eq "$found" "1" "sentinel found returns 1"
    assert_contains "$prd" "# PRD: Dark Mode" "prd content extracted"
    assert_not_contains "$prd" "[INTERVIEW_COMPLETE]" "sentinel stripped from prd"
}

test_ralp_sentinel_mid_response() {
    local prd
    local response="Great, I have enough info.
[INTERVIEW_COMPLETE]
# PRD: Search
## Overview
Add search."
    local found
    found=$(_ralp_check_sentinel "$response" prd)
    assert_eq "$found" "1" "sentinel found mid-response"
    assert_contains "$prd" "# PRD: Search" "prd content correct"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh tests/test_ralp.sh`
Expected: FAIL on the 3 new tests

**Step 3: Implement `_ralp_check_sentinel`**

Add to `plugin.sh`:

```bash
# Check if a response contains the interview complete sentinel.
# Outputs: prints "1" if found, "0" if not
# Sets the variable named by $2 to the PRD content (everything after sentinel line)
# Usage: found=$(_ralp_check_sentinel "$response" prd_var)
_ralp_check_sentinel() {
    local response="$1"
    local __prd_var="$2"

    if [[ "$response" != *"[INTERVIEW_COMPLETE]"* ]]; then
        printf -v "$__prd_var" '%s' ""
        echo "0"
        return 0
    fi

    # Extract everything after the [INTERVIEW_COMPLETE] line
    local prd_content
    prd_content=$(echo "$response" | awk '/\[INTERVIEW_COMPLETE\]/{found=1; next} found{print}')

    printf -v "$__prd_var" '%s' "$prd_content"
    echo "1"
}
```

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh tests/test_ralp.sh`
Expected: all tests PASS

**Step 5: Commit**

```bash
git add lib/plugins/ralp/plugin.sh tests/test_ralp.sh
git commit -m "feat(ralp): add sentinel detection with tests"
```

---

## Task 4: Implement PRD file writing helper

**Files:**
- Modify: `lib/plugins/ralp/plugin.sh`
- Modify: `tests/test_ralp.sh`

**Step 1: Add failing tests**

```bash
test_ralp_prd_slug_simple() {
    local slug
    slug=$(_ralp_prd_slug "# PRD: Dark Mode Toggle")
    assert_eq "$slug" "dark-mode-toggle" "slug from PRD title"
}

test_ralp_prd_slug_special_chars() {
    local slug
    slug=$(_ralp_prd_slug "# PRD: Add Search (v2)")
    assert_contains "$slug" "add-search" "special chars stripped from slug"
}

test_ralp_prd_slug_fallback() {
    local slug
    slug=$(_ralp_prd_slug "No title here")
    assert_not_empty "$slug" "fallback slug not empty"
}

test_ralp_write_prd_file() {
    local prd_content="# PRD: Test Feature
## Overview
This is a test."
    local outdir="${TEST_TMP}/prd_test"
    mkdir -p "$outdir"
    local outfile
    outfile=$(_ralp_write_prd "$prd_content" "$outdir")
    assert_file_exists "$outfile" "PRD file created"
    local content
    content=$(cat "$outfile")
    assert_contains "$content" "# PRD: Test Feature" "PRD content written"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh tests/test_ralp.sh`
Expected: FAIL on the 4 new tests

**Step 3: Implement `_ralp_prd_slug` and `_ralp_write_prd`**

```bash
# Generate a URL-friendly slug from PRD content
# Looks for the first "# PRD: <title>" line; falls back to timestamp
_ralp_prd_slug() {
    local prd_content="$1"
    local title

    # Try to extract title from "# PRD: <title>" line
    title=$(echo "$prd_content" | grep -m1 '^# PRD:' | sed 's/^# PRD:[[:space:]]*//')

    if [[ -z "$title" ]]; then
        # Fallback: use timestamp
        echo "prd-$(date +%Y%m%d-%H%M%S)"
        return 0
    fi

    # Slugify: lowercase, replace non-alphanumeric runs with hyphens, trim hyphens
    echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//;s/-$//'
}

# Write the PRD content to a file in the given directory
# Prints the full path of the written file on stdout
_ralp_write_prd() {
    local prd_content="$1"
    local outdir="${2:-.}"

    local slug
    slug=$(_ralp_prd_slug "$prd_content")

    local outfile="${outdir}/prd-${slug}.md"
    echo "$prd_content" > "$outfile"
    echo "$outfile"
}
```

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh tests/test_ralp.sh`
Expected: all tests PASS

**Step 5: Commit**

```bash
git add lib/plugins/ralp/plugin.sh tests/test_ralp.sh
git commit -m "feat(ralp): add PRD file writing helpers with tests"
```

---

## Task 5: Implement the claude loop launcher

**Files:**
- Modify: `lib/plugins/ralp/plugin.sh`

This function is a side-effecting shell-out — no unit test possible. Implement and manually verify.

**Step 1: Add `_ralp_ensure_cclean` and `_ralp_run_claude_loop`**

```bash
# Ensure cclean is installed; install it if not found
_ralp_ensure_cclean() {
    if ! command -v cclean &>/dev/null; then
        log_info "Installing cclean for pretty output..."
        curl -fsSL https://raw.githubusercontent.com/ariel-frischer/claude-clean/main/install.sh | sh
    fi
}

# Run the claude iteration loop with the given PRD content
# Args: $1 = prd_content, $2 = max_iterations
_ralp_run_claude_loop() {
    local prd_content="$1"
    local max_iterations="$2"

    # Ensure claude is available
    if ! command -v claude &>/dev/null; then
        log_error "'claude' CLI not found. Install it from: https://claude.ai/code"
        return 1
    fi

    _ralp_ensure_cclean

    echo -e "${THEME_HEADER}Starting Claude loop: ${max_iterations} iteration(s)${NC}"
    echo -e "${THEME_SEPARATOR}$(printf '%.0s─' {1..50})${NC}"

    local i
    for ((i=1; i<=max_iterations; i++)); do
        echo ""
        echo -e "${THEME_ACCENT}=== Iteration ${i} of ${max_iterations} ===${NC}"
        echo ""

        claude -p "$prd_content" \
            --dangerously-skip-permissions \
            --output-format stream-json | cclean

        if [[ $i -lt $max_iterations ]]; then
            echo ""
            echo -e "${THEME_MUTED}--- Completed iteration ${i}, continuing... ---${NC}"
        fi
    done

    echo ""
    echo -e "${THEME_SEPARATOR}$(printf '%.0s─' {1..50})${NC}"
    echo -e "${THEME_SUCCESS}Ralph loop completed after ${max_iterations} iteration(s).${NC}"
}
```

**Step 2: Commit**

```bash
git add lib/plugins/ralp/plugin.sh
git commit -m "feat(ralp): add claude loop launcher"
```

---

## Task 6: Implement the PRD interview sub-loop

**Files:**
- Modify: `lib/plugins/ralp/plugin.sh`

This is the core sub-loop. It manages its own conversation, calls the API, and watches for the sentinel.

**Step 1: Add `_ralp_interview_loop`**

```bash
# Run the PRD interview sub-loop.
# Args: $1 = initial topic (may be empty), $2 = max_iterations
# On success: writes the PRD file and returns the path via stdout
# On abort: returns 1
_ralp_interview_loop() {
    local topic="$1"
    local max_iterations="$2"
    local prd_dir
    prd_dir=$(plugin_config_get "ralp" "prd_dir" ".")

    # Load the interview system prompt
    local plugin_dir
    plugin_dir="$(dirname "${BASH_SOURCE[0]}")"
    local interview_prompt_file="${plugin_dir}/interview_prompt.txt"

    if [[ ! -f "$interview_prompt_file" ]]; then
        log_error "Interview prompt not found: ${interview_prompt_file}"
        return 1
    fi

    local system_prompt
    system_prompt=$(cat "$interview_prompt_file")

    # Append current directory context
    system_prompt="${system_prompt}

CONTEXT:
- Current directory: $(pwd)
- Files in current directory: $(ls -1 2>/dev/null | head -20 | tr '\n' ', ' | sed 's/,$//')"

    # Temp conversation file for the interview
    local conv_file
    conv_file=$(mktemp /tmp/shellia_ralp_XXXXXX.json)
    echo '[]' > "$conv_file"
    trap "rm -f '$conv_file'" RETURN

    local prompt_str
    prompt_str="$(echo -e "${THEME_ACCENT}ralp>${NC}") "

    echo -e "${THEME_HEADER}RALP — PRD Interview${NC}"
    echo -e "${THEME_SEPARATOR}$(printf '%.0s─' {1..50})${NC}"
    echo -e "${THEME_MUTED}I'll ask you a few questions to build a PRD, then launch Claude.${NC}"
    echo -e "${THEME_MUTED}Type 'abort' at any time to cancel.${NC}"
    echo ""

    # If a topic was provided, use it as the opening user message
    local first_message="$topic"
    if [[ -z "$first_message" ]]; then
        # Ask the LLM to open the interview
        first_message="Let's start. Please ask me the first question."
    fi

    local user_message="$first_message"

    while true; do
        # Build messages with history
        local messages
        messages=$(build_conversation_messages "$system_prompt" "$conv_file" "$user_message")

        # Call API
        spinner_start "Thinking..."
        local response
        local api_exit=0
        response=$(api_chat_loop "$messages" "[]") || api_exit=$?
        spinner_stop

        if [[ $api_exit -ne 0 ]]; then
            log_error "API call failed. Type 'abort' to exit or try again."
        else
            # Check for sentinel
            local prd_content=""
            local sentinel_found
            sentinel_found=$(_ralp_check_sentinel "$response" prd_content)

            if [[ "$sentinel_found" == "1" ]]; then
                # Strip sentinel from displayed response (show only text before it, if any)
                local before_sentinel
                before_sentinel=$(echo "$response" | awk '/\[INTERVIEW_COMPLETE\]/{exit} {print}')
                if [[ -n "$before_sentinel" ]]; then
                    echo ""
                    echo "$before_sentinel" | format_markdown
                fi

                echo ""
                echo -e "${THEME_SUCCESS}Interview complete. Writing PRD...${NC}"

                # Write PRD file
                local outfile
                outfile=$(_ralp_write_prd "$prd_content" "$prd_dir")
                echo -e "${THEME_SUCCESS}PRD saved: ${outfile}${NC}"
                echo ""

                # Update conv file for completeness
                local updated
                updated=$(jq \
                    --arg usr "$user_message" \
                    --arg asst "$response" \
                    '. + [{"role": "user", "content": $usr}, {"role": "assistant", "content": $asst}]' \
                    "$conv_file")
                echo "$updated" > "$conv_file"

                # Return the PRD content and file path via stdout
                # Format: first line = file path, rest = PRD content
                echo "$outfile"
                echo "$prd_content"
                return 0
            fi

            # No sentinel — display response and continue
            echo ""
            echo "$response" | format_markdown
            echo ""

            # Update conversation history
            local updated
            updated=$(jq \
                --arg usr "$user_message" \
                --arg asst "$response" \
                '. + [{"role": "user", "content": $usr}, {"role": "assistant", "content": $asst}]' \
                "$conv_file")
            echo "$updated" > "$conv_file"
        fi

        # Read next user input
        local line
        if ! read -rep "$prompt_str" line; then
            # Ctrl+D
            echo ""
            log_info "Interview aborted."
            return 1
        fi

        [[ -z "$line" ]] && continue

        if [[ "$line" == "abort" || "$line" == "quit" || "$line" == "exit" ]]; then
            log_info "Interview aborted."
            return 1
        fi

        user_message="$line"
    done
}
```

**Step 2: Commit**

```bash
git add lib/plugins/ralp/plugin.sh
git commit -m "feat(ralp): add PRD interview sub-loop"
```

---

## Task 7: Implement the REPL command entry point

**Files:**
- Modify: `lib/plugins/ralp/plugin.sh`

**Step 1: Add `repl_cmd_ralp_handler` and `repl_cmd_ralp_help`**

```bash
# REPL command: ralp [topic] [--max-iterations=N]
repl_cmd_ralp_handler() {
    local args="${1:-}"

    # Split args string into positional array for parsing
    # (REPL dispatch passes all args as a single string in $1)
    local topic max_iterations

    # shellcheck disable=SC2086
    _ralp_parse_args topic max_iterations $args

    # Run the interview loop; capture output
    # The first line of output is the PRD file path; the rest is PRD content
    local interview_output
    local interview_exit=0
    interview_output=$(_ralp_interview_loop "$topic" "$max_iterations") || interview_exit=$?

    if [[ $interview_exit -ne 0 ]]; then
        return 0  # Aborted cleanly
    fi

    # First line = file path, rest = PRD content
    local prd_file
    prd_file=$(echo "$interview_output" | head -n1)
    local prd_content
    prd_content=$(echo "$interview_output" | tail -n +2)

    # Confirm before launching claude loop
    local confirm
    read -rp "$(echo -e "${THEME_ACCENT}Launch Claude loop (${max_iterations} iterations)? [Y/n]:${NC} ")" confirm
    confirm="${confirm:-Y}"

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        _ralp_run_claude_loop "$prd_content" "$max_iterations"
    else
        log_info "Claude loop skipped. PRD is at: ${prd_file}"
    fi
}

repl_cmd_ralp_help() {
    echo -e "  ${THEME_ACCENT}ralp [topic] [--max-iterations=N]${NC}  PRD interview + Claude loop"
}
```

**Step 2: Write a smoke test for the REPL command registration**

Add to `tests/test_ralp.sh`:

```bash
test_ralp_plugin_info() {
    local info
    info=$(plugin_ralp_info)
    assert_not_empty "$info" "plugin_ralp_info returns non-empty string"
}

test_ralp_plugin_hooks_empty() {
    local hooks
    hooks=$(plugin_ralp_hooks)
    assert_eq "$hooks" "" "ralp plugin subscribes to no hooks"
}

test_ralp_repl_help_registered() {
    # repl_cmd_ralp_help should be callable and return non-empty
    local help_text
    help_text=$(repl_cmd_ralp_help 2>/dev/null || true)
    assert_not_empty "$help_text" "repl_cmd_ralp_help returns text"
}
```

**Step 3: Run tests**

Run: `bash tests/run_tests.sh tests/test_ralp.sh`
Expected: all tests PASS

**Step 4: Commit**

```bash
git add lib/plugins/ralp/plugin.sh tests/test_ralp.sh
git commit -m "feat(ralp): add REPL command entry point with smoke tests"
```

---

## Task 8: Run the full test suite

**Step 1: Run all tests**

Run: `bash tests/run_tests.sh`
Expected: all existing tests pass, no regressions

**Step 2: Fix any regressions before proceeding**

If any test fails, fix it before moving on.

**Step 3: Commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: resolve test regressions from ralp plugin"
```

---

## Task 9: Update README

**Files:**
- Modify: `README.md`

**Step 1: Add `ralp` to the Plugin-provided REPL commands table**

Find the table under `### REPL mode` that has columns `Command | Plugin | Effect` and add:

```
| `ralp [topic] [--max-iterations=N]` | ralp | PRD interview + Claude iteration loop |
```

**Step 2: Add `ralp` to the Built-in plugins table**

Find the table under `### Built-in plugins` with columns `Plugin | Description | Hooks` and add:

```
| `ralp` | LLM-driven PRD interview that feeds into a Claude iteration loop | (none) |
```

**Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document ralp plugin in README"
```

---

## Task 10: Manual end-to-end smoke test

This cannot be automated. Perform manually:

1. Start shellia REPL: `./shellia`
2. Run: `plugins` — verify `ralp` appears in the list
3. Run: `help` — verify `ralp` appears in plugin commands
4. Run: `ralp add a dark mode toggle --max-iterations=1`
5. Answer 3-5 interview questions
6. Verify `prd-*.md` is written to current directory
7. If `claude` CLI is available, confirm the loop launches
8. If `claude` CLI is not available, verify the error message is clear
9. Run: `ralp` with no args — verify the interview starts with the LLM asking the first question
10. Type `abort` mid-interview — verify clean exit with no leftover temp files

---

## Definition of Done

- [ ] All unit tests in `tests/test_ralp.sh` pass
- [ ] Full test suite (`tests/run_tests.sh`) passes with no regressions  
- [ ] `ralp` appears in `help` and `plugins` output
- [ ] Interview produces a `.md` PRD file in the current directory
- [ ] Claude loop launches with correct arguments
- [ ] `abort` exits cleanly
- [ ] README updated
