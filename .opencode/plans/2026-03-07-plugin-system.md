# Plugin System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a hook-based plugin architecture that lets plugins extend shellia with hooks, tools, REPL commands, and prompt sections — then extract existing functionality (safety, themes, REPL settings, history) into plugins.

**Architecture:** A plugin is a `.sh` file (or directory with `plugin.sh`) that defines functions following a naming convention. The plugin loader discovers plugins from two directories: built-in (`lib/plugins/`) and user-installed (`~/.config/shellia/plugins/`). Each plugin declares which hooks it subscribes to via a `plugin_<name>_hooks()` function. A central registry (`lib/plugins.sh`) manages discovery, loading, and hook dispatch. Hooks fire sequentially in load order. Plugins can also provide tools (same `tool_*` convention) and REPL commands (via `repl_cmd_*` functions).

**Tech Stack:** Pure bash, jq (for plugin config)

---

## Design Reference

### Hook Points

| Hook | Arguments | When Fired | Example Use |
|------|-----------|------------|-------------|
| `on_init` | (none) | After config loaded, before first API call | Plugin setup, state loading |
| `on_shutdown` | (none) | Before exit | Cleanup, save state |
| `on_prompt_build` | `$1` = mode | During system prompt assembly | Inject context into prompt |
| `on_before_api_call` | `$1` = messages JSON | Before each HTTP request | Logging, token counting |
| `on_after_api_call` | `$1` = response JSON | After each HTTP response | Cost tracking, logging |
| `on_before_tool_call` | `$1` = tool_name, `$2` = args JSON | Before tool dispatch | Audit, approval gates |
| `on_after_tool_call` | `$1` = tool_name, `$2` = result, `$3` = exit_code | After tool returns | Logging, metrics |
| `on_user_message` | `$1` = message text | When user sends message in REPL | Input preprocessing |
| `on_assistant_message` | `$1` = response text | When assistant responds | Output processing |
| `on_conversation_reset` | (none) | When REPL conversation is reset | History export |

### Plugin File Convention

A plugin is either:
- A single file: `<plugin_name>.sh`
- A directory: `<plugin_name>/plugin.sh`

Each plugin defines these functions (all prefixed with `plugin_<name>_`):

```bash
# Required: metadata
plugin_<name>_info()      # Echoes: "description text" (one-liner)

# Required: hook list
plugin_<name>_hooks()     # Echoes space-separated hook names this plugin subscribes to

# Optional: hook handlers (one per hook the plugin subscribes to)
plugin_<name>_on_init()
plugin_<name>_on_shutdown()
plugin_<name>_on_prompt_build()    # Echoes text to append to system prompt
plugin_<name>_on_before_tool_call()
plugin_<name>_on_after_tool_call()
plugin_<name>_on_before_api_call()
plugin_<name>_on_after_api_call()
plugin_<name>_on_user_message()
plugin_<name>_on_assistant_message()
plugin_<name>_on_conversation_reset()

# Optional: tools (same convention as lib/tools/*.sh)
tool_<toolname>_schema()
tool_<toolname>_execute()

# Optional: REPL commands
repl_cmd_<cmdname>_handler()    # Args: $1 = full input after command name
repl_cmd_<cmdname>_help()       # Echoes: "command   description" for help display
```

### Plugin Config

