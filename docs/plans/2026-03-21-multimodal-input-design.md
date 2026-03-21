# Multimodal Input Core Design

## Goal

Make Shellia able to include local image files and text files directly in a user prompt by referencing them inline with `@path` during normal conversation.

## Scope

In scope:

- Parse `@file` references in REPL and single-prompt input.
- Resolve local image and text files before the API call.
- Convert referenced images into multimodal content parts sent to the model.
- Inline referenced text files as text content parts with filename context.
- Preserve prompt text and referenced-file order in the final user message.
- Persist resolved canonical message parts in conversation history.
- Keep backward compatibility with existing text-only history.

Out of scope:

- Web upload support.
- Telegram multimodal input wiring.
- Remote URLs.
- Arbitrary binary file support beyond images.
- Capability detection or model flags.
- Multimodal assistant output rendering.

## User-Facing Behavior

Users can reference files inline while chatting:

- `What is in @screenshots/login.png?`
- `Compare @mockup.png with requirements in @docs/spec.txt`
- `Summarize @README.md and tell me if @images/diagram.png matches it`

Behavior rules:

- `@path` includes the referenced file in the same user turn.
- Image files become multimodal image parts.
- Text files become text parts containing the file contents.
- Plain prompt text remains plain text and stays in order around file references.
- `\@literal` escapes a literal at-sign and does not trigger file inclusion.

## Supported File Types

First slice support:

- Images: `.png`, `.jpg`, `.jpeg`, `.webp`, `.gif`
- Text: `.txt`, `.md`, `.json`, `.yaml`, `.yml`, `.sh`, `.py`, `.js`, `.ts`, `.tsx`

Anything else should fail early with a clear local error.

## Prompt Expansion Model

The prompt preprocessor should transform one raw user string into ordered content parts.

Example:

```text
Compare @mockup.png with notes in @spec.txt
```

Becomes canonical user content similar to:

```json
[
  { "type": "text", "text": "Compare " },
  {
    "type": "input_image",
    "mime_type": "image/png",
    "source": "data_url",
    "data_url": "data:image/png;base64,...",
    "path": "mockup.png"
  },
  { "type": "text", "text": " with notes in " },
  { "type": "text", "text": "File: spec.txt\n---\n...contents..." }
]
```

This preserves the exact order the user wrote, which gives the model the most faithful context.

## Resolution Rules

- Resolve referenced paths relative to the current working directory.
- Reject directories.
- Reject missing files.
- Reject unsupported extensions.
- Reject oversized files before building the API request.
- Support quoted paths with spaces using `@"path with spaces/file.png"`.

The first slice should stay local-only and deterministic.

## Canonical Message Format

Internal non-system messages remain canonical content-part arrays.

- Plain text-only prompts still become one text part.
- Prompts with `@file` references become mixed ordered parts.
- Assistant and tool messages remain text-part arrays in this phase.

Legacy messages with string `content` are still normalized on read.

## API Serialization

`lib/api.sh` should serialize canonical parts into OpenAI-compatible chat messages:

- text part -> `{ "type": "text", "text": ... }`
- image part -> provider-compatible image block using the encoded local file payload

System messages remain string content for compatibility.

## Persistence Changes

Persist the resolved canonical message parts rather than the original raw `@file` token string.

Why:

- follow-up turns should reflect what the model actually received,
- history should remain reproducible,
- the app avoids reparsing missing or later-changed files when replaying history.

## Error Handling

Fail before the API call when:

- file path is invalid,
- file is unreadable,
- file type is unsupported,
- text file exceeds configured size limit,
- image file exceeds configured size limit.

If the upstream provider rejects the multimodal request, Shellia should still surface a clear error saying the selected model/provider rejected multimodal input.

## Testing Strategy

Add tests for:

- plain text prompt remains text-only,
- mixed prompt with image + text-file references preserves ordering,
- escaped `\@file` stays literal,
- quoted paths with spaces resolve correctly,
- missing files and unsupported files fail clearly,
- REPL and single-prompt persistence stores canonical resolved content parts,
- API request serialization emits image blocks and text parts in the expected order.

## Success Criteria

- In REPL and single-prompt mode, `@file` references include local image and text files in the model input.
- Images are visible to a multimodal model in the same turn.
- Text files are inlined with filename context.
- Existing text-only prompts continue to work.
- Stored conversation history reflects the resolved message content sent to the model.
