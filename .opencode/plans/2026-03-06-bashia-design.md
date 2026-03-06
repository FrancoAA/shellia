# Bashia Design Document

A bash-based terminal AI agent that translates natural language into shell commands and automates multi-step tasks, using OpenAI-compatible chat completion APIs.

## Goals

- Translate natural language to shell commands and execute them
- Automate multi-step tasks from a single description
- Support both bash and zsh
- Work with any OpenAI-compatible API provider (OpenRouter, etc.)

## Non-Goals

- Persistent chat companion / shell assistant
- Support for shells beyond bash/zsh
- GUI or TUI interface

## Tech Stack

- Pure bash script with `jq` as the only dependency
- `curl` for API calls
- OpenAI-compatible chat completions endpoint

---

## Project Structure

```
bashia/
├── bashia                    # Main executable script
├── lib/
│   ├── api.sh                # API call logic (curl + jq)
│   ├── config.sh             # Config loading (file + env var merging)
│   ├── prompt.sh             # System prompt assembly (base + user additions)
│   ├── executor.sh           # Command execution + safety checks
│   ├── repl.sh               # REPL loop logic
│   └── utils.sh              # Shared helpers (colors, logging, error handling)
├── defaults/
│   ├── system_prompt.txt     # Base system prompt (ships with bashia)
│   └── dangerous_commands    # Default dangerous command patterns
├── install.sh                # Installer script
├── LICENSE
└── README.md
```

**User config directory (`~/.bashia/`):**

```
~/.bashia/
├── config                    # API URL, key, model, preferences
├── dangerous_commands        # User-editable dangerous command patterns
├── system_prompt             # User's custom prompt additions (appended to base)
└── history                   # REPL conversation history
```

The main `bashia` script is the entrypoint. It parses arguments, sources the `lib/` files, and dispatches to the right mode (single prompt, REPL, pipe, or init).

---

## Configuration & Initialization

### `bashia init` flow

1. Check if `~/.bashia/` exists (offer to reconfigure if so)
2. Ask for API provider URL (default: `https://openrouter.ai/api/v1`)
3. Ask for API key
4. Ask for model ID (no default -- user types or pastes it)
5. Create `~/.bashia/config`, `dangerous_commands`, and empty `system_prompt`

### Config file format (`~/.bashia/config`)

```bash
# bashia configuration
BASHIA_API_URL=https://openrouter.ai/api/v1
BASHIA_API_KEY=sk-or-v1-xxxx
BASHIA_MODEL=anthropic/claude-sonnet-4
```

### Environment variable overrides

Any env var prefixed with `BASHIA_` takes precedence over the config file. Example: `export BASHIA_MODEL=openai/gpt-4o` overrides just the model for that session.

### Dangerous commands file (`~/.bashia/dangerous_commands`)

```
rm
sudo
mkfs
dd
fdisk
chmod 777
chown
kill -9
reboot
shutdown
mv /
```

One pattern per line. Bashia checks if the generated command starts with or contains any of these patterns before auto-running. If it matches, it prompts for confirmation. The user can add or remove entries freely.

### System prompt additions (`~/.bashia/system_prompt`)

```
# Custom instructions for bashia (appended to base prompt)
# Examples:
#   Prefer eza over ls
#   Use doas instead of sudo
#   Always use long flags for readability
```

Starts as a commented-out example file. Anything uncommented gets appended to the base system prompt on every API call.

---

## Invocation Modes

### Single prompt mode

```bash
bashia "find all python files modified today"
# Sends prompt to API, gets command back, safety check, run, display output

bashia --dry-run "find all python files modified today"
# Same but only prints the command, doesn't run it
```

### REPL mode

```bash
bashia
# Enters interactive loop with conversation context
```

### Pipe mode

```bash
cat error.log | bashia "what went wrong here?"
# Pipes stdin content into the prompt as context
# Returns explanation (not a command to run)
```

When stdin is not a TTY, bashia appends the piped content to the user's prompt and tells the LLM to analyze/explain rather than generate commands.

### Argument summary

