# Compact REPL Command Design

## Goal

Add a new REPL command, `compact`, that summarizes the current conversation and starts a fresh conversation seeded with that summary to save context.

## Scope

In scope:

- Add `compact` as a plugin-provided REPL command.
- Summarize the active in-memory conversation using a fixed summarization prompt.
- Replace conversation history with one visible assistant message containing the summary.
- Start a new persistent history session after compaction.
- Add tests and docs for command behavior.

Out of scope:

- Automatic compaction triggers.
- Token-budget-aware partial compaction.
- Multi-summary history stitching.

## Command Behavior

- Command: `compact`
- No arguments; any arguments are ignored with usage warning.
- If conversation history is empty, print an informational no-op message.
- If history exists:
  1. Build a transcript from current conversation messages.
  2. Send one API request with a fixed system prompt and transcript as user content.
  3. Receive summary text.
  4. Overwrite `SHELLIA_CONV_FILE` with one message:
     - `{"role":"assistant","content":"<summary>"}`
  5. Fire `conversation_reset` hook so history plugin starts a fresh session.
  6. Print success message indicating conversation was compacted.

## Plugin Placement

Implement in the core plugin (`lib/plugins/core/plugin.sh`) as a REPL command:

- `repl_cmd_compact_handler`
- `repl_cmd_compact_help`

Rationale:

- User explicitly requested plugin implementation.
- `compact` is conversation-lifecycle behavior and best kept in a built-in always-loaded plugin.
- Core plugin can rely on globally available runtime helpers (`SHELLIA_CONV_FILE`, `build_system_prompt`, `build_tools_array`, `api_chat_loop`, `fire_hook`).

## Summarization Prompt

Use exactly this system prompt for the compaction request:

```text
You are a helpful AI assistant tasked with summarizing conversations.

When asked to summarize, provide a detailed but concise summary of the conversation.
Focus on information that would be helpful for continuing the conversation, including:
- What was done
- What is currently being worked on
- Which files are being modified
- What needs to be done next
- Key user requests, constraints, or preferences that should persist
- Important technical decisions and why they were made

Your summary should be comprehensive enough to provide context but concise enough to be quickly understood.

Do not respond to any questions in the conversation, only output the summary.
```

## Data Flow

1. Read `SHELLIA_CONV_FILE` JSON array.
2. Convert entries into transcript lines with role labels (`user:` / `assistant:`).
3. Build messages via `build_single_messages` using the compaction prompt as system content.
4. Call `api_chat_loop` with an empty tools array (`[]`) to prevent tool usage during summarization.
5. Persist summary-only conversation state into `SHELLIA_CONV_FILE`.

## Error Handling

- If conversation file is missing or invalid JSON, print warning and no-op.
- If API call fails, preserve original conversation and print warning.
- If API returns empty summary, preserve original conversation and print warning.

## Testing Strategy

Add tests in `tests/test_repl.sh` (plugin command behavior can still be tested through REPL flow):

- `compact` after at least one user turn rewrites conversation to one assistant summary message.
- `compact` on empty conversation is no-op and does not crash.
- `repl_help` includes `compact` through plugin help aggregation.

Use API stubs to make tests deterministic.

## Documentation

- Update `README.md` REPL command table to include `compact`.
- Mention that compaction creates a new conversation seeded with a summary message.

## Success Criteria

- Running `compact` creates a concise summary and resets active context to that summary.
- Summary is visible to the user as an assistant message in new conversation history.
- Existing commands (`reset`, `reload`, plugin commands) keep working unchanged.
- Tests pass for new compact command behavior.
