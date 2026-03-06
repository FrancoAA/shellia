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
| `profiles` | List all profiles |
| `profile <name>` | Switch profile (provider + model) |
| `dry-run on/off` | Toggle dry-run mode |
| `themes` | List available themes |
| `theme <name>` | Switch theme |
| `exit` / `quit` | Exit shellia |

## Safety

Shellia maintains a list of dangerous command patterns at `~/.shellia/dangerous_commands`. Any generated command matching these patterns requires explicit confirmation before running. You can edit this file to add or remove patterns.

Default dangerous patterns: `rm`, `sudo`, `mkfs`, `dd`, `fdisk`, `chmod 777`, `chown`, `kill -9`, `reboot`, `shutdown`, `mv /`

## Profiles

Shellia supports named profiles, each with its own API provider, key, and model. This lets you switch between providers (OpenRouter, OpenAI, local models) without editing config files.

### Managing profiles

```bash
# List all profiles
shellia profiles

# Add a new profile (interactive wizard)
shellia profile add openai

# Remove a profile
shellia profile remove openai
```

### Using profiles

```bash
# Use a specific profile for one command
shellia --profile openai "list running containers"

# Switch profiles in the REPL
shellia
shellia> profiles
shellia> profile openai
```

Running `shellia init` creates a "default" profile. You can add more at any time.

### Quick model swap

Use `model <id>` in the REPL to change the model without switching the full profile:

```bash
shellia> model openai/gpt-4o
```

## Configuration

Shellia reads configuration from `~/.shellia/config` with environment variable overrides:

| Config key | Env variable | Description |
|------------|-------------|-------------|
| `SHELLIA_PROFILE` | `SHELLIA_PROFILE` | Active profile name (default: "default") |
| `SHELLIA_THEME` | `SHELLIA_THEME` | Color theme (default, ocean, forest, sunset, minimal) |

API settings (`SHELLIA_API_URL`, `SHELLIA_API_KEY`, `SHELLIA_MODEL`) are stored per-profile in `~/.shellia/profiles`. Environment variables take precedence over profile values:

```bash
SHELLIA_MODEL=openai/gpt-4o shellia "list running containers"
```

### Themes

Shellia includes 5 color themes. Switch themes in the REPL with `theme <name>` or set permanently in `~/.shellia/config`:

- **default** — Cyan and magenta accents
- **ocean** — Blue and cyan tones
- **forest** — Green and yellow tones
- **sunset** — Warm reds and magentas
- **minimal** — Monochrome, just bold and dim

Use `themes` in the REPL to preview all available themes.

### Custom instructions

Add personal preferences to `~/.shellia/system_prompt`:

```
Prefer eza over ls
Use doas instead of sudo
Always use long flags for readability
```

These are appended to the base system prompt on every API call.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/FrancoAA/shellia/main/uninstall.sh | bash
```

Or from a cloned repo:

```bash
./uninstall.sh
```

This removes the wrapper and cloned source. You'll be asked whether to keep or delete your configuration (`~/.shellia/`).

## Dependencies

- bash (4.0+) or zsh
- `jq`
- `curl`
- `git` (for installation only)

## License

MIT
