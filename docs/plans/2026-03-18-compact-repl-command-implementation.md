# Compact REPL Command Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a plugin-provided `compact` REPL command that summarizes current conversation context and replaces history with a single assistant summary message.

**Architecture:** Implement `compact` in the core plugin so it is always available in REPL. The command reads `SHELLIA_CONV_FILE`, generates a summary via `api_chat_loop` using a fixed summarization prompt and no tools, then rewrites the conversation file to one assistant message and fires `conversation_reset` to begin a fresh persisted session.

**Tech Stack:** Bash 3.2+, jq, existing REPL/plugin architecture, shellia API loop, shellia test runner.

---

### Task 1: Add failing REPL tests for compact command behavior

**Files:**
- Modify: `tests/test_repl.sh`
- Test: `tests/test_repl.sh`

**Step 1: Write failing tests for compact success path**

Add a test that:

- stubs `api_chat_loop` to return a known summary string,
- seeds conversation by sending at least one prompt,
- runs `compact`,
- asserts resulting conversation file content has exactly one entry with:
  - `role == "assistant"`
  - `content == <stubbed summary>`

**Step 2: Write failing tests for empty conversation behavior**

Add a test that runs `compact` before any user turn and asserts:

- no crash,
- output includes no-op/empty conversation message,
- conversation file remains empty array.

**Step 3: Write failing help-output test**

Add a test that verifies `repl_help` includes `compact` via plugin help output.

**Step 4: Run tests to verify they fail first**

Run: `bash tests/run_tests.sh repl`
Expected: FAIL due to missing compact command implementation.

### Task 2: Implement compact command in core plugin

**Files:**
- Modify: `lib/plugins/core/plugin.sh`
- Test: `tests/test_repl.sh`

**Step 1: Add compact prompt constant/helper**

In `lib/plugins/core/plugin.sh`, add a helper that returns the exact required compaction prompt text.

**Step 2: Implement transcript builder helper**

Add helper(s) to:

- load JSON from `SHELLIA_CONV_FILE`,
- validate array shape,
- render transcript lines in deterministic order: `user: ...` / `assistant: ...`.

**Step 3: Implement `repl_cmd_compact_handler`**

Behavior:

- validate no args (warn on extra args),
- detect empty/missing/invalid conversation and no-op safely,
- build one-shot messages with compaction prompt + transcript,
- call `api_chat_loop` with `[]` tools,
- if summary non-empty: overwrite `SHELLIA_CONV_FILE` with one assistant message,
- call `fire_hook "conversation_reset"`,
- print success message.

Error path:

- preserve original file on API failure or empty output,
- print warning and return non-zero where appropriate.

**Step 4: Add `repl_cmd_compact_help`**

Add concise help line in plugin help format.

**Step 5: Run tests to verify pass**

Run: `bash tests/run_tests.sh repl`
Expected: PASS for compact tests.

### Task 3: Update REPL documentation

**Files:**
- Modify: `README.md`

**Step 1: Add `compact` to core REPL command table**

Add command row describing summary-based context reset.

**Step 2: Verify wording matches implementation**

Ensure docs state that new conversation is seeded with visible assistant summary.

### Task 4: Final verification and regression

**Files:**
- Test: `tests/run_tests.sh`

**Step 1: Run focused tests**

Run: `bash tests/run_tests.sh repl`
Expected: PASS.

**Step 2: Run full suite**

Run: `bash tests/run_tests.sh`
Expected: PASS with 0 failures.

**Step 3: Manual smoke verification**

Run interactive scenario:

```bash
shellia
# enter one prompt
compact
# verify summary appears and subsequent prompt has compacted context
```

Expected: command executes without errors and conversation continues from summary context.
