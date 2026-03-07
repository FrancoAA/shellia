# Tool System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the text-tag response protocol with OpenAI-compatible tool/function calling, and add an extensible tool system with auto-discovery.

**Architecture:** Each tool is a self-contained bash file in `lib/tools/` exporting a schema function and an execute function. A loader (`lib/tools.sh`) auto-discovers tools, builds the JSON tools array for API requests, and dispatches tool calls. The API layer runs a tool-call loop: send request → if tool_calls, execute and loop back → if text only, return to user. Explanations are just text content (no tool needed).

**Tech Stack:** Pure bash, jq, curl, OpenAI-compatible tools API

---

### Task 1: Create tool registry and loader (`lib/tools.sh`)

**Files:**
- Create: `lib/tools.sh`

**Step 1: Create lib/tools.sh with loader, schema builder, and dispatcher**

```bash
#!/usr/bin/env bash
# Tool registry: auto-discovers tools from lib/tools/, builds schemas, dispatches calls

# Source all tool files from lib/tools/
load_tools() {
    local tools_dir="${SHELLIA_DIR}/lib/tools"
    if [[ -d "$tools_dir" ]]; then
        for tool_file in "${tools_dir}"/*.sh; do
            [[ -f "$tool_file" ]] || continue
            source "$tool_file"
            debug_log "tools" "loaded $(basename "$tool_file")"
        done
    fi
}

# Build JSON array of all tool schemas for the API request
build_tools_array() {
    local schemas=()
    local funcs
    funcs=$(declare -F | awk '{print $3}' | grep '^tool_.*_schema$' | sort)

    if [[ -z "$funcs" ]]; then
        echo '[]'
        return
    fi

    local first=true
    local result="["
    for func in $funcs; do
        local schema
        schema=$("$func")
        if [[ "$first" == "true" ]]; then
            first=false
        else
            result="${result},"
        fi
        result="${result}${schema}"
    done
    result="${result}]"

    echo "$result"
}

# Dispatch a tool call to the correct execute function
# Args: $1 = tool name, $2 = arguments JSON string
# Returns: tool result string on stdout
dispatch_tool_call() {
    local tool_name="$1"
    local tool_args="$2"
    local func_name="tool_${tool_name}_execute"

    if declare -F "$func_name" >/dev/null 2>&1; then
        "$func_name" "$tool_args"
    else
        echo "Error: unknown tool '${tool_name}'"
        return 1
    fi
}
```

**Step 2: Run tests to verify it passes**

Run: `bash tests/run_tests.sh tools`

**Step 3: Commit**

```bash
git add lib/tools.sh
git commit -m "feat: add tool registry with auto-discovery loader"
```

---

### Task 2: Create the `run_command` tool

**Files:**
- Create: `lib/tools/run_command.sh`

**Step 1: Create run_command tool**

```bash
#!/usr/bin/env bash
# Tool: run_command — execute a shell command

tool_run_command_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "run_command",
        "description": "Execute a shell command in the user's terminal. Use this for any single command, pipeline, loop, heredoc, or script. The command runs in the user's current shell and working directory. Output (stdout and stderr) is captured and returned.",
        "parameters": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The shell command to execute"
                }
            },
            "required": ["command"]
        }
    }
}
EOF
}

tool_run_command_execute() {
    local args_json="$1"
    local cmd
    cmd=$(echo "$args_json" | jq -r '.command')

    debug_log "tool" "run_command: ${cmd}"
    echo -e "${THEME_CMD}\$ ${cmd}${NC}" >&2

    # Dry-run check
    if [[ "${SHELLIA_DRY_RUN:-false}" == "true" ]]; then
        debug_log "tool" "skipped (dry-run)"
        echo "(dry-run: command not executed)"
        return 0
    fi

    # Safety check
    if is_dangerous "$cmd"; then
        debug_log "tool" "dangerous pattern matched"
        echo -e "${THEME_WARN}Warning: This command matches a dangerous pattern.${NC}" >&2
        read -rp "Run this? [y/N]: " confirm </dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_warn "Skipped." >&2
            echo "Command skipped by user."
            return 0
        fi
    fi

    # Execute
    local shell_cmd
    shell_cmd=$(detect_shell)
    local output
    local exit_code=0
    output=$("$shell_cmd" -c "$cmd" 2>&1) || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo -e "${THEME_ERROR}Command exited with code ${exit_code}${NC}" >&2
    fi

    # Return output + exit code to the LLM
    if [[ -n "$output" ]]; then
        printf '%s\n[exit code: %d]' "$output" "$exit_code"
    else
        printf '[exit code: %d]' "$exit_code"
    fi
}
```