| Flag | Effect |
|------|--------|
| (no args) | Enter REPL mode |
| `"prompt"` | Single prompt mode |
| `--dry-run` | Show command without running |
| `init` | Run setup wizard |
| `--help` | Show usage info |
| `--version` | Print version |

---

## API Communication

### Request format

Uses the OpenAI-compatible chat completions endpoint:

```bash
curl -s "$BASHIA_API_URL/chat/completions" \
  -H "Authorization: Bearer $BASHIA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "'"$BASHIA_MODEL"'",
    "messages": [
      {"role": "system", "content": "'"$system_prompt"'"},
      {"role": "user", "content": "'"$user_prompt"'"}
    ],
    "temperature": 0.2
  }'
```

Low temperature (0.2) for deterministic, precise commands.

### Response parsing

```bash
response=$(curl -s ...)
command=$(echo "$response" | jq -r '.choices[0].message.content')
```

### Structured response format

The base system prompt instructs the LLM to respond with a tag prefix:

- `[COMMAND]` -- single command to execute
- `[PLAN]` -- JSON array of `{"description": "...", "command": "..."}` objects for multi-step tasks
- `[EXPLANATION]` -- plain text explanation (pipe mode / analysis)

This lets bashia reliably parse what comes back and decide whether to execute, present a plan, or print text.

### Error handling

- HTTP errors (401, 429, 500): clear message with suggestion (check key, rate limit, try again)
- Malformed JSON response: print raw response and ask user to try again
- Network failure: check connectivity, suggest retrying

---

## Command Execution & Safety

### Single command flow

```
User prompt -> API call -> Parse response -> Safety check -> Execute/Confirm -> Show output
```

1. Extract command from API response
2. Check against `~/.bashia/dangerous_commands` -- match if command contains any pattern
3. **Safe command**: run immediately, display output
4. **Dangerous command**: print in yellow/red, prompt `Run this? [y/N]:`
5. Capture both stdout and stderr, display to user
6. Show exit code if non-zero

### Multi-step plan flow

```
User prompt -> API call -> Parse JSON plan -> Display full plan -> Confirm -> Execute all
```

1. Parse the `[PLAN]` JSON array into steps
2. Display the full plan:
   ```
   Plan (3 steps):
     1. Initialize npm project        -> npm init -y
     2. Install TypeScript             -> npm install -D typescript
     3. Create tsconfig                -> npx tsc --init
   Run all? [y/N]:
   ```
3. On confirmation, execute sequentially
4. Print each step as it runs with status (check or X)
5. **If any step fails**: stop execution, show the error, print remaining unexecuted steps

### Shell detection

Bashia detects the current shell (`$SHELL` or `$0`) and runs commands through the appropriate interpreter (bash or zsh).

---

## REPL Mode

### Startup

```
$ bashia
bashia v0.1.0 | model: anthropic/claude-sonnet-4 | type 'help' for commands
bashia> _
```

Brief header with version and active model, then enter prompt loop.

### Conversation management

- On REPL start: create `/tmp/bashia_conv_<timestamp>.json` with empty messages array
- Register `trap` on `EXIT`, `INT`, `TERM` to clean up temp file
- On each exchange: append user message and assistant response using `jq`
- Before each API call: estimate token usage (character count / 4), warn if approaching limits:
  ```
  Warning: Conversation is getting long (~12k tokens). Consider 'reset' to start fresh.
  ```
- On exit: delete temp file automatically

### Built-in REPL commands

These are handled locally, not sent to the API:

| Command | Effect |
|---------|--------|
| `help` | Show available commands |
| `reset` | Clear conversation file, start fresh |
| `history` | Show commands executed this session |
| `exit` / `quit` / Ctrl+D | Exit REPL, delete conversation file |
| `model <id>` | Switch model mid-session |
| `dry-run on/off` | Toggle dry-run mode |

### Pipe into REPL

```bash
cat error.log | bashia
bashia> what's wrong here?
# analyzes the piped content
```

Piped content is included as context for the first prompt only.

---

## Dependencies

- bash (4.0+) or zsh
- `jq` (JSON parsing)
- `curl` (API calls)

## Future considerations (not in scope now)

- `save` command to persist REPL conversations
- Shell completions (bash/zsh)
- Streaming API responses
- Plugin system for custom commands
