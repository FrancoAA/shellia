# Multimodal Input Core Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let Shellia include local image and text files in normal conversation turns via inline `@file` references.

**Architecture:** Add a prompt-expansion layer that parses raw user text into ordered canonical content parts before message building. Expand image references into multimodal image parts and text-file references into filename-labeled text parts, then serialize those canonical parts into OpenAI-compatible API request messages and persist the resolved content in conversation history.

**Tech Stack:** Bash 3.2+, jq, base64, file extension/MIME helpers, Shellia REPL/session architecture, OpenAI-compatible chat completions API, Shellia test runner.

---

### Task 1: Add failing parser and expansion tests

**Files:**
- Modify: `tests/test_api.sh`
- Test: `tests/test_api.sh`

**Step 1: Write a failing test for image reference expansion**

Add a test asserting a prompt like `Describe @tests/fixtures/cat.png` expands into ordered content parts containing prompt text and an `input_image` part.

**Step 2: Write a failing test for text file expansion**

Add a test asserting `@notes.txt` becomes a text part with filename context and file contents.

**Step 3: Write a failing test for mixed ordering and escapes**

Add tests covering mixed prompt text + image + text file ordering and `\@literal` remaining plain text.

**Step 4: Run focused tests to verify RED**

Run: `bash tests/run_tests.sh test_api`
Expected: FAIL because no `@file` expansion exists.

### Task 2: Implement `@file` expansion helpers

**Files:**
- Modify: `lib/api.sh`
- Test: `tests/test_api.sh`

**Step 1: Add path/token parser helper**

Implement a helper that scans raw prompt text and emits ordered text/file tokens, supporting `@path`, `@"path with spaces"`, and `\@` escaping.

**Step 2: Add file resolver helpers**

Implement helpers that:

- classify supported image/text file types,
- read text files with size limits,
- base64-encode image files and build image content-part payloads,
- reject missing/unsupported/directory inputs.

**Step 3: Add prompt-to-content-parts builder**

Convert a raw user prompt into canonical ordered content parts.

**Step 4: Run focused tests to verify GREEN**

Run: `bash tests/run_tests.sh test_api`
Expected: PASS for parser and expansion tests.

### Task 3: Add failing request serialization tests for image payloads

**Files:**
- Modify: `tests/test_api.sh`
- Test: `tests/test_api.sh`

**Step 1: Write a failing test for outgoing image serialization**

Mock `curl`, capture the request body, and assert image parts become provider-compatible image blocks while text parts remain text blocks.

**Step 2: Write a failing test for mixed text/image ordering in request JSON**

Assert the emitted request preserves the order of prompt text, image part, and inlined text-file content.

**Step 3: Run focused tests to verify RED**

Run: `bash tests/run_tests.sh test_api`
Expected: FAIL because request serialization still lacks image payload handling.

### Task 4: Implement multimodal request serialization

**Files:**
- Modify: `lib/api.sh`
- Test: `tests/test_api.sh`

**Step 1: Extend request serializer**

Teach the serializer to convert canonical `input_image` parts into OpenAI-compatible image content items and preserve text parts as text items.

**Step 2: Keep multimodal provider rejection messaging**

Preserve the improved 4xx error for provider/model multimodal rejection.

**Step 3: Run focused tests to verify GREEN**

Run: `bash tests/run_tests.sh test_api`
Expected: PASS.

### Task 5: Persist resolved content in REPL and single-prompt flows

**Files:**
- Modify: `lib/repl.sh`
- Modify: `shellia`
- Modify: `tests/test_repl.sh`
- Modify: `tests/test_entrypoint.sh`

**Step 1: Write failing persistence tests**

Add tests asserting REPL and single-prompt/web-mode persist the resolved content parts produced from `@file` references.

**Step 2: Update REPL path**

Resolve the raw user input into canonical content parts before request building and persist those exact parts after the turn.

**Step 3: Update single-prompt and web-mode path**

Resolve prompt content parts before request building and persist the same resolved content in session history.

**Step 4: Run focused tests to verify GREEN**

Run: `bash tests/run_tests.sh test_repl`
Run: `bash tests/run_tests.sh test_entrypoint`
Expected: PASS.

### Task 6: Final verification and progress record

**Files:**
- Modify: `tasks/todo.md`
- Test: `tests/run_tests.sh`

**Step 1: Run focused suites**

Run: `bash tests/run_tests.sh test_api`
Run: `bash tests/run_tests.sh test_repl`
Run: `bash tests/run_tests.sh test_entrypoint`
Expected: PASS.

**Step 2: Run full suite**

Run: `bash tests/run_tests.sh`
Expected: PASS with 0 failures.

**Step 3: Record validation results**

Update `tasks/todo.md` with the final focused/full test outcomes for `@file` support.
