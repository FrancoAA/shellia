# File Operation Tools for Shellia

**Date:** 2026-03-12
**Status:** Approved

## Problem

Shellia's LLM currently performs all file operations through `run_command` (raw shell commands like `find`, `grep`, `cat`, `sed`). This has two problems:

1. **Context window waste** — `cat` on a large file dumps the entire thing into the conversation context. There's no truncation, line limits, or byte caps.
2. **Unreliable commands** — The LLM sometimes generates malformed `grep`/`sed` commands with bad escaping or wrong flags.

## Goal

Add dedicated file tools with **structured parameters** and **built-in output control** to protect the context window. Primary motivation is token efficiency, not safety or feature parity.

## Approach

**Thin bash wrappers** — each tool is a self-contained `.sh` file in `lib/tools/` following the existing `tool_<name>_schema()` / `tool_<name>_execute()` convention. No new dependencies. Tools construct the right bash commands internally and post-process output (truncation, line numbers, byte caps).

### Alternatives Considered

| Approach | Pros | Cons | Verdict |
|----------|------|------|---------|
| **Thin bash wrappers** | Pure bash, no deps, fits existing pattern | Platform differences (macOS/GNU) | **Selected** |
| Python helper script | Robust text processing | Adds dependency, breaks identity | Rejected |
| Enhanced run_command | Minimal change | Doesn't solve structured params or request-side tokens | Rejected |

## Tool Inventory

### 1. `search_files` — Find files by glob pattern

**File:** `lib/tools/search_files.sh`

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `pattern` | string | yes | — | Glob pattern like `"*.py"` or `"src/**/*.ts"` |
| `path` | string | no | `$PWD` | Directory to search in |

**Returns:** Sorted list of matching paths (one per line), newest first. Capped at 100 results.

**Implementation:** `find "$path" -name "$pattern"` (or `-path` for patterns with `/`). Sorted by modification time.

### 2. `search_content` — Search file contents by regex

**File:** `lib/tools/search_content.sh`

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `pattern` | string | yes | — | Regex pattern to search for |
| `path` | string | no | `$PWD` | Directory to search in |
| `include` | string | no | — | File glob filter, e.g. `"*.js"` |

**Returns:** Matching lines as `filepath:line_number: content`, capped at 100 matches.

**Implementation:** `grep -rn` with fallback behavior. Prefers `rg` (ripgrep) if available for speed and `.gitignore` awareness.

### 3. `read_file` — Read a file with offset/limit

**File:** `lib/tools/read_file.sh`

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `path` | string | yes | — | File path to read |
| `offset` | integer | no | 1 | Starting line number (1-indexed) |
| `limit` | integer | no | 200 | Max lines to return |

**Returns:** File content with line number prefixes (`1: content`), plus header `[lines X-Y of Z total]`. Byte cap of 50KB.

**Implementation:** `wc -l` for total count, `awk` for the window with line numbering. Binary detection via `file --mime`.

### 4. `edit_file` — Exact string replacement

**File:** `lib/tools/edit_file.sh`

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `path` | string | yes | — | File path to edit |
| `old_string` | string | yes | — | Exact text to find |
| `new_string` | string | yes | — | Replacement text |
| `replace_all` | boolean | no | false | Replace all occurrences |

**Returns:** `"OK: replaced N occurrence(s) in <path>"` or error.

**Error conditions:**
- File doesn't exist
- `old_string` not found
- Multiple matches when `replace_all=false`
- `old_string` equals `new_string`

**Implementation:** Read file content, count occurrences via `awk`, perform replacement using `awk` (avoids sed regex escaping). Write back via temp file + mv for atomicity.

### 5. `write_file` — Create or overwrite a file

**File:** `lib/tools/write_file.sh`

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `path` | string | yes | — | File path to write |
| `content` | string | yes | — | Content to write |

**Returns:** `"OK: wrote N bytes to <path>"`. Notes `[overwriting existing file]` when applicable.

**Implementation:** `mkdir -p` for parent dirs, `printf '%s' "$content" > "$path"`.

## Output Control

These constants govern context window protection:

| Constant | Value | Purpose |
|----------|-------|---------|
| `MAX_SEARCH_RESULTS` | 100 | Max file/content matches returned |
| `MAX_READ_LINES` | 200 | Default line limit for read_file |
| `MAX_OUTPUT_BYTES` | 51200 | 50KB byte cap on any tool output |
| `MAX_LINE_LENGTH` | 2000 | Truncate individual lines longer than this |

**Truncation markers:**
- `[truncated: showing N of M total]` — when results exceed limits
- `[lines X-Y of Z total]` — read_file header
- `...[truncated]` — individual long lines
- `[binary file: <mime-type>, <size> bytes]` — binary file detection

**Noise exclusion** (for search tools):
```
.git, node_modules, __pycache__, .venv, .env, vendor,
dist, build, .next, coverage, *.pyc, *.min.js, *.map
```

## System Prompt Changes

Add to `defaults/system_prompt.txt`:

```
- Use search_files to find files by name pattern (instead of `find` via run_command)
- Use search_content to search file contents by regex (instead of `grep` via run_command)
- Use read_file to read files with controlled output (instead of `cat` via run_command)
- Use edit_file for precise text replacements in files (instead of `sed` via run_command)
- Use write_file to create or overwrite files (instead of heredocs via run_command)
- Prefer these dedicated file tools over run_command for file operations — they have
  built-in output limits that prevent context overflow.
```

## Safety Integration

- `edit_file` and `write_file` are destructive — route through the safety plugin's `before_tool_call` hook.
- The safety plugin currently only checks `run_command` — extend it to inspect destructive file tool paths.
- `read_file`, `search_files`, `search_content` are read-only — no safety check needed.

## Sizing

| File | Lines (est.) | Complexity |
|------|-------------|------------|
| `lib/tools/search_files.sh` | ~60 | Low |
| `lib/tools/search_content.sh` | ~80 | Medium |
| `lib/tools/read_file.sh` | ~80 | Medium |
| `lib/tools/edit_file.sh` | ~100 | Medium-High |
| `lib/tools/write_file.sh` | ~40 | Low |
| System prompt update | ~10 lines | Low |
| Safety plugin update | ~10 lines | Low |

**Total:** ~380 lines of new code across 5 new files and 2 existing files.
