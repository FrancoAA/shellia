# shellia

A terminal agent that helps you execute and automate tasks from the console. Supports bash and zsh. Works with any OpenAI-compatible API provider (OpenRouter, OpenAI, Anthropic via proxy, local models, etc.).

## What it does

- **Run commands from natural language** — describe what you want, shellia does it
- **Generate scripts and files** — create shell scripts, config files, and more
- **Automate multi-step workflows** — describe a workflow, shellia plans and executes it
- **Track work with todos** — the agent can maintain a markdown todo checklist during execution
- **Analyze piped input** — pipe errors, logs, or output for AI-powered analysis
- **Interactive REPL** — conversational mode with context across exchanges
- **Web UI** — browser-based chat interface via `shellia serve`
- **Agent skills** — Claude-compatible skill discovery and loading from shared hub or local config
- **Telegram bot** — chat with shellia via Telegram
- **Web search** — search the web using Brave Search API
- **Persistent memory** — the agent remembers facts across sessions
- **MCP integration** — connect to Model Context Protocol servers and use their tools

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

### Test installation

Run the test suite to verify everything works:

```bash
bash tests/run_tests.sh
```

Shellia has 880+ tests covering all core functionality.

## Usage

### Single command

```bash
shellia "show disk usage sorted by size"
```

Shellia turns your request into a shell command and runs it. **Tip:** If your prompt contains parentheses, commas, or other special characters, keep it in double quotes so the shell (especially zsh) doesn’t interpret them — e.g. `shellia "build a table (lines)"` instead of `shellia build a table (lines)`. Dangerous commands (rm, sudo, mkfs, etc.) prompt for confirmation before executing.

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
| `todos` | Show persisted todo checklist |
| `exit` / `quit` | Exit shellia |

**Plugin-provided REPL commands** (loaded from built-in plugins):

| Command | Plugin | Effect |
|---------|--------|--------|
| `model <id>` | settings | Switch model mid-session |
| `mode <build|plan>` | settings | Switch agent mode (build or plan) |
| `profiles` | settings | List all profiles |
| `profile <name>` | settings | Switch profile (provider + model) |
| `dry-run on/off` | settings | Toggle dry-run mode |
| `debug on/off` | settings | Toggle debug output |
| `yolo` | settings | Disable safety validation (dangerous!) |
| `themes` | themes | List available themes |
| `theme <name>` | themes | Switch theme |
| `history` | history | List/manage conversation history (list, clear) |
| `compact` | core | Summarize and reset context to free up token budget |
| `clear` | settings | Clear the terminal screen |
| `serve` | serve | Start web UI (serve [--port 8080] [--host 0.0.0.0]) |
| `docker` | docker | Toggle Docker sandbox on/off in current session |
| `schedule` | scheduler | Manage scheduled prompts (add, list, logs, run, remove) |
| `todos` | tools | Show persisted todo list |
| `memory` | memory | View and manage persistent memories (show, add, remove, reset) |
| `mcp` | mcp | MCP server integration (status, servers, tools, add, remove, restart) |
| `websearch config <key>` | websearch | Configure Brave Search API key |
| `telegram` | telegram | Start Telegram bot |

### Free models

If you use OpenRouter, quickly switch to a free model with `--free`:

```bash
shellia --free "explain this error"
```

Shellia fetches the best available free model from OpenRouter and uses it for that command. Requires an OpenRouter profile.

## Docker Sandbox

Run commands inside a Docker container for isolation. The sandbox is opt-in — commands run on the host unless you explicitly use the `docker` subcommand.

### Single command in sandbox

```bash
shellia docker "find all files larger than 100MB"
```

### REPL mode in sandbox

```bash
shellia docker
```

Starts an interactive session where all commands execute inside Docker. The container persists for the session and is cleaned up on exit.

### Toggle in an existing REPL

```bash
shellia
shellia> docker
# (sandbox now active — commands run in Docker)
shellia> docker
# (sandbox stopped — commands run on host again)
```

### Configuration