**Step 2: Commit**

```bash
git add lib/tools/run_command.sh
git commit -m "feat: add run_command tool"
```

---

### Task 3: Create the `run_plan` tool

**Files:**
- Create: `lib/tools/run_plan.sh`

**Step 1: Create run_plan tool**

```bash
#!/usr/bin/env bash
# Tool: run_plan — execute a multi-step plan

tool_run_plan_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "run_plan",
        "description": "Execute a multi-step plan of sequential shell commands. Each step has a description and a command. All steps are shown to the user for review before execution. Use this when a task requires multiple coordinated commands.",
        "parameters": {
            "type": "object",
            "properties": {
                "steps": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "description": {
                                "type": "string",
                                "description": "What this step does and why"
                            },
                            "command": {
                                "type": "string",
                                "description": "The shell command to execute"
                            }
                        },
                        "required": ["description", "command"]
                    },
                    "description": "Ordered list of steps to execute"
                }
            },
            "required": ["steps"]
        }
    }
}
EOF
}

tool_run_plan_execute() {
    local args_json="$1"
    local plan_json
    plan_json=$(echo "$args_json" | jq '.steps')
    local step_count
    step_count=$(echo "$plan_json" | jq 'length')

    echo -e "${THEME_HEADER}Plan (${step_count} steps):${NC}" >&2
    echo "" >&2

    # Display all steps
    for ((i = 0; i < step_count; i++)); do
        local desc cmd
        desc=$(echo "$plan_json" | jq -r ".[$i].description")
        cmd=$(echo "$plan_json" | jq -r ".[$i].command")
        printf "  %d. %-35s -> %s\n" "$((i + 1))" "$desc" "$cmd" >&2
    done
    echo "" >&2

    # Dry-run check
    if [[ "${SHELLIA_DRY_RUN:-false}" == "true" ]]; then
        log_info "(dry-run: not executing)" >&2
        echo "(dry-run: plan not executed)"
        return 0
    fi

    read -rp "Run all? [y/N]: " confirm </dev/tty
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_warn "Cancelled." >&2
        echo "Plan cancelled by user."
        return 0
    fi

    echo "" >&2

    local results=""
    local shell_cmd
    shell_cmd=$(detect_shell)

    for ((i = 0; i < step_count; i++)); do
        local desc cmd
        desc=$(echo "$plan_json" | jq -r ".[$i].description")
        cmd=$(echo "$plan_json" | jq -r ".[$i].command")

        echo -e "${THEME_ACCENT}Step $((i + 1))/${step_count}: ${desc}${NC}" >&2

        local output
        local exit_code=0
        output=$("$shell_cmd" -c "$cmd" 2>&1) || exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            echo -e "  ${THEME_ERROR}✗ Failed (exit code ${exit_code})${NC}" >&2

            # Show remaining steps
            if [[ $((i + 1)) -lt $step_count ]]; then
                log_warn "Remaining steps not executed:" >&2
                for ((j = i + 1; j < step_count; j++)); do
                    local rdesc rcmd
                    rdesc=$(echo "$plan_json" | jq -r ".[$j].description")
                    rcmd=$(echo "$plan_json" | jq -r ".[$j].command")
                    printf "  %d. %-35s -> %s\n" "$((j + 1))" "$rdesc" "$rcmd" >&2
                done
            fi

            results="${results}Step $((i + 1)) (${desc}): FAILED (exit code ${exit_code})\nOutput: ${output}\n"
            printf '%b' "$results"
            return $exit_code
        else
            echo -e "  ${THEME_SUCCESS}✓ Done${NC}" >&2
            results="${results}Step $((i + 1)) (${desc}): OK\n"
            [[ -n "$output" ]] && results="${results}Output: ${output}\n"
        fi
    done

    echo "" >&2
    log_success "All ${step_count} steps completed successfully." >&2
    printf '%b' "$results"
}
```

