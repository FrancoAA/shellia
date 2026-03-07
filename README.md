# shellia

A terminal agent that helps you execute and automate tasks from the console. Supports bash and zsh. Works with any OpenAI-compatible API provider (OpenRouter, OpenAI, Anthropic via proxy, local models, etc.).

## What it does

- **Run commands from natural language** — describe what you want, shellia does it
- **Generate scripts and files** — create shell scripts, config files, and more
- **Automate multi-step workflows** — describe a workflow, shellia plans and executes it
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

This clones the repo to `~/.local/share/shellia/src`, creates a wrapper in `~/.local/bin`, and offers to add it to your PATH.

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

Configuration is stored in `~/.config/shellia/config` with `chmod 600`.

## Usage

### Single command

```bash
shellia "show disk usage sorted by size"
```

Shellia turns your request into a shell command and runs it. Dangerous commands (rm, sudo, mkfs, etc.) prompt for confirmation before executing.

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

**Core REPL commands:**

| Command | Effect |
|---------|--------|
| `help` | Show all available commands (core + plugin) |
| `reset` | Clear conversation history |
| `plugins` | List loaded plugins and their hooks |
| `exit` / `quit` | Exit shellia |

**Plugin-provided REPL commands** (loaded from built-in plugins):

| Command | Plugin | Effect |
|---------|--------|--------|
| `model <id>` | settings | Switch model mid-session |
| `profiles` | settings | List all profiles |
| `profile <name>` | settings | Switch profile (provider + model) |
| `dry-run on/off` | settings | Toggle dry-run mode |
| `debug on/off` | settings | Toggle debug output |
| `themes` | themes | List available themes |
| `theme <name>` | themes | Switch theme |
| `history` | history | Show conversation history for current session |

## Plugins

Shellia uses a hook-based plugin system. Core functionality like safety checks, themes, settings, and conversation history are implemented as plugins.

### Built-in plugins

| Plugin | Description |
|--------|-------------|
| `safety` | Blocks dangerous commands (rm, sudo, etc.) with confirmation prompts |
| `themes` | Theme listing and switching REPL commands |
| `settings` | Model, profile, dry-run, and debug REPL commands |
| `history` | Persistent JSONL conversation history per session |

### Plugin locations

Plugins are loaded from two directories (user plugins can override built-in ones):

1. **Built-in:** `lib/plugins/` (ships with shellia)
2. **User:** `~/.config/shellia/plugins/` (your custom plugins)

### Listing plugins

```bash
# CLI
shellia plugins

# REPL
shellia> plugins
```

### Creating a plugin

A plugin is either a single file (`name.sh`) or a directory (`name/plugin.sh`). Every plugin must define two functions:

```bash
# ~/.config/shellia/plugins/myplugin.sh

plugin_myplugin_info() { echo "My custom plugin"; }
plugin_myplugin_hooks() { echo "init shutdown"; }

# Hook handlers (on_ prefix is added automatically)
plugin_myplugin_on_init() {
    # Called when shellia starts
    :
}

plugin_myplugin_on_shutdown() {
    # Called when shellia exits
    :
}
```

### Available hooks

| Hook | Fired when |
|------|-----------|
| `init` | Shellia starts up |
| `shutdown` | Shellia exits |
| `user_message` | User sends a message (arg: message text) |
| `assistant_message` | Assistant responds (arg: response text) |
| `conversation_reset` | User runs `reset` |
| `before_api_call` | Before each API request |
| `after_api_call` | After each API response |
| `before_tool_call` | Before tool execution (args: tool name, arguments) |
| `after_tool_call` | After tool execution (args: tool name, result) |
| `prompt_build` | Building the system prompt (stdout is appended to prompt) |

### Plugin-provided REPL commands

Plugins can register REPL commands by defining handler and help functions:

```bash
repl_cmd_greet_handler() { echo "Hello, $1!"; }
repl_cmd_greet_help() { echo "  /greet <name>  - Greet someone"; }
```

Commands with hyphens are converted to underscores for the function name (`dry-run` -> `repl_cmd_dry_run_handler`).

### Plugin-provided tools

Plugins can define tools using the same `tool_*` convention as built-in tools:

```bash
tool_my_search() { echo "result for: $1"; }
tool_my_search_description() { echo "Search for something"; }
tool_my_search_schema() { cat <<'EOF'
{"type":"function","function":{"name":"my_search","description":"Search","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}}
EOF
}
```

### Plugin configuration

Each plugin can have its own config file at `~/.config/shellia/plugins/<name>/config`:

```
key=value
timeout=30
```

Plugins read their config with `plugin_config_get "name" "key" "default"`.

## Safety

Shellia's safety plugin maintains a list of dangerous command patterns at `~/.config/shellia/dangerous_commands`. Any generated command matching these patterns requires explicit confirmation before running. You can edit this file to add or remove patterns.

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

Shellia reads configuration from `~/.config/shellia/config` with environment variable overrides:

| Config key | Env variable | Description |
|------------|-------------|-------------|
| `SHELLIA_PROFILE` | `SHELLIA_PROFILE` | Active profile name (default: "default") |
| `SHELLIA_THEME` | `SHELLIA_THEME` | Color theme (default, ocean, forest, sunset, minimal) |

API settings (`SHELLIA_API_URL`, `SHELLIA_API_KEY`, `SHELLIA_MODEL`) are stored per-profile in `~/.config/shellia/profiles`. Environment variables take precedence over profile values:

```bash
SHELLIA_MODEL=openai/gpt-4o shellia "list running containers"
```

### Themes

Shellia includes 5 color themes. Switch themes in the REPL with `theme <name>` or set permanently in `~/.config/shellia/config`:

- **default** — Cyan and magenta accents
- **ocean** — Blue and cyan tones
- **forest** — Green and yellow tones
- **sunset** — Warm reds and magentas
- **minimal** — Monochrome, just bold and dim

Use `themes` in the REPL to preview all available themes.

### Custom instructions

Add personal preferences to `~/.config/shellia/system_prompt`:

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

This removes the wrapper and cloned source. You'll be asked whether to keep or delete your configuration (`~/.config/shellia/`).

## Dependencies

- bash (3.2+) or zsh
- `jq`
- `curl`
- `git` (for installation only)

## License

MIT
