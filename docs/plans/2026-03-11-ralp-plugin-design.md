# RALP Plugin Design

**Date:** 2026-03-11
**Status:** Approved

## Overview

The RALP plugin adds an `ralp` REPL command to shellia that guides the user through an LLM-driven PRD (Product Requirements Document) interview, then automatically feeds the resulting PRD into an iterative `claude` CLI loop.

The name stands for: **Read, Ask, Loop, Produce**.

## Goals

- Guide the user through a conversational PRD interview via the LLM
- Produce a structured PRD markdown file in the current working directory
- Launch the reference `ralph.sh`-style claude iteration loop with the PRD as the prompt
- Integrate cleanly into shellia's existing plugin architecture

## Entry Point

```bash
# In the shellia REPL
ralp [topic] [--max-iterations=N]
```

- `topic` — optional upfront description of the feature/task
- `--max-iterations=N` — number of claude loop iterations (default from config, fallback: 5)

## Architecture

### Plugin location

```
lib/plugins/ralp/
├── plugin.sh             # plugin registration, REPL command, sub-loop logic
└── interview_prompt.txt  # PRD interview system prompt
```

### Plugin registration

- `plugin_ralp_info()` — one-line description
- `plugin_ralp_hooks()` — returns `""` (no hooks subscribed; purely REPL-command driven)
- `repl_cmd_ralp_handler()` — entry point
- `repl_cmd_ralp_help()` — help text

### Plugin configuration

Stored at `~/.config/shellia/plugins/ralp/config`:

```
max_iterations=5
prd_dir=.
```

Read via `plugin_config_get "ralp" "max_iterations" "5"`.

## Data Flow

```
ralp [topic] [--max-iterations=N]
    │
    ▼
Parse args → resolve max_iterations (arg > config > default:5)
    │
    ▼
PRD Interview Sub-Loop
    ├─ Prompt: "ralp> "
    ├─ Own conversation file: /tmp/shellia_ralp_<timestamp>.json
    ├─ System prompt: interview_prompt.txt (injected once)
    ├─ If topic provided: injected as first user message automatically
    └─ Each turn:
        user input → build_conversation_messages() → api_chat_loop()
              │
              └─ LLM responds with question OR [INTERVIEW_COMPLETE]\n<PRD markdown>
                        │
                    Sentinel detected?
                        ├─ NO  → print response, continue loop
                        └─ YES → extract PRD content, exit interview loop
                                    │
                                    ▼
                          Write ./prd-<slug>.md
                          (slug = sanitized first line of PRD title or timestamp)
                                    │
                                    ▼
                          Print: "PRD saved to prd-<slug>.md"
                          Ask: "Launch claude loop? [Y/n]"
                                    │
                                    ▼
                          Claude iteration loop:
                          for i in 1..N:
                              claude -p "$prd_content" \
                                  --dangerously-skip-permissions \
                                  --output-format stream-json | cclean
```

## Sub-Loop Details

The interview sub-loop is a self-contained `while true; read` loop inside `repl_cmd_ralp_handler`. It does **not** reuse `repl_start` — it manages its own:

- Conversation temp file (`/tmp/shellia_ralp_<ts>.json`)
- Custom prompt string (`ralp> `)
- Sentinel detection after each API response
- `exit`/`quit`/`abort` commands to cancel mid-interview

It reuses shellia's existing functions:
- `build_conversation_messages()` — message assembly with history
- `api_chat_loop()` — API call + tool loop
- `spinner_start` / `spinner_stop` — UX
- `format_markdown` — response display
- `plugin_config_get` — config reads

## Sentinel Protocol

The interview system prompt instructs the LLM:

1. Ask one focused question per turn
2. Minimum required before completing: feature description, primary goal, at least one acceptance criterion
3. When ready, output exactly:

```
[INTERVIEW_COMPLETE]
# PRD: <Feature Name>
...markdown body...
```

The plugin detects `[INTERVIEW_COMPLETE]` as a line prefix in the response. Everything after it is the PRD content.

## PRD Interview System Prompt (`interview_prompt.txt`)

The prompt instructs the LLM to act as a senior product manager / engineer. It:

- Asks one question at a time
- Covers: feature goal, target users, key requirements, acceptance criteria, out-of-scope, technical constraints
- Does not emit `[INTERVIEW_COMPLETE]` until it has the minimum required information
- Produces a structured PRD with sections: Overview, Goals, Users, Requirements, Acceptance Criteria, Out of Scope

## Claude Loop

After PRD is written, the plugin:

1. Confirms with the user before launching (Y/n prompt)
2. Checks for `cclean` and installs it if missing (matching reference script behavior)
3. Runs the iteration loop:

```bash
for ((i=1; i<=MAX_ITERATIONS; i++)); do
    echo "=== Iteration $i of $MAX_ITERATIONS ==="
    claude -p "$prd_content" \
        --dangerously-skip-permissions \
        --output-format stream-json | cclean
done
```

4. Reports completion after all iterations finish

## Error Handling

- API errors during interview: print error, allow user to retry or `abort`
- `claude` not found: print install instructions, exit cleanly
- `cclean` not found: auto-install via its install script
- User Ctrl+D during interview: treat as `abort`, clean up temp file

## Files Changed / Created

| File | Action |
|------|--------|
| `lib/plugins/ralp/plugin.sh` | Create |
| `lib/plugins/ralp/interview_prompt.txt` | Create |
| `README.md` | Update plugin table + REPL commands table |
