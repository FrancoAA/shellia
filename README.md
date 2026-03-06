# shellia

A terminal AI agent that translates natural language into shell commands. Supports bash and zsh. Works with any OpenAI-compatible API provider (OpenRouter, OpenAI, Anthropic via proxy, local models, etc.).

## What it does

- **Translate natural language to commands** — describe what you want, shellia runs it
- **Automate multi-step tasks** — describe a workflow, shellia plans and executes it
- **Analyze piped input** — pipe errors, logs, or output for AI-powered analysis
- **Interactive REPL** — conversational mode with context across exchanges

```bash
# Translate and run
shellia "find all files larger than 100MB"

# Preview without running
shellia --dry-run "delete all node_modules directories"

# Analyze piped input
cat error.log | shellia "what went wrong here?"

# Interactive mode
shellia
shellia> find python files modified today
shellia> now count the lines in each one
```

## Install

**Requirements:** `curl`, `jq`, `git`

### One-liner install

```bash
curl -fsSL https://raw.githubusercontent.com/FrancoAA/shellia/main/install.sh | bash
```

This clones the repo to `~/.shellia/src`, creates a wrapper in `~/.local/bin`, and offers to add it to your PATH.

### Manual install

```bash
git clone https://github.com/FrancoAA/shellia.git
cd shellia
./install.sh
```

### Setup

After installing, configure your API provider:

```bash
shellia init
```

You'll be asked for:
- **API URL** — defaults to `https://openrouter.ai/api/v1`
- **API key** — your provider's API key
- **Model ID** — e.g. `anthropic/claude-sonnet-4`, `openai/gpt-4o`

Configuration is stored in `~/.shellia/config` with `chmod 600`.

## Usage

### Single command

```bash
shellia "show disk usage sorted by size"
```

Shellia translates your request to a shell command and runs it. Dangerous commands (rm, sudo, mkfs, etc.) prompt for confirmation before executing.

### Dry run

```bash
shellia --dry-run "compress all jpg files in this directory"
```

Shows the generated command without running it.

### Pipe mode

```bash
dmesg | shellia "are there any disk errors?"
cat deploy.log | shellia "summarize the failures"
```

Piped input is sent as context — shellia returns an explanation instead of a command.

### REPL mode

```bash
shellia
```

Starts an interactive session with conversation context. Follow-up prompts understand previous exchanges.

**Built-in REPL commands:**

| Command | Effect |
|---------|--------|
| `help` | Show available commands |
| `reset` | Clear conversation history |
| `history` | Show commands executed this session |
| `model <id>` | Switch model mid-session |
| `dry-run on/off` | Toggle dry-run mode |
| `exit` / `quit` | Exit shellia |

## Safety

Shellia maintains a list of dangerous command patterns at `~/.shellia/dangerous_commands`. Any generated command matching these patterns requires explicit confirmation before running. You can edit this file to add or remove patterns.

Default dangerous patterns: `rm`, `sudo`, `mkfs`, `dd`, `fdisk`, `chmod 777`, `chown`, `kill -9`, `reboot`, `shutdown`, `mv /`

## Configuration

Shellia reads configuration from `~/.shellia/config` with environment variable overrides:

| Config key | Env variable | Description |
|------------|-------------|-------------|
| `SHELLIA_API_URL` | `SHELLIA_API_URL` | API endpoint URL |
| `SHELLIA_API_KEY` | `SHELLIA_API_KEY` | API authentication key |
| `SHELLIA_MODEL` | `SHELLIA_MODEL` | Model identifier |

Environment variables take precedence over the config file. Example:

```bash
SHELLIA_MODEL=openai/gpt-4o shellia "list running containers"
```

### Custom instructions

Add personal preferences to `~/.shellia/system_prompt`:

```
Prefer eza over ls
Use doas instead of sudo
Always use long flags for readability
```

These are appended to the base system prompt on every API call.

## Dependencies

- bash (4.0+) or zsh
- `jq`
- `curl`
- `git` (for installation only)

## License

MIT