Per-plugin config lives at `~/.config/shellia/plugins/<name>/config` (key=value format, same as shellia's main config). Plugins access their config via a helper function `plugin_config_get <plugin_name> <key> [default]`.

### Plugin Directories

- **Built-in:** `${SHELLIA_DIR}/lib/plugins/` — ships with shellia, extracted core functionality
- **User:** `${SHELLIA_CONFIG_DIR}/plugins/` — user-installed or custom plugins

Built-in plugins load first, then user plugins. User plugins can override built-in ones with the same name.

---

## Phase 1: Plugin Framework

### Task 1: Create plugin registry and loader (`lib/plugins.sh`)

**Files:**
- Create: `lib/plugins.sh`
- Create: `tests/test_plugins.sh`

**Step 1: Write the test file for plugin system**

Create `tests/test_plugins.sh`:

```bash
#!/usr/bin/env bash
# Tests for lib/plugins.sh

test_load_plugins_from_directory() {
    # Create a temp plugin directory with a test plugin
    local plugin_dir="${TEST_TMP_DIR}/plugins"
    mkdir -p "$plugin_dir"
    cat > "${plugin_dir}/hello.sh" <<'PLUGIN'
plugin_hello_info() { echo "A test plugin"; }
plugin_hello_hooks() { echo "on_init"; }
plugin_hello_on_init() { echo "hello_init_called"; }
PLUGIN

    # Load plugins from directory
    _load_plugins_from_dir "$plugin_dir"
    assert_contains "${SHELLIA_LOADED_PLUGINS[*]}" "hello" "hello plugin should be loaded"
}

test_load_plugins_directory_format() {
    # Plugin as directory with plugin.sh inside
    local plugin_dir="${TEST_TMP_DIR}/plugins"
    mkdir -p "${plugin_dir}/myplug"
    cat > "${plugin_dir}/myplug/plugin.sh" <<'PLUGIN'
plugin_myplug_info() { echo "Directory plugin"; }
plugin_myplug_hooks() { echo "on_init"; }
plugin_myplug_on_init() { echo "myplug_init"; }
PLUGIN

    _load_plugins_from_dir "$plugin_dir"
    assert_contains "${SHELLIA_LOADED_PLUGINS[*]}" "myplug" "myplug should be loaded"
}

test_fire_hook_calls_all_subscribers() {
    # Register two plugins that subscribe to the same hook
    local plugin_dir="${TEST_TMP_DIR}/plugins"
    mkdir -p "$plugin_dir"

    cat > "${plugin_dir}/alpha.sh" <<'PLUGIN'
plugin_alpha_info() { echo "Alpha plugin"; }
plugin_alpha_hooks() { echo "on_init"; }
plugin_alpha_on_init() { echo "alpha" >> "${TEST_TMP_DIR}/hook_output"; }
PLUGIN

    cat > "${plugin_dir}/beta.sh" <<'PLUGIN'
plugin_beta_info() { echo "Beta plugin"; }
plugin_beta_hooks() { echo "on_init"; }
plugin_beta_on_init() { echo "beta" >> "${TEST_TMP_DIR}/hook_output"; }
PLUGIN

    _load_plugins_from_dir "$plugin_dir"
    fire_hook "on_init"

    local output
    output=$(cat "${TEST_TMP_DIR}/hook_output")
    assert_contains "$output" "alpha" "alpha hook should have fired"
    assert_contains "$output" "beta" "beta hook should have fired"
}

test_fire_hook_no_subscribers_is_noop() {
    SHELLIA_LOADED_PLUGINS=()
    SHELLIA_PLUGIN_HOOKS=()
    # Should not error
    fire_hook "on_shutdown"
    assert_eq $? 0 "fire_hook with no subscribers should succeed"
}

test_fire_hook_passes_arguments() {
    local plugin_dir="${TEST_TMP_DIR}/plugins"
    mkdir -p "$plugin_dir"

    cat > "${plugin_dir}/argtest.sh" <<'PLUGIN'
plugin_argtest_info() { echo "Arg test"; }
plugin_argtest_hooks() { echo "on_before_tool_call"; }
plugin_argtest_on_before_tool_call() {
    echo "$1|$2" >> "${TEST_TMP_DIR}/hook_args"
}
PLUGIN

    _load_plugins_from_dir "$plugin_dir"
    fire_hook "on_before_tool_call" "run_command" '{"command":"ls"}'

    local output
    output=$(cat "${TEST_TMP_DIR}/hook_args")
    assert_eq "$output" 'run_command|{"command":"ls"}' "hook should receive arguments"
}

test_plugin_config_get() {
    local config_dir="${TEST_TMP_DIR}/config/plugins/testplug"
    mkdir -p "$config_dir"
    cat > "${config_dir}/config" <<'EOF'
MY_SETTING=hello
OTHER=world
EOF

    # Override config dir for test
    local old_config_dir="$SHELLIA_CONFIG_DIR"
    SHELLIA_CONFIG_DIR="${TEST_TMP_DIR}/config"

    local val
    val=$(plugin_config_get "testplug" "MY_SETTING")
    assert_eq "$val" "hello" "should read plugin config value"

    local default_val
    default_val=$(plugin_config_get "testplug" "MISSING" "fallback")
    assert_eq "$default_val" "fallback" "should return default for missing key"

    SHELLIA_CONFIG_DIR="$old_config_dir"
}

test_list_plugins_shows_loaded() {
    local plugin_dir="${TEST_TMP_DIR}/plugins"
    mkdir -p "$plugin_dir"
    cat > "${plugin_dir}/demo.sh" <<'PLUGIN'
plugin_demo_info() { echo "Demo plugin"; }
plugin_demo_hooks() { echo "on_init"; }
plugin_demo_on_init() { :; }
PLUGIN

    _load_plugins_from_dir "$plugin_dir"
    local output
    output=$(list_plugins)
    assert_contains "$output" "demo" "list should show demo plugin"
    assert_contains "$output" "Demo plugin" "list should show description"
}

test_user_plugin_overrides_builtin() {
    # Create builtin and user dirs with same plugin name
    local builtin_dir="${TEST_TMP_DIR}/builtin_plugins"
    local user_dir="${TEST_TMP_DIR}/user_plugins"
    mkdir -p "$builtin_dir" "$user_dir"

    cat > "${builtin_dir}/conflict.sh" <<'PLUGIN'
plugin_conflict_info() { echo "Builtin version"; }
plugin_conflict_hooks() { echo "on_init"; }
plugin_conflict_on_init() { echo "builtin" >> "${TEST_TMP_DIR}/override_test"; }
PLUGIN

    cat > "${user_dir}/conflict.sh" <<'PLUGIN'
plugin_conflict_info() { echo "User version"; }
plugin_conflict_hooks() { echo "on_init"; }
plugin_conflict_on_init() { echo "user" >> "${TEST_TMP_DIR}/override_test"; }
PLUGIN

    _load_plugins_from_dir "$builtin_dir"
    _load_plugins_from_dir "$user_dir"
    fire_hook "on_init"

    local output
    output=$(cat "${TEST_TMP_DIR}/override_test")
    # User plugin should override builtin (only "user" in output, not "builtin")
    assert_eq "$output" "user" "user plugin should override builtin"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL (functions not defined)

**Step 3: Write the plugin system implementation**

Create `lib/plugins.sh`:

```bash
#!/usr/bin/env bash
# Plugin system: discovery, loading, hook dispatch, config

# Registry arrays
SHELLIA_LOADED_PLUGINS=()
# Associative array: hook_name -> space-separated list of plugin names
declare -A SHELLIA_PLUGIN_HOOKS

# Load plugins from both built-in and user directories
load_plugins() {
    local builtin_dir="${SHELLIA_DIR}/lib/plugins"
    local user_dir="${SHELLIA_CONFIG_DIR}/plugins"

    # Built-in first
    if [[ -d "$builtin_dir" ]]; then
        _load_plugins_from_dir "$builtin_dir"
    fi

    # User plugins (can override built-in)
    if [[ -d "$user_dir" ]]; then
        _load_plugins_from_dir "$user_dir"
    fi

    debug_log "plugins" "loaded ${#SHELLIA_LOADED_PLUGINS[@]} plugin(s): ${SHELLIA_LOADED_PLUGINS[*]:-none}"
}

# Load all plugins from a directory
# Supports both single-file (name.sh) and directory (name/plugin.sh) formats
_load_plugins_from_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0

    # Single-file plugins: *.sh
    for plugin_file in "${dir}"/*.sh; do
        [[ -f "$plugin_file" ]] || continue
        local name
        name=$(basename "$plugin_file" .sh)
        _register_plugin "$name" "$plugin_file"
    done

    # Directory plugins: */plugin.sh
    for plugin_dir in "${dir}"/*/; do
        [[ -d "$plugin_dir" ]] || continue
        local plugin_file="${plugin_dir}plugin.sh"
        [[ -f "$plugin_file" ]] || continue
        local name
        name=$(basename "$plugin_dir")
        _register_plugin "$name" "$plugin_file"
    done
}

# Register a single plugin by name and file path
# If a plugin with the same name is already loaded, it gets overridden
_register_plugin() {
    local name="$1"
    local file="$2"

    # If already loaded, unregister old hooks first
    if _plugin_is_loaded "$name"; then
        _unregister_plugin_hooks "$name"
        # Remove from loaded list
        local new_list=()
        for p in "${SHELLIA_LOADED_PLUGINS[@]}"; do
            [[ "$p" != "$name" ]] && new_list+=("$p")
        done
        SHELLIA_LOADED_PLUGINS=("${new_list[@]}")
        debug_log "plugins" "overriding plugin: ${name}"
    fi

    # Source the plugin file
    source "$file"

    # Verify required functions exist
    if ! declare -F "plugin_${name}_info" >/dev/null 2>&1; then
        log_warn "Plugin '${name}' missing plugin_${name}_info(), skipping."
        return 1
    fi
    if ! declare -F "plugin_${name}_hooks" >/dev/null 2>&1; then
        log_warn "Plugin '${name}' missing plugin_${name}_hooks(), skipping."
        return 1
    fi

    # Register in loaded list
    SHELLIA_LOADED_PLUGINS+=("$name")

    # Register hook subscriptions
    local hooks
    hooks=$("plugin_${name}_hooks")
    for hook in $hooks; do
        if [[ -n "${SHELLIA_PLUGIN_HOOKS[$hook]:-}" ]]; then
            SHELLIA_PLUGIN_HOOKS[$hook]="${SHELLIA_PLUGIN_HOOKS[$hook]} ${name}"
        else
            SHELLIA_PLUGIN_HOOKS[$hook]="$name"
        fi
    done

    debug_log "plugins" "registered: ${name} (hooks: ${hooks})"
}

# Check if a plugin is already loaded
_plugin_is_loaded() {
    local name="$1"
    for p in "${SHELLIA_LOADED_PLUGINS[@]+"${SHELLIA_LOADED_PLUGINS[@]}"}"; do
        [[ "$p" == "$name" ]] && return 0
    done
    return 1
}

# Remove a plugin's hooks from the registry
_unregister_plugin_hooks() {
    local name="$1"
    for hook in "${!SHELLIA_PLUGIN_HOOKS[@]}"; do
        local new_list=""
        for p in ${SHELLIA_PLUGIN_HOOKS[$hook]}; do
            [[ "$p" != "$name" ]] && new_list="${new_list} ${p}"
        done
        new_list="${new_list# }"  # trim leading space
        if [[ -z "$new_list" ]]; then
            unset "SHELLIA_PLUGIN_HOOKS[$hook]"
        else
            SHELLIA_PLUGIN_HOOKS[$hook]="$new_list"
        fi
    done
}

# Fire a hook — calls all subscribed plugin handlers in load order
# Args: $1 = hook name, $2..N = arguments passed to handlers
fire_hook() {
    local hook="$1"
    shift
    local subscribers="${SHELLIA_PLUGIN_HOOKS[$hook]:-}"
    [[ -z "$subscribers" ]] && return 0

    for plugin_name in $subscribers; do
        local func="plugin_${plugin_name}_${hook}"
        if declare -F "$func" >/dev/null 2>&1; then
            debug_log "plugins" "firing ${hook} -> ${plugin_name}"
            "$func" "$@"
        fi
    done
}

# Fire on_prompt_build hook — collects output from all subscribers
# Returns: concatenated prompt additions on stdout
fire_prompt_hook() {
    local mode="$1"
    local additions=""
    local subscribers="${SHELLIA_PLUGIN_HOOKS[on_prompt_build]:-}"
    [[ -z "$subscribers" ]] && return 0

    for plugin_name in $subscribers; do
        local func="plugin_${plugin_name}_on_prompt_build"
        if declare -F "$func" >/dev/null 2>&1; then
            local output
            output=$("$func" "$mode")
            if [[ -n "$output" ]]; then
                additions="${additions}
${output}"
            fi
        fi
    done

    echo "$additions"
}

# Read a plugin's config value
# Args: $1 = plugin name, $2 = key, $3 = default value (optional)
plugin_config_get() {
    local plugin_name="$1"
    local key="$2"
    local default="${3:-}"
    local config_file="${SHELLIA_CONFIG_DIR}/plugins/${plugin_name}/config"

    if [[ -f "$config_file" ]]; then
        local value
        value=$(grep "^${key}=" "$config_file" 2>/dev/null | head -1 | cut -d'=' -f2-)
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    fi

    echo "$default"
}

# List all loaded plugins
list_plugins() {
    if [[ ${#SHELLIA_LOADED_PLUGINS[@]} -eq 0 ]]; then
        echo "No plugins loaded."
        return 0
    fi

    echo "Loaded plugins:"
    for name in "${SHELLIA_LOADED_PLUGINS[@]}"; do
        local info
        info=$("plugin_${name}_info" 2>/dev/null || echo "no description")
        local hooks
        hooks=$("plugin_${name}_hooks" 2>/dev/null || echo "none")
        echo -e "  ${THEME_ACCENT}${name}${NC} - ${info}"
        echo -e "    hooks: ${THEME_MUTED}${hooks}${NC}"
    done
}

# Collect REPL commands registered by plugins
# Returns lines of "command_name" for dispatch
get_plugin_repl_commands() {
    declare -F | awk '{print $3}' | grep '^repl_cmd_.*_handler$' | sed 's/^repl_cmd_//;s/_handler$//' | sort
}

# Dispatch a plugin REPL command
# Args: $1 = command name, $2 = rest of input
dispatch_repl_command() {
    local cmd_name="$1"
    local args="$2"
    # Convert hyphens to underscores for function name lookup
    local func_name="repl_cmd_${cmd_name//-/_}_handler"

    if declare -F "$func_name" >/dev/null 2>&1; then
        "$func_name" "$args"
        return 0
    fi
    return 1
}

# Get help text for all plugin REPL commands
get_plugin_repl_help() {
    local cmds
    cmds=$(get_plugin_repl_commands)
    [[ -z "$cmds" ]] && return 0

    for cmd in $cmds; do
        local help_func="repl_cmd_${cmd}_help"
        if declare -F "$help_func" >/dev/null 2>&1; then
            "$help_func"
        else
            echo -e "  ${THEME_ACCENT}${cmd}${NC}"
        fi
    done
}
```

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/plugins.sh tests/test_plugins.sh
git commit -m "feat: add plugin system with hook dispatch, config, and REPL command support"
```

---

### Task 2: Wire plugin system into the entrypoint and lifecycle

**Files:**
- Modify: `shellia` (entrypoint)
- Modify: `lib/repl.sh`
- Modify: `lib/api.sh`
- Modify: `lib/prompt.sh`

**Step 1: Update entrypoint to source and initialize plugins**

In `shellia`, add after sourcing `lib/tools.sh` (line 15):
```bash
source "${SHELLIA_DIR}/lib/plugins.sh"
```

In both dispatch sections (single-prompt around line 156 and REPL around line 180), after `load_tools`, add:
```bash
load_plugins
fire_hook "on_init"
```

**Step 2: Update `lib/prompt.sh` — fire `on_prompt_build` hook**

In `build_system_prompt()`, after the user preferences block (after line 33), add:

```bash
# Append plugin prompt additions
local plugin_additions
plugin_additions=$(fire_prompt_hook "$mode")
if [[ -n "$plugin_additions" ]]; then
    base_prompt="${base_prompt}
${plugin_additions}"
fi
```

**Step 3: Update `lib/api.sh` — fire API and tool hooks**

In `api_chat()`, before the curl call (around line 58), add:
```bash
fire_hook "on_before_api_call" "$messages"
```

After successful response parsing (around line 125, before `echo "$message"`), add:
```bash
fire_hook "on_after_api_call" "$message"
```

In `api_chat_loop()`, wrap the tool dispatch (around lines 190-201):
```bash
# Before dispatch
fire_hook "on_before_tool_call" "$tool_name" "$tool_args"

# Check if a plugin blocked the tool
if [[ "${SHELLIA_TOOL_BLOCKED:-false}" == "true" ]]; then
    SHELLIA_TOOL_BLOCKED=false
    tool_result="Command blocked by plugin policy."
    tool_exit=0
else
    tool_result=$(dispatch_tool_call "$tool_name" "$tool_args") || tool_exit=$?
    fire_hook "on_after_tool_call" "$tool_name" "${tool_result:-}" "$tool_exit"
fi
```

**Step 4: Update `lib/repl.sh` — fire message hooks, plugin command dispatch, shutdown**

Strip the REPL's `case` statement to only keep core commands: `help`, `reset`, `exit|quit`, `plugins`. Remove all other cases (`model`, `dry-run`, `debug`, `themes`, `theme`, `profiles`, `profile`).

After the `esac`, before building messages for the API, add plugin command dispatch:
```bash
# Try plugin REPL commands
local cmd_word="${input%% *}"
local cmd_args="${input#* }"
[[ "$cmd_word" == "$input" ]] && cmd_args=""
if dispatch_repl_command "$cmd_word" "$cmd_args" 2>/dev/null; then
    continue
fi
```

Fire `on_user_message` before building messages:
```bash
fire_hook "on_user_message" "$user_message"
```

Fire `on_assistant_message` after getting the response:
```bash
fire_hook "on_assistant_message" "$response"
```

Fire `on_conversation_reset` in the reset case:
```bash
reset)
    echo '[]' > "$conv_file"
    fire_hook "on_conversation_reset"
    log_info "Conversation cleared."
    continue
    ;;
```

Fire `on_shutdown` on exit:
```bash
exit|quit)
    fire_hook "on_shutdown"
    log_info "Goodbye."
    break
    ;;
```

Also fire `on_shutdown` on Ctrl+D:
```bash
if ! read -rep "..." input; then
    echo ""
    fire_hook "on_shutdown"
    log_info "Goodbye."
    break
fi
```

Update `repl_help()`:
```bash
repl_help() {
    echo -e "${THEME_HEADER}Built-in commands:${NC}"
    echo -e "  ${THEME_ACCENT}help${NC}              Show this help"
    echo -e "  ${THEME_ACCENT}reset${NC}             Clear conversation history"
    echo -e "  ${THEME_ACCENT}plugins${NC}           List loaded plugins"
    echo -e "  ${THEME_ACCENT}exit${NC} / ${THEME_ACCENT}quit${NC}       Exit shellia"

    local plugin_help
    plugin_help=$(get_plugin_repl_help)
    if [[ -n "$plugin_help" ]]; then
        echo ""
        echo -e "${THEME_HEADER}Plugin commands:${NC}"
        echo "$plugin_help"
    fi
}
```

**Step 5: Run full test suite**

Run: `bash tests/run_tests.sh`
Expected: Some REPL tests may need updating for removed commands. Fix as needed.

**Step 6: Commit**

```bash
git add shellia lib/plugins.sh lib/repl.sh lib/api.sh lib/prompt.sh
git commit -m "feat: wire plugin system into agent lifecycle with hooks"
```

---

### Task 3: Add `plugins` CLI subcommand

**Files:**
- Modify: `shellia` (entrypoint)

**Step 1: Add `plugins` CLI subcommand**

In `shellia`, after the `profiles` subcommand block (around line 37), add:
```bash
if [[ "${1:-}" == "plugins" ]]; then
    load_config
    apply_theme "${SHELLIA_THEME:-default}"
    load_tools
    load_plugins
    list_plugins
    exit 0
fi
```

**Step 2: Update `--help` output**

Add to the Options section:
```
  plugins                   List loaded plugins
```

**Step 3: Commit**

```bash
git add shellia
git commit -m "feat: add plugins CLI subcommand"
```

---

## Phase 2: Extract Existing Functionality Into Plugins

### Task 4: Extract safety checks into `safety` plugin

**Files:**
- Create: `lib/plugins/safety/plugin.sh`
- Modify: `lib/tools/run_command.sh` — remove inline safety check
- Modify: `shellia` — remove `load_dangerous_commands` calls

**Step 1: Create the safety plugin**

Create `lib/plugins/safety/plugin.sh`:

```bash
#!/usr/bin/env bash
# Plugin: safety — dangerous command detection and confirmation

plugin_safety_info() {
    echo "Dangerous command detection and confirmation prompts"
}

plugin_safety_hooks() {
    echo "on_init on_before_tool_call"
}

plugin_safety_on_init() {
    load_dangerous_commands
    debug_log "plugin:safety" "loaded ${#DANGEROUS_PATTERNS[@]} dangerous patterns"
}

plugin_safety_on_before_tool_call() {
    local tool_name="$1"
    local tool_args="$2"

    # Only check command-executing tools
    case "$tool_name" in
        run_command)
            local cmd
            cmd=$(echo "$tool_args" | jq -r '.command' 2>/dev/null)
            [[ -z "$cmd" ]] && return 0
            _safety_check_command "$cmd"
            ;;
        run_plan)
            local steps
            steps=$(echo "$tool_args" | jq -r '.steps[].command' 2>/dev/null)
            while IFS= read -r cmd; do
                [[ -z "$cmd" ]] && continue
                _safety_check_command "$cmd"
            done <<< "$steps"
            ;;
    esac
}

_safety_check_command() {
    local cmd="$1"
    if is_dangerous "$cmd"; then
        debug_log "plugin:safety" "dangerous pattern matched: ${cmd}"
        echo -e "${THEME_WARN}Warning: '${cmd}' matches a dangerous pattern.${NC}" >&2
        read -rp "Run this? [y/N]: " confirm </dev/tty
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_warn "Command blocked by safety plugin." >&2
            SHELLIA_TOOL_BLOCKED=true
            return 0
        fi
    fi
}
```

**Step 2: Remove inline safety check from `run_command.sh`**

In `tool_run_command_execute()`, remove the safety check block (lines 42-51 in current file):
```bash
    # Safety check (REMOVE THIS BLOCK)
    if is_dangerous "$cmd"; then
        ...
    fi
```

**Step 3: Remove `load_dangerous_commands` calls from entrypoint**

In `shellia`, remove `load_dangerous_commands` from both dispatch paths (lines 156 and 180).

**Step 4: Run tests**

Run: `bash tests/run_tests.sh`
Expected: PASS

**Step 5: Commit**

```bash
git add lib/plugins/safety/ lib/tools/run_command.sh shellia
git commit -m "refactor: extract safety checks into safety plugin"
```

---

### Task 5: Extract theme REPL commands into `themes` plugin

**Files:**
- Create: `lib/plugins/themes/plugin.sh`

The `lib/themes.sh` file stays as-is (core library). The plugin only adds REPL commands.

**Step 1: Create the themes plugin**

Create `lib/plugins/themes/plugin.sh`:

```bash
#!/usr/bin/env bash
# Plugin: themes — theme switching REPL commands

plugin_themes_info() {
    echo "Theme switching commands (themes, theme <name>)"
}

plugin_themes_hooks() {
    echo ""
}

# REPL command: themes — list available themes
repl_cmd_themes_handler() {
    list_themes
}

repl_cmd_themes_help() {
    echo -e "  ${THEME_ACCENT}themes${NC}            List available themes"
}

# REPL command: theme — switch theme
repl_cmd_theme_handler() {
    local new_theme="$1"
    if [[ -z "$new_theme" ]]; then
        log_warn "Usage: theme <name>"
        return 1
    fi
    SHELLIA_THEME="$new_theme"
    apply_theme "$new_theme"
    log_info "Switched to theme: ${new_theme}"
}

repl_cmd_theme_help() {
    echo -e "  ${THEME_ACCENT}theme ${THEME_MUTED}<name>${NC}      Switch theme"
}
```

**Step 2: Commit**

```bash
git add lib/plugins/themes/
git commit -m "refactor: extract theme REPL commands into themes plugin"
```

---

### Task 6: Extract settings REPL commands into `settings` plugin

**Files:**
- Create: `lib/plugins/settings/plugin.sh`

**Step 1: Create the settings plugin**

Create `lib/plugins/settings/plugin.sh`:

```bash
#!/usr/bin/env bash
# Plugin: settings — runtime settings REPL commands

plugin_settings_info() {
    echo "Runtime settings commands (model, dry-run, debug, profiles, profile)"
}

plugin_settings_hooks() {
    echo ""
}

# REPL command: model
repl_cmd_model_handler() {
    local new_model="$1"
    if [[ -z "$new_model" ]]; then
        log_info "Current model: ${SHELLIA_MODEL}"
        return 0
    fi
    SHELLIA_MODEL="$new_model"
    log_info "Switched to model: ${SHELLIA_MODEL}"
}

repl_cmd_model_help() {
    echo -e "  ${THEME_ACCENT}model ${THEME_MUTED}<id>${NC}        Switch model (or show current)"
}

# REPL command: dry-run (dispatched as dry_run)
repl_cmd_dry_run_handler() {
    local arg="$1"
    case "$arg" in
        on)
            SHELLIA_DRY_RUN=true
            log_info "Dry-run mode enabled."
            ;;
        off)
            SHELLIA_DRY_RUN=false
            log_info "Dry-run mode disabled."
            ;;
        *)
            log_info "Dry-run mode: ${SHELLIA_DRY_RUN}"
            ;;
    esac
}

repl_cmd_dry_run_help() {
    echo -e "  ${THEME_ACCENT}dry-run ${THEME_MUTED}on/off${NC}    Toggle dry-run mode"
}

# REPL command: debug
repl_cmd_debug_handler() {
    local arg="$1"
    case "$arg" in
        on)
            SHELLIA_DEBUG=true
            log_info "Debug mode enabled."
            ;;
        off)
            SHELLIA_DEBUG=false
            log_info "Debug mode disabled."
            ;;
        *)
            log_info "Debug mode: ${SHELLIA_DEBUG}"
            ;;
    esac
}

repl_cmd_debug_help() {
    echo -e "  ${THEME_ACCENT}debug ${THEME_MUTED}on/off${NC}      Toggle debug mode"
}

# REPL command: profiles
repl_cmd_profiles_handler() {
    list_profiles
}

repl_cmd_profiles_help() {
    echo -e "  ${THEME_ACCENT}profiles${NC}          List all profiles"
}

# REPL command: profile
repl_cmd_profile_handler() {
    local new_profile="$1"
    if [[ -z "$new_profile" ]]; then
        log_info "Current profile: ${SHELLIA_PROFILE:-default}"
        return 0
    fi
    if load_profile "$new_profile"; then
        log_info "Switched to profile: ${SHELLIA_PROFILE} (model: ${SHELLIA_MODEL})"
    fi
}

repl_cmd_profile_help() {
    echo -e "  ${THEME_ACCENT}profile ${THEME_MUTED}<name>${NC}    Switch profile (provider + model)"
}
```

**Step 2: Commit**

```bash
git add lib/plugins/settings/
git commit -m "refactor: extract settings REPL commands into settings plugin"
```

---

### Task 7: Create `history` plugin for conversation persistence

**Files:**
- Create: `lib/plugins/history/plugin.sh`

**Step 1: Create the history plugin**

Create `lib/plugins/history/plugin.sh`:

```bash
#!/usr/bin/env bash
# Plugin: history — persistent conversation history

SHELLIA_HISTORY_DIR=""
SHELLIA_HISTORY_SESSION_FILE=""

plugin_history_info() {
    echo "Persistent conversation history with session export"
}

plugin_history_hooks() {
    echo "on_init on_user_message on_assistant_message on_shutdown on_conversation_reset"
}

plugin_history_on_init() {
    SHELLIA_HISTORY_DIR="${SHELLIA_CONFIG_DIR}/history"
    mkdir -p "$SHELLIA_HISTORY_DIR"

    # Start a new session file
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    SHELLIA_HISTORY_SESSION_FILE="${SHELLIA_HISTORY_DIR}/session_${timestamp}.jsonl"
    debug_log "plugin:history" "session file: ${SHELLIA_HISTORY_SESSION_FILE}"
}

plugin_history_on_user_message() {
    local message="$1"
    [[ -z "$SHELLIA_HISTORY_SESSION_FILE" ]] && return 0
    local entry
    entry=$(jq -nc --arg role "user" --arg content "$message" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{timestamp: $ts, role: $role, content: $content}')
    echo "$entry" >> "$SHELLIA_HISTORY_SESSION_FILE"
}

plugin_history_on_assistant_message() {
    local message="$1"
    [[ -z "$SHELLIA_HISTORY_SESSION_FILE" ]] && return 0
    [[ -z "$message" ]] && return 0
    local entry
    entry=$(jq -nc --arg role "assistant" --arg content "$message" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{timestamp: $ts, role: $role, content: $content}')
    echo "$entry" >> "$SHELLIA_HISTORY_SESSION_FILE"
}

plugin_history_on_shutdown() {
    # Remove empty session files
    if [[ -n "$SHELLIA_HISTORY_SESSION_FILE" && -f "$SHELLIA_HISTORY_SESSION_FILE" ]]; then
        if [[ ! -s "$SHELLIA_HISTORY_SESSION_FILE" ]]; then
            rm -f "$SHELLIA_HISTORY_SESSION_FILE"
            debug_log "plugin:history" "removed empty session file"
        else
            debug_log "plugin:history" "session saved: ${SHELLIA_HISTORY_SESSION_FILE}"
        fi
    fi
}

plugin_history_on_conversation_reset() {
    # Start a new session file on reset
    if [[ -n "$SHELLIA_HISTORY_DIR" ]]; then
        local timestamp
        timestamp=$(date +%Y%m%d_%H%M%S)
        SHELLIA_HISTORY_SESSION_FILE="${SHELLIA_HISTORY_DIR}/session_${timestamp}.jsonl"
        debug_log "plugin:history" "new session after reset: ${SHELLIA_HISTORY_SESSION_FILE}"
    fi
}

# REPL command: history
repl_cmd_history_handler() {
    local subcmd="$1"
    case "$subcmd" in
        list|"")
            _history_list_sessions
            ;;
        clear)
            _history_clear
            ;;
        *)
            log_warn "Usage: history [list|clear]"
            ;;
    esac
}

repl_cmd_history_help() {
    echo -e "  ${THEME_ACCENT}history${NC}           List/manage conversation history"
}

_history_list_sessions() {
    if [[ ! -d "$SHELLIA_HISTORY_DIR" ]]; then
        echo "No history directory found."
        return 0
    fi

    local count=0
    for f in "${SHELLIA_HISTORY_DIR}"/session_*.jsonl; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f" .jsonl)
        local lines
        lines=$(wc -l < "$f" | tr -d ' ')
        local size
        size=$(wc -c < "$f" | tr -d ' ')
        echo -e "  ${THEME_ACCENT}${name}${NC}  (${lines} messages, ${size} bytes)"
        ((count++))
    done

    if [[ $count -eq 0 ]]; then
        echo "No history sessions found."
    else
        echo ""
        echo "${count} session(s) total."
    fi
}

_history_clear() {
    if [[ -d "$SHELLIA_HISTORY_DIR" ]]; then
        local count
        count=$(find "$SHELLIA_HISTORY_DIR" -name "session_*.jsonl" | wc -l | tr -d ' ')
        rm -f "${SHELLIA_HISTORY_DIR}"/session_*.jsonl
        log_info "Cleared ${count} session(s)."
    fi
}
```

**Step 2: Commit**

```bash
git add lib/plugins/history/
git commit -m "feat: add history plugin for persistent conversation sessions"
```

---

### Task 8: Clean up `executor.sh` dead code

**Files:**
- Modify: `lib/executor.sh`
- Modify: `tests/test_executor.sh`

**Step 1: Remove dead functions from executor.sh**

Remove `execute_command()` (lines 30-70) and `execute_plan()` (lines 72-143). Keep only `load_dangerous_commands()` and `is_dangerous()`.

**Step 2: Update tests**

In `tests/test_executor.sh`, remove any tests for `execute_command` and `execute_plan`. Keep tests for `load_dangerous_commands` and `is_dangerous`.

**Step 3: Run tests**

Run: `bash tests/run_tests.sh`
Expected: PASS

**Step 4: Commit**

```bash
git add lib/executor.sh tests/test_executor.sh
git commit -m "refactor: remove dead execute_command/execute_plan from executor.sh"
```

---

## Phase 3: Testing and Polish

### Task 9: Write integration tests for plugin lifecycle

**Files:**
- Modify: `tests/test_plugins.sh`

**Step 1: Add integration tests to test_plugins.sh**

```bash
test_full_plugin_lifecycle() {
    local plugin_dir="${TEST_TMP_DIR}/plugins"
    mkdir -p "$plugin_dir"

    cat > "${plugin_dir}/lifecycle.sh" <<'PLUGIN'
LIFECYCLE_LOG=""
plugin_lifecycle_info() { echo "Lifecycle tracker"; }
plugin_lifecycle_hooks() { echo "on_init on_shutdown on_user_message on_assistant_message on_conversation_reset"; }
plugin_lifecycle_on_init() { LIFECYCLE_LOG="${LIFECYCLE_LOG}init,"; }
plugin_lifecycle_on_shutdown() { LIFECYCLE_LOG="${LIFECYCLE_LOG}shutdown,"; }
plugin_lifecycle_on_user_message() { LIFECYCLE_LOG="${LIFECYCLE_LOG}user:$1,"; }
plugin_lifecycle_on_assistant_message() { LIFECYCLE_LOG="${LIFECYCLE_LOG}assistant:$1,"; }
plugin_lifecycle_on_conversation_reset() { LIFECYCLE_LOG="${LIFECYCLE_LOG}reset,"; }
PLUGIN

    _load_plugins_from_dir "$plugin_dir"

    fire_hook "on_init"
    fire_hook "on_user_message" "hello"
    fire_hook "on_assistant_message" "hi there"
    fire_hook "on_conversation_reset"
    fire_hook "on_shutdown"

    assert_eq "$LIFECYCLE_LOG" "init,user:hello,assistant:hi there,reset,shutdown," \
        "all lifecycle hooks should fire in order"
}

test_plugin_repl_command_dispatch() {
    local plugin_dir="${TEST_TMP_DIR}/plugins"
    mkdir -p "$plugin_dir"

    cat > "${plugin_dir}/greeter.sh" <<'PLUGIN'
plugin_greeter_info() { echo "Greeter"; }
plugin_greeter_hooks() { echo ""; }
repl_cmd_greet_handler() { echo "Hello, $1!"; }
repl_cmd_greet_help() { echo "  greet <name>    Say hello"; }
PLUGIN

    _load_plugins_from_dir "$plugin_dir"

    local output
    output=$(dispatch_repl_command "greet" "World")
    assert_eq "$output" "Hello, World!" "should dispatch to plugin REPL command"

    local help_output
    help_output=$(get_plugin_repl_help)
    assert_contains "$help_output" "greet" "help should show greet command"
}

test_plugin_provides_tool() {
    local plugin_dir="${TEST_TMP_DIR}/plugins"
    mkdir -p "$plugin_dir"

    cat > "${plugin_dir}/toolplugin.sh" <<'PLUGIN'
plugin_toolplugin_info() { echo "Tool provider"; }
plugin_toolplugin_hooks() { echo ""; }

tool_my_custom_tool_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "my_custom_tool",
        "description": "A custom tool from a plugin",
        "parameters": {"type": "object", "properties": {}}
    }
}
EOF
}

tool_my_custom_tool_execute() {
    echo "custom tool executed"
}
PLUGIN

    _load_plugins_from_dir "$plugin_dir"

    # The tool should be discoverable
    local tools_json
    tools_json=$(build_tools_array)
    local has_custom
    has_custom=$(echo "$tools_json" | jq '[.[] | select(.function.name == "my_custom_tool")] | length')
    assert_eq "$has_custom" "1" "custom tool from plugin should be in tools array"

    # The tool should be dispatchable
    local result
    result=$(dispatch_tool_call "my_custom_tool" '{}')
    assert_eq "$result" "custom tool executed" "custom tool should execute"
}
```

**Step 2: Run full test suite**

Run: `bash tests/run_tests.sh`
Expected: All pass

**Step 3: Commit**

```bash
git add tests/test_plugins.sh
git commit -m "test: add integration tests for plugin lifecycle, REPL commands, and tool provision"
```

---

### Task 10: Update test runner and fix remaining test failures

**Files:**
- Modify: `tests/run_tests.sh`
- Modify: `tests/test_entrypoint.sh` (if needed)

**Step 1: Source plugins.sh in test runner**

Add after the existing lib sourcing in `tests/run_tests.sh`:
```bash
source "${PROJECT_DIR}/lib/plugins.sh"
```

**Step 2: Fix any remaining test failures**

Run: `bash tests/run_tests.sh`

Fix any tests that reference removed REPL commands or expect the old command structure. Update assertions as needed.

**Step 3: Commit**

```bash
git add tests/
git commit -m "chore: source plugin system in test runner, fix remaining test failures"
```

---

### Task 11: Update documentation

**Files:**
- Modify: `shellia` — update `--help` output
- Modify: `README.md` — add plugin documentation

**Step 1: Update CLI help**

Add `plugins` to the subcommands and explain plugin directories.

**Step 2: Add plugin section to README**

Document:
- Plugin locations (built-in + user)
- How to create a plugin (naming convention, required functions)
- Available hooks and when they fire
- How to provide tools from a plugin
- How to register REPL commands
- Plugin config system

**Step 3: Commit**

```bash
git add shellia README.md
git commit -m "docs: add plugin system documentation"
```

---

## Summary

### New Files
| File | Purpose |
|------|---------|
| `lib/plugins.sh` | Plugin registry, loader, hook dispatch, config helper |
| `lib/plugins/safety/plugin.sh` | Dangerous command detection (extracted from tools) |
| `lib/plugins/themes/plugin.sh` | Theme switching REPL commands (extracted from REPL) |
| `lib/plugins/settings/plugin.sh` | Model/debug/dry-run/profile REPL commands (extracted from REPL) |
| `lib/plugins/history/plugin.sh` | Persistent conversation history (new) |
| `tests/test_plugins.sh` | Plugin system tests |

### Modified Files
| File | Changes |
|------|---------|
| `shellia` | Source plugins.sh, load plugins, fire hooks, add `plugins` subcommand |
| `lib/repl.sh` | Strip to core commands, add plugin dispatch, fire message hooks |
| `lib/api.sh` | Fire hooks around API calls and tool dispatch |
| `lib/prompt.sh` | Fire `on_prompt_build` hook |
| `lib/tools/run_command.sh` | Remove inline safety check |
| `lib/executor.sh` | Remove dead `execute_command`/`execute_plan` |
| `tests/run_tests.sh` | Source plugins.sh |
| `tests/test_executor.sh` | Remove tests for deleted functions |
| `README.md` | Plugin documentation |

### Architecture After Implementation

```
shellia (entrypoint)
├── lib/
│   ├── utils.sh          (core: logging, spinner, version)
│   ├── config.sh         (core: config loading)
│   ├── profiles.sh       (core: profile management)
│   ├── prompt.sh         (core: prompt assembly + plugin hook)
│   ├── api.sh            (core: API calls + plugin hooks)
│   ├── executor.sh       (core: is_dangerous utility only)
│   ├── themes.sh         (core: theme definitions)
│   ├── tools.sh          (core: tool registry)
│   ├── plugins.sh        (core: plugin system)
│   ├── repl.sh           (core: REPL loop, minimal commands)
│   ├── tools/            (built-in tools)
│   │   ├── run_command.sh
│   │   ├── run_plan.sh
│   │   └── ask_user.sh
│   └── plugins/          (built-in plugins)
│       ├── safety/plugin.sh
│       ├── themes/plugin.sh
│       ├── settings/plugin.sh
│       └── history/plugin.sh
└── ~/.config/shellia/
    └── plugins/          (user plugins)
```