**Step 2: Commit**

```bash
git add lib/tools/run_plan.sh
git commit -m "feat: add run_plan tool"
```

---

### Task 4: Create the `ask_user` tool

**Files:**
- Create: `lib/tools/ask_user.sh`

**Step 1: Create ask_user tool**

```bash
#!/usr/bin/env bash
# Tool: ask_user — ask the user a question and get their response

tool_ask_user_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "ask_user",
        "description": "Ask the user a question when you need clarification, a decision, or additional information before proceeding. The user's response is returned to you.",
        "parameters": {
            "type": "object",
            "properties": {
                "question": {
                    "type": "string",
                    "description": "The question to ask the user"
                }
            },
            "required": ["question"]
        }
    }
}
EOF
}

tool_ask_user_execute() {
    local args_json="$1"
    local question
    question=$(echo "$args_json" | jq -r '.question')

    echo -e "${THEME_ACCENT}${question}${NC}" >&2
    local answer
    read -rp "$(echo -e "${THEME_PROMPT}> ${NC}")" answer </dev/tty
    echo "$answer"
}
```

**Step 2: Commit**

```bash
git add lib/tools/ask_user.sh
git commit -m "feat: add ask_user tool"
```

---

### Task 5: Update API layer for tool calling (`lib/api.sh`)

**Files:**
- Modify: `lib/api.sh`

**Step 1: Update api_chat to include tools and parse tool_calls**

The core changes:
- `api_chat()` accepts an optional second arg for the tools JSON array; adds `tools` to request body if non-empty
- Returns the full message JSON (not just content) so the caller can check for tool_calls
- New `api_chat_loop()` function implements the tool execution loop

**Step 2: Commit**

```bash
git add lib/api.sh
git commit -m "feat: update api layer for tool calling with execution loop"
```

---

### Task 6: Update system prompt

**Files:**
- Modify: `defaults/system_prompt.txt`
- Modify: `lib/prompt.sh`

**Step 1: Simplify system prompt**

Remove the `[COMMAND]`, `[PLAN]`, `[EXPLANATION]` protocol. The tools API handles structured output now. Keep the role description, mode behavior, and rules.

**Step 2: Commit**

```bash
git add defaults/system_prompt.txt lib/prompt.sh
git commit -m "refactor: simplify system prompt for tool-based architecture"
```

---

### Task 7: Update entrypoint and REPL

**Files:**
- Modify: `shellia`
- Modify: `lib/repl.sh`

**Step 1: Update entrypoint**

- Source `lib/tools.sh`
- Call `load_tools()` at startup
- Replace `api_chat()` + `handle_response()` with `api_chat_loop()`
- Remove `handle_response()` function
- Set `SHELLIA_DRY_RUN` var for tools to check

**Step 2: Update REPL**

- Use `api_chat_loop()` instead of `api_chat()` + `handle_response()`
- Remove command tracking (tool loop handles it)

**Step 3: Commit**

```bash
git add shellia lib/repl.sh
git commit -m "refactor: wire entrypoint and REPL to tool-based flow"
```

---

### Task 8: Update tests

**Files:**
- Create: `tests/test_tools.sh`
- Modify: `tests/test_api.sh`
- Modify: `tests/test_entrypoint.sh`

**Step 1: Write test_tools.sh**

Test tool schema generation, dispatch, and individual tool execution.

**Step 2: Update test_api.sh**

Update for new request format (includes tools), add api_chat_loop tests.

**Step 3: Update test_entrypoint.sh**

Remove handle_response tests (replaced by tool system), keep CLI tests.

**Step 4: Run full test suite**

Run: `bash tests/run_tests.sh`
Expected: all pass

**Step 5: Commit**

```bash
git add tests/
git commit -m "test: add tool system tests, update api and entrypoint tests"
```

---

### Task 9: Update test runner to source tools

**Files:**
- Modify: `tests/run_tests.sh`

**Step 1: Source tools.sh and load tools in test runner**

Add after the existing lib sourcing:
```bash
source "${PROJECT_DIR}/lib/tools.sh"
load_tools
```

**Step 2: Commit**

```bash
git add tests/run_tests.sh
git commit -m "chore: source tool system in test runner"
```
