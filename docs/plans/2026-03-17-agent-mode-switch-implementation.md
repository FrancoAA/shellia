# Agent Mode Switching Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add runtime agent mode switching between `build` and `plan`, where `plan` exposes a strict read-only toolset and `build` exposes all tools.

**Architecture:** Keep a single runtime mode variable (`SHELLIA_AGENT_MODE`) initialized to `build`. Filter tool schemas in `build_tools_array` by mode so the model only sees allowed tools. Add a REPL settings command (`mode`) to inspect/switch mode, then surface mode in prompt context and REPL UI so behavior is transparent.

**Tech Stack:** Bash 3.2+, jq, existing shellia plugin/tool system, shellia test runner.

---

### Task 1: Add failing tests for mode-aware tool filtering

**Files:**
- Modify: `tests/test_tools.sh`
- Test: `tests/test_tools.sh`

**Step 1: Write failing tests for plan mode filtering**

Add tests that call `build_tools_array` with `SHELLIA_AGENT_MODE=plan` and assert:

- Includes: `read_file`, `search_files`, `search_content`, `todo_write`, `ask_user`
- Excludes: `run_command`, `run_plan`, `write_file`, `edit_file`, `delegate_task`, `schedule_task`

Add a test for invalid mode fallback behavior to ensure `build` toolset is used.

**Step 2: Run tests to verify failures**

Run: `bash tests/run_tests.sh tools`
Expected: FAIL because filtering behavior is not implemented yet.

### Task 2: Implement mode state and tool filtering

**Files:**
- Modify: `lib/config.sh`
- Modify: `lib/tools.sh`
- Test: `tests/test_tools.sh`

**Step 1: Add mode defaults/validation in config**

In `lib/config.sh`:

- Set `SHELLIA_AGENT_MODE="${SHELLIA_AGENT_MODE:-build}"`
- Normalize/validate values (`build|plan`), fallback to `build` on invalid values.

**Step 2: Add mode-aware tool filtering in registry**

In `lib/tools.sh`:

- Add helper to return allowed tool names for current mode.
- Update `build_tools_array` to include schema only when the tool is allowed by mode.
- Keep current behavior unchanged for `build` mode.

**Step 3: Run tests to verify pass**

Run: `bash tests/run_tests.sh tools`
Expected: PASS for added filtering tests.

### Task 3: Add REPL mode command and UI visibility

**Files:**
- Modify: `lib/plugins/settings/plugin.sh`
- Modify: `lib/repl.sh`
- Test: `tests/test_repl.sh`

**Step 1: Write failing tests for mode command**

In `tests/test_repl.sh`, add tests for:

- `mode` prints current mode
- `mode plan` switches to plan
- `mode build` switches back to build
- invalid mode prints clear usage/help

**Step 2: Implement REPL command**

In `lib/plugins/settings/plugin.sh`:

- Add `repl_cmd_mode_handler`
- Add `repl_cmd_mode_help`
- Validate input and update `SHELLIA_AGENT_MODE`

In `lib/repl.sh`:

- Show mode in startup header.
- Ensure tool list is rebuilt per turn so mode switches apply immediately.

**Step 3: Run tests to verify pass**

Run: `bash tests/run_tests.sh repl`
Expected: PASS for mode command tests.

### Task 4: Add mode context to system prompt

**Files:**
- Modify: `lib/prompt.sh`
- Modify: `tests/test_prompt.sh`
- Test: `tests/test_prompt.sh`

**Step 1: Write failing prompt test**

Add assertion that generated prompt context includes `Agent mode: <build|plan>`.

**Step 2: Implement prompt context update**

In `lib/prompt.sh`, append current agent mode to CONTEXT block.

**Step 3: Run tests to verify pass**

Run: `bash tests/run_tests.sh prompt`
Expected: PASS.

### Task 5: Full regression and docs consistency

**Files:**
- Modify: `README.md` (if needed for command/help updates)
- Test: `tests/run_tests.sh`

**Step 1: Run full test suite**

Run: `bash tests/run_tests.sh`
Expected: PASS with 0 failures.

**Step 2: Update docs only if output/help changed materially**

If REPL command list in docs is stale, update the relevant section.

**Step 3: Final verification**

Re-run focused checks for `tools`, `repl`, and `prompt` if any final edits were made.