See [Docker sandbox plugin configuration](#docker-sandbox-plugin-configuration) below for image, mount, and extra args settings.

## Scheduler

Schedule shellia prompts to run automatically at specific times or recurring intervals. Uses `launchd` on macOS and `cron` on Linux.

### Adding a scheduled job

```bash
# Run once at a specific time
shellia schedule add --at "2026-03-20 09:00" --prompt "say hello"

# Run daily
shellia schedule add --every daily --prompt "check disk space"

# Run with a raw cron expression (every Monday at 9am)
shellia schedule add --cron "0 9 * * 1" --prompt "weekly report"

# Force a specific backend
shellia schedule add --at "2026-03-20 09:00" --backend cron --prompt "use cron"
```

The `--prompt` flag must be the last flag — everything after it is treated as the prompt text.

**Schedule presets for `--every`:** `hourly`, `daily`, `weekly`, `monthly`

**Backend resolution:** On macOS, `launchd` is preferred when `launchctl` is available. On Linux (or when `launchctl` is absent), `cron` is used. Use `--backend` to override.

### Managing jobs

```bash
# List all scheduled jobs
shellia schedule list

# View logs for a job
shellia schedule logs <job-id>

# Execute a job immediately (runs the wrapper script)
shellia schedule run <job-id>

# Remove a job (keeps log files for history)
shellia schedule remove <job-id>
```

### REPL usage

All schedule commands work in the REPL:

```bash
shellia
shellia> schedule add --every daily --prompt check disk space
shellia> schedule list
shellia> schedule logs <job-id>
shellia> schedule remove <job-id>
```

### How it works

Each scheduled job creates:
- **Job metadata** (`~/.config/shellia/plugins/scheduler/jobs/<id>.json`) — stores prompt, schedule, backend, and run history
- **Wrapper script** (`~/.config/shellia/plugins/scheduler/bin/<id>.sh`) — self-contained script that invokes shellia, logs output, and updates metadata
- **Backend artifact** — a launchd plist or cron entry that triggers the wrapper at the scheduled time
- **Log file** (`~/.config/shellia/plugins/scheduler/logs/<id>.log`) — timestamped run history with output summaries

Run-once jobs automatically disable themselves after successful execution. Log files are preserved even after job removal.

## Web UI

Shellia can be accessed through a web browser using the built-in serve plugin.

### Starting the web server

```bash
shellia serve
```

This starts an HTTP server on `0.0.0.0:8080` and opens a chat interface in the browser. The web UI provides the same agent capabilities as the CLI — including command execution, multi-step plans, and conversation history.

### Options

```bash
# Custom port
shellia serve --port 3000

# Bind to localhost only
shellia serve --host 127.0.0.1
```

### Configuration

Default settings can be stored in `~/.config/shellia/plugins/serve/config`:

```
port=8080
host=0.0.0.0
```

### Requirements

- `python3` (used as the HTTP server — no pip dependencies needed)
- Python 3 is pre-installed on macOS and most Linux distributions

### Security

By default, the web server binds to `0.0.0.0`, making it accessible from other machines on the network. The web agent has full command execution capabilities. For personal use on untrusted networks, bind to localhost:

```bash
shellia serve --host 127.0.0.1
```

### How it works

The serve plugin (`lib/plugins/serve/`) contains:
- `plugin.sh` — plugin registration and CLI integration
- `server.py` — thin Python HTTP server (~200 lines, stdlib only)
- `index.html` — single-file chat UI (no build step, no npm)

Each chat message spawns a shellia subprocess with session-based conversation history. Responses stream to the browser via Server-Sent Events (SSE).

### Web mode

Shellia also supports a programmatic web mode for integration with external applications:

```bash
# Web mode with session ID
shellia --web-mode --session-id <id> "prompt"
```

This mode returns structured JSON events for tool execution and status updates.

## Memory

Shellia can remember facts across sessions. When the AI learns something useful — your name, project details, preferences, environment info — it can save it to a persistent memory file. Memories are automatically injected into the system prompt so every future session starts with that context.

### How it works

The AI uses two tools to manage memory:

- **`memory_save`** — saves a concise fact (e.g., "User prefers Python 3.11 with type hints")
- **`memory_remove`** — deletes a fact when it becomes outdated or incorrect

Memories are stored in `~/.config/shellia/memory.md` as timestamped bullet points.

### Managing memories in the REPL

```bash
shellia> memory              # Show all memories
shellia> memory add User prefers dark themes
shellia> memory remove User prefers dark themes
shellia> memory reset        # Delete all memories
shellia> memory file         # Show path to memory file
shellia> memory edit         # Open memory file in $EDITOR
```

## MCP Integration

Shellia can connect to [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) servers and expose their tools to the AI. This allows you to extend shellia with any MCP-compatible tool server.

### Configuration

Create a servers file at `~/.config/shellia/plugins/mcp/servers.json`:

```json
{
  "mcpServers": {
    "my-server": {
      "command": "npx",
      "args": ["-y", "@my/mcp-server"]
    }
  }
}
```

Shellia starts a Python bridge process on init that connects to configured MCP servers and registers their tools.

### Managing MCP in the REPL

```bash
shellia> mcp status          # Show bridge status and connected servers
shellia> mcp servers         # List configured MCP servers
shellia> mcp tools           # List available MCP tools
shellia> mcp add <name> <cmd>  # Add an MCP server
shellia> mcp remove <name>   # Remove an MCP server
shellia> mcp restart         # Restart the MCP bridge
shellia> mcp port <number>   # Change the bridge port (default: 7898)
```

### Requirements

- `python3` (for the MCP bridge)
- MCP server packages installed separately per server

## Plugins

Shellia uses a hook-based plugin system. Core functionality like safety checks, themes, settings, and conversation history are implemented as plugins. The plugin system is implemented in `lib/plugins.sh` and is compatible with Bash 3.2+.

### Architecture

The plugin system provides:

- **Plugin discovery** — automatic loading from built-in and user directories
- **Hook dispatch** — event-driven communication between plugins and the core
- **REPL command registration** — plugins add commands to the interactive REPL
- **Tool registration** — plugins can provide AI-callable tools
- **Per-plugin configuration** — key=value config files per plugin

#### Registry

The plugin system maintains two registries:

- `SHELLIA_LOADED_PLUGINS` — indexed array of loaded plugin names, in load order
- `_SHELLIA_HOOK_ENTRIES` — indexed array of `"hook_name:plugin_name"` entries (Bash 3.2-compatible alternative to associative arrays)

#### Loading order

`load_plugins()` loads from two directories in order:

1. **Built-in:** `${SHELLIA_DIR}/lib/plugins/` (ships with shellia)
2. **User:** `${SHELLIA_CONFIG_DIR}/plugins/` (your custom plugins)

If a user plugin has the same name as a built-in plugin, it overrides the built-in: the old plugin's hooks are unregistered, it is removed from the loaded list, and the new plugin takes its place.

#### Plugin formats

Each directory is scanned for two formats:

- **Single file:** `name.sh` — a standalone plugin file
- **Directory:** `name/plugin.sh` — a plugin with supporting files in its own directory

#### Registration (`_register_plugin`)

When a plugin file is sourced, the system validates that two required functions exist:

- `plugin_<name>_info()` — returns a one-line description
- `plugin_<name>_hooks()` — returns a space-separated list of hook names to subscribe to

If either is missing, the plugin is skipped with a warning. If validation passes, the plugin is added to `SHELLIA_LOADED_PLUGINS` and its hook subscriptions are recorded.

### Built-in plugins

| Plugin | Description | Hooks |
|--------|-------------|-------|
| `safety` | Dangerous command detection and confirmation prompts | `init`, `before_tool_call` |
| `docker` | Opt-in Docker sandbox for command execution (`shellia docker`) | (none) |
| `settings` | Runtime settings commands (model, mode, dry-run, debug, profiles, profile, yolo) | (none) |
| `themes` | Theme switching commands (themes, theme) | (none) |
| `history` | Persistent conversation history with session management | `init`, `user_message`, `assistant_message`, `shutdown`, `conversation_reset` |
| `serve` | Web-based chat UI accessible via browser | (none) |
| `scheduler` | Schedule prompt execution at specified times or intervals | (none) |
| `skills` | Claude-compatible agent skill discovery and loading | `init`, `prompt_build` |
| `websearch` | Web search via Brave Search API | `init` |
| `telegram` | Telegram bot interface for chatting with shellia | (none) |
| `memory` | Persistent fact storage across sessions | `init`, `prompt_build` |
| `mcp` | MCP server integration (Model Context Protocol) | `init`, `shutdown` |
| `openrouter` | OpenRouter utilities (`--free` flag) | `init` |

### Listing plugins

```bash
# CLI
shellia plugins

# REPL
shellia> plugins
```

`list_plugins()` displays each loaded plugin's name, description (from `plugin_<name>_info`), and subscribed hooks (from `plugin_<name>_hooks`).

### Creating a plugin

A plugin is either a single file (`name.sh`) or a directory (`name/plugin.sh`). Every plugin must define two functions:

```bash
# ~/.config/shellia/plugins/myplugin.sh

plugin_myplugin_info() { echo "My custom plugin"; }
plugin_myplugin_hooks() { echo "init shutdown"; }

# Hook handlers: plugin_<name>_on_<hook_name>()
plugin_myplugin_on_init() {
    # Called when shellia starts
    :
}

plugin_myplugin_on_shutdown() {
    # Called when shellia exits
    :
}
```

### Hook dispatch

#### `fire_hook(hook_name, args...)`

Calls all subscribed handlers for a hook in load order. Each subscriber's handler function is `plugin_<name>_on_<hook_name>`. Arguments are passed through to every handler. If no plugins subscribe to the hook, it is a no-op (returns 0).

#### `fire_prompt_hook(mode)`

A specialized hook for `prompt_build` that captures stdout from all subscribed handlers and returns the concatenated text. This allows plugins to inject content into the system prompt.

### Available hooks

| Hook | Fired when | Arguments |
|------|-----------|-----------|
| `init` | Shellia starts up | (none) |
| `shutdown` | Shellia exits | (none) |
| `user_message` | User sends a message | message text |
| `assistant_message` | Assistant responds | response text |
| `conversation_reset` | User runs `reset` | (none) |
| `before_api_call` | Before each API request | (none) |
| `after_api_call` | After each API response | (none) |
| `before_tool_call` | Before tool execution | tool name, arguments JSON |
| `after_tool_call` | After tool execution | tool name, result |
| `prompt_build` | Building the system prompt (stdout appended) | mode (`interactive`, `single`, `pipe`) |

### Plugin-provided REPL commands

Plugins can register REPL commands by defining handler and help functions:

```bash
repl_cmd_greet_handler() { echo "Hello, $1!"; }
repl_cmd_greet_help() { echo "  greet <name>  - Greet someone"; }
```

The plugin system discovers commands automatically via `get_plugin_repl_commands()`, which finds all `repl_cmd_*_handler` functions. `dispatch_repl_command(cmd_name, args...)` calls the matching handler. Commands with hyphens are converted to underscores for function lookup (`dry-run` dispatches to `repl_cmd_dry_run_handler`).

`get_plugin_repl_help()` collects help text from all `repl_cmd_*_help` functions.

### Plugin-provided tools

Plugins can define AI-callable tools using the same convention as built-in tools. When the plugin file is sourced, its `tool_*` functions become available to `build_tools_array()` and `dispatch_tool_call()`:

```bash
tool_my_search_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "my_search",
        "description": "Search for something",
        "parameters": {
            "type": "object",
            "properties": {
                "query": { "type": "string", "description": "Search query" }
            },
            "required": ["query"]
        }
    }
}
EOF
}

tool_my_search_execute() {
    local args="$1"
    local query
    query=$(echo "$args" | jq -r '.query')
    echo "Results for: ${query}"
}
```

Each tool needs two functions:
- `tool_<name>_schema()` — returns the JSON tool definition (OpenAI function calling format)
- `tool_<name>_execute(args_json)` — executes the tool and returns the result on stdout

### Built-in tools

Shellia includes several built-in tools that plugins can also extend:

| Tool | Description |
|------|-------------|
| `read_file` | Read a file from the filesystem |
| `write_file` | Write content to a file |
| `edit_file` | Edit a file using search/replace |
| `search_files` | Find files by glob pattern |
| `search_content` | Search file contents with regex |
| `run_command` | Execute a shell command |
| `run_plan` | Execute a multi-step plan |
| `ask_user` | Pause and ask the user for input |
| `todo_write` | Persist task list as markdown |
| `delegate_task` | Delegate a task to a subagent |
| `webfetch` | Fetch web content and convert it to LLM-friendly markdown (supports HTML, PDF, DOCX, PPTX, XLSX via markitdown) |
| `web_search` | Search the web using Brave Search API |
| `memory_save` | Save a fact or preference to persistent memory |
| `memory_remove` | Remove a fact from persistent memory |

Some built-in tools are provided by built-in plugins rather than files under `lib/tools/`. For example, `webfetch`, `web_search`, and memory tools are exposed through the plugin system but appear in the same tool registry at runtime.

### Plugin configuration

Each plugin can have its own config file at `~/.config/shellia/plugins/<name>/config` using key=value format:

```
api_key=secret123
timeout=30
# Comments are supported
```

Plugins read their config with `plugin_config_get`:

```bash
plugin_config_get "plugin_name" "key" "default_value"
```

Returns the value for `key` from the plugin's config file. If the file doesn't exist or the key is missing, returns `default_value`. Blank lines and `#` comments are ignored.

### Overriding built-in plugins

Place a plugin with the same name in `~/.config/shellia/plugins/`. When `load_plugins()` runs, it loads built-in plugins first, then user plugins. If a user plugin matches a built-in name:

1. The built-in plugin's hooks are unregistered
2. The built-in is removed from the loaded list
3. The user plugin is sourced, validated, and registered in its place

This allows you to replace or extend any built-in behavior.

### Docker sandbox plugin configuration

The docker plugin reads optional config from:

`~/.config/shellia/plugins/docker/config`

This file is scaffolded automatically during `shellia init` if it does not exist.

Supported keys:

- `image` (default: `ubuntu:latest`)
- `mount_cwd` (default: `true`)
- `extra_args` (default: empty)

Example:

```ini
image=ubuntu:latest
mount_cwd=true
extra_args=--network none
```

## Safety

Shellia's safety plugin maintains a list of dangerous command patterns at `~/.config/shellia/dangerous_commands`. Any generated command matching these patterns requires explicit confirmation before running. You can edit this file to add or remove patterns.

Default dangerous patterns: `rm`, `sudo`, `mkfs`, `dd`, `fdisk`, `chmod 777`, `chown`, `kill -9`, `reboot`, `shutdown`, `mv /`

### Yolo mode

For advanced users, disable safety validation with the `--yolo` flag or `yolo` REPL command:

```bash
shellia --yolo "rm -rf /tmp/test"
```

**Warning:** This bypasses all safety checks and can cause irreversible damage.

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

### Agent mode

Shellia supports two agent modes that control which tools are available:

- **build** (default): Full tool access including `run_command`, `write_file`, `edit_file`, etc.
- **plan**: Limited to safe tools (`read_file`, `search_files`, `search_content`, `todo_write`, `ask_user`)

Switch modes with the `mode` command:

```bash
shellia
shellia> mode plan
```

Or use the `--mode` flag:

```bash
shellia --mode plan "analyze this project structure"
```

## Configuration

Shellia reads configuration from `~/.config/shellia/config` with environment variable overrides:

| Config key | Env variable | Description |
|------------|-------------|-------------|
| `SHELLIA_PROFILE` | `SHELLIA_PROFILE` | Active profile name (default: "default") |
| `SHELLIA_THEME` | `SHELLIA_THEME` | Color theme (default, ocean, forest, sunset, minimal) |
| `SHELLIA_AGENT_MODE` | `SHELLIA_AGENT_MODE` | Agent mode: build or plan |

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

### Environment variables

| Variable | Description |
|----------|-------------|
| `SHELLIA_API_URL` | API provider URL |
| `SHELLIA_API_KEY` | API key for the provider |
| `SHELLIA_MODEL` | Model ID to use |
| `SHELLIA_PROFILE` | Active profile name |
| `SHELLIA_THEME` | Color theme |
| `SHELLIA_AGENT_MODE` | Agent mode (build/plan) |
| `SHELLIA_DEBUG` | Enable debug output |
| `SHELLIA_DRY_RUN` | Enable dry-run mode |
| `SHELLIA_YOLO_MODE` | Disable safety validation |
| `BRAVE_SEARCH_API_KEY` | Brave Search API key for web search |

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
- `python3` (for `shellia serve`, `shellia telegram`, and MCP bridge — pre-installed on macOS/Linux)
- `docker` (optional, for Docker sandbox functionality)
- `markitdown` (optional, for converting PDF/DOCX/PPTX/XLSX in `webfetch` — `pip install markitdown`)

## License

MIT License — see [LICENSE](LICENSE) for details.

## Contributing

Shellia is actively developed and welcomes contributions! Here's how you can help:

1. **Run tests** — Ensure all tests pass before submitting changes:
   ```bash
   bash tests/run_tests.sh
   ```

2. **Check test coverage** — Add tests for new features or bug fixes

3. **Follow conventions** — Match existing code style and plugin patterns

4. **Test across modes** — Verify REPL, single-prompt, and web modes all work

5. **Update documentation** — Keep the README and docs in sync with changes

### Development setup

```bash
# Clone the repo
git clone https://github.com/FrancoAA/shellia.git
cd shellia

# Run tests
bash tests/run_tests.sh

# Test individual test files
bash tests/run_tests.sh test_api
bash tests/run_tests.sh test_tools
```

### Adding a plugin

See the [Plugins](#plugins) section above for plugin development guidelines.

### Adding a tool

Tools are defined in `lib/tools/`. Each tool needs:
- `tool_<name>_schema()` — returns JSON schema
- `tool_<name>_execute(args_json)` — executes the tool

See existing tools for examples.

## Acknowledgments

- Built with [OpenRouter](https://openrouter.ai/) API support
- Inspired by [Claude's agent capabilities](https://claude.ai/)
- Uses [Brave Search API](https://brave.com/search/api/) for web search

## License

MIT License — see [LICENSE](LICENSE) for details.
