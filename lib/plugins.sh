#!/usr/bin/env bash
# Plugin registry: discovers, loads, and manages plugins with hook-based extensibility
# Compatible with Bash 3.2+ (no associative arrays)

# --- Registry state ---

SHELLIA_LOADED_PLUGINS=()

# Hook registry: indexed array of "hook_name:plugin_name" entries
# Simulates an associative array for Bash 3.2 compatibility
_SHELLIA_HOOK_ENTRIES=()

# --- Internal hook helpers (Bash 3.2 compat) ---

# Get space-separated plugin names for a hook
_hook_get_plugins() {
    local hook="$1"
    local result=""
    local entry
    for entry in ${_SHELLIA_HOOK_ENTRIES[@]+"${_SHELLIA_HOOK_ENTRIES[@]}"}; do
        if [[ "$entry" == "${hook}:"* ]]; then
            local plugin="${entry#*:}"
            result="${result:+${result} }${plugin}"
        fi
    done
    echo "$result"
}

# Check if a hook has any subscribers
_hook_has_subscribers() {
    local hook="$1"
    local entry
    for entry in ${_SHELLIA_HOOK_ENTRIES[@]+"${_SHELLIA_HOOK_ENTRIES[@]}"}; do
        [[ "$entry" == "${hook}:"* ]] && return 0
    done
    return 1
}

# Add a plugin to a hook
_hook_add() {
    local hook="$1"
    local plugin="$2"
    _SHELLIA_HOOK_ENTRIES+=("${hook}:${plugin}")
}

# Remove all entries for a plugin from all hooks
_hook_remove_plugin() {
    local plugin="$1"
    local new_entries=()
    local entry
    for entry in ${_SHELLIA_HOOK_ENTRIES[@]+"${_SHELLIA_HOOK_ENTRIES[@]}"}; do
        if [[ "$entry" != *":${plugin}" ]]; then
            new_entries+=("$entry")
        fi
    done
    _SHELLIA_HOOK_ENTRIES=(${new_entries[@]+"${new_entries[@]}"})
}

# List all unique hook names
_hook_list_names() {
    local seen=""
    local entry
    for entry in ${_SHELLIA_HOOK_ENTRIES[@]+"${_SHELLIA_HOOK_ENTRIES[@]}"}; do
        local hook="${entry%%:*}"
        if [[ " ${seen} " != *" ${hook} "* ]]; then
            echo "$hook"
            seen="${seen:+${seen} }${hook}"
        fi
    done
}

# --- Plugin loading ---

# Load only bundled plugins (no user override)
# Used by metadata flows like --help where user plugins should not execute first.
load_builtin_plugins() {
    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"
}

# Load plugins from built-in dir, then user dir (user can override built-in)
load_plugins() {
    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"
    _load_plugins_from_dir "${SHELLIA_CONFIG_DIR}/plugins"
}

# Discover and load plugins from a directory
# Supports: name.sh (single file) or name/plugin.sh (directory format)
_load_plugins_from_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0

    # Single file plugins: name.sh
    for plugin_file in "${dir}"/*.sh; do
        [[ -f "$plugin_file" ]] || continue
        local name
        name=$(basename "$plugin_file" .sh)
        _register_plugin "$name" "$plugin_file"
    done

    # Directory plugins: name/plugin.sh
    for plugin_dir in "${dir}"/*/; do
        [[ -d "$plugin_dir" ]] || continue
        local plugin_file="${plugin_dir}plugin.sh"
        [[ -f "$plugin_file" ]] || continue
        local name
        name=$(basename "$plugin_dir")
        _register_plugin "$name" "$plugin_file"
    done
}

# Source a plugin file, verify required functions, register hooks
_register_plugin() {
    local name="$1"
    local file="$2"

    # Source the plugin file
    source "$file" || {
        log_warn "plugin: failed to source '${file}'"
        return 1
    }

    # Verify required functions exist
    if ! declare -F "plugin_${name}_info" >/dev/null 2>&1; then
        log_warn "plugin: '${name}' missing plugin_${name}_info()"
        return 1
    fi

    if ! declare -F "plugin_${name}_hooks" >/dev/null 2>&1; then
        log_warn "plugin: '${name}' missing plugin_${name}_hooks()"
        return 1
    fi

    # If already loaded, unregister old hooks and remove from loaded list
    if _plugin_is_loaded "$name"; then
        _unregister_plugin_hooks "$name"
        local new_list=()
        local p
        for p in "${SHELLIA_LOADED_PLUGINS[@]}"; do
            [[ "$p" != "$name" ]] && new_list+=("$p")
        done
        SHELLIA_LOADED_PLUGINS=(${new_list[@]+"${new_list[@]}"})
    fi

    # Register the plugin
    SHELLIA_LOADED_PLUGINS+=("$name")

    # Get hooks and register subscriptions
    local hooks
    hooks=$("plugin_${name}_hooks")
    local hook
    for hook in $hooks; do
        _hook_add "$hook" "$name"
    done

    debug_log "plugins" "loaded '${name}' from $(basename "$file")"
}

# --- Plugin queries ---

# Returns 0 if plugin is loaded, 1 otherwise
_plugin_is_loaded() {
    local name="$1"
    local p
    for p in ${SHELLIA_LOADED_PLUGINS[@]+"${SHELLIA_LOADED_PLUGINS[@]}"}; do
        [[ "$p" == "$name" ]] && return 0
    done
    return 1
}

# Remove a plugin's hooks from the registry
_unregister_plugin_hooks() {
    local name="$1"
    _hook_remove_plugin "$name"
}

# --- Hook dispatch ---

# Call all subscribers for a hook, passing args
fire_hook() {
    local hook_name="$1"
    shift

    _hook_has_subscribers "$hook_name" || return 0

    local plugins
    plugins=$(_hook_get_plugins "$hook_name")
    local plugin
    for plugin in $plugins; do
        local func="plugin_${plugin}_on_${hook_name}"
        if declare -F "$func" >/dev/null 2>&1; then
            "$func" "$@"
        fi
    done
}

# Special hook that collects stdout from on_prompt_build subscribers
fire_prompt_hook() {
    local mode="${1:-}"
    local output=""

    _hook_has_subscribers "prompt_build" || {
        echo ""
        return 0
    }

    local plugins
    plugins=$(_hook_get_plugins "prompt_build")
    local plugin
    for plugin in $plugins; do
        local func="plugin_${plugin}_on_prompt_build"
        if declare -F "$func" >/dev/null 2>&1; then
            local chunk
            chunk=$("$func" "$mode")
            output="${output}${chunk}"
        fi
    done

    echo "$output"
}

# --- Plugin config ---

# Read a config value for a plugin
# Args: plugin_name, key, [default]
plugin_config_get() {
    local plugin_name="$1"
    local key="$2"
    local default="${3:-}"

    local config_file="${SHELLIA_CONFIG_DIR}/plugins/${plugin_name}/config"

    if [[ ! -f "$config_file" ]]; then
        echo "$default"
        return 0
    fi

    local value
    value=$(grep "^${key}=" "$config_file" 2>/dev/null | head -1 | cut -d'=' -f2-)

    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# --- Plugin listing ---

# Display loaded plugins with descriptions and hooks
list_plugins() {
    if [[ ${#SHELLIA_LOADED_PLUGINS[@]} -eq 0 ]]; then
        echo -e "${THEME_MUTED}No plugins loaded.${NC}"
        return 0
    fi

    echo -e "${THEME_ACCENT}Loaded plugins:${NC}"
    local plugin
    for plugin in "${SHELLIA_LOADED_PLUGINS[@]}"; do
        local info
        info=$("plugin_${plugin}_info" 2>/dev/null)
        local hooks
        hooks=$("plugin_${plugin}_hooks" 2>/dev/null)
        echo -e "  ${THEME_ACCENT}${plugin}${NC} - ${info:-no description}"
        if [[ -n "$hooks" ]]; then
            echo -e "    ${THEME_MUTED}hooks: ${hooks}${NC}"
        fi
    done
}

# --- REPL command integration ---

# Discover repl_cmd_*_handler functions from plugins
get_plugin_repl_commands() {
    declare -F | awk '{print $3}' | grep '^repl_cmd_.*_handler$' | sed 's/^repl_cmd_//;s/_handler$//' | sort
}

# Dispatch a REPL command to its handler
# Converts hyphens to underscores in cmd_name for function lookup
dispatch_repl_command() {
    local cmd_name="$1"
    shift

    # Convert hyphens to underscores for function name
    local func_name="repl_cmd_${cmd_name//-/_}_handler"

    if declare -F "$func_name" >/dev/null 2>&1; then
        "$func_name" "$@"
        return 0  # Command was handled; don't leak handler errors to the REPL
    else
        return 1
    fi
}

# Collect help text from repl_cmd_*_help functions
get_plugin_repl_help() {
    local help_funcs
    help_funcs=$(declare -F | awk '{print $3}' | grep '^repl_cmd_.*_help$' | sort)

    [[ -z "$help_funcs" ]] && return 0

    local func
    for func in $help_funcs; do
        "$func"
    done
}

# --- CLI subcommand integration ---

# Check if $1 matches a cli_cmd_*_handler and dispatch it
# Returns 1 if no matching command found (fall through to normal dispatch)
dispatch_cli_command() {
    local cmd_name="$1"
    shift

    # Convert hyphens to underscores for function name
    local func_name="cli_cmd_${cmd_name//-/_}_handler"

    if ! declare -F "$func_name" >/dev/null 2>&1; then
        return 1
    fi

    # Get setup requirements
    local setup_func="cli_cmd_${cmd_name//-/_}_setup"
    if declare -F "$setup_func" >/dev/null 2>&1; then
        local setup_steps
        setup_steps=$("$setup_func")
        _run_cli_setup "$setup_steps"
    fi

    # Dispatch to the handler
    "$func_name" "$@"
}

# Run setup steps declared by cli_cmd_*_setup
_run_cli_setup() {
    local steps="$1"
    local step
    for step in $steps; do
        case "$step" in
            config)      load_config ;;
            validate)    validate_config ;;
            theme)       apply_theme "${SHELLIA_THEME:-default}" ;;
            tools)       load_tools ;;
            plugins)     load_plugins ;;
            hooks_init)  fire_hook "init" ;;
        esac
    done
}

# Discover all cli_cmd_*_handler function names
get_cli_commands() {
    declare -F | awk '{print $3}' | grep '^cli_cmd_.*_handler$' | sed 's/^cli_cmd_//;s/_handler$//' | sort
}

# Collect help text from cli_cmd_*_help functions
get_cli_command_help() {
    local help_funcs
    help_funcs=$(declare -F | awk '{print $3}' | grep '^cli_cmd_.*_help$' | sort)

    [[ -z "$help_funcs" ]] && return 0

    local func
    for func in $help_funcs; do
        "$func"
    done
}

# --- CLI flag integration ---

# Parse CLI flags dynamically via cli_flag_*_handler functions
# Populates PROMPT_ARGS with non-flag arguments
# Usage: parse_cli_flags "$@"
parse_cli_flags() {
    PROMPT_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --*)
                # Extract flag name: --dry-run -> dry_run
                local flag_name="${1#--}"
                flag_name="${flag_name//-/_}"
                local handler="cli_flag_${flag_name}_handler"

                if declare -F "$handler" >/dev/null 2>&1; then
                    shift
                    # Run handler in current shell so variable assignments
                    # (e.g. SHELLIA_WEB_MODE=true) propagate. Capture stdout
                    # (the consumed-args count) via a temp file.
                    local _cli_flag_tmp
                    _cli_flag_tmp=$(mktemp)
                    "$handler" "$@" > "$_cli_flag_tmp"
                    local consumed
                    consumed=$(cat "$_cli_flag_tmp")
                    rm -f "$_cli_flag_tmp"
                    consumed=${consumed:-0}
                    # Shift by the number of args consumed
                    local i
                    for ((i = 0; i < consumed; i++)); do
                        shift
                    done
                else
                    # Unknown flag — treat as prompt arg
                    PROMPT_ARGS+=("$1")
                    shift
                fi
                ;;
            *)
                PROMPT_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

# Collect help text from cli_flag_*_help functions
get_cli_flag_help() {
    local help_funcs
    help_funcs=$(declare -F | awk '{print $3}' | grep '^cli_flag_.*_help$' | sort)

    [[ -z "$help_funcs" ]] && return 0

    local func
    for func in $help_funcs; do
        "$func"
    done
}

# --- Dynamic help generation ---

# Generate full --help output from plugin definitions
generate_help() {
    echo "Usage: shellia [OPTIONS] [COMMAND] [PROMPT]"
    echo ""
    echo "A terminal agent that helps you execute and automate tasks from the console."
    echo ""

    # CLI commands
    local cmd_help
    cmd_help=$(get_cli_command_help)
    if [[ -n "$cmd_help" ]]; then
        echo "Commands:"
        echo "$cmd_help"
        echo ""
    fi

    # CLI flags
    local flag_help
    flag_help=$(get_cli_flag_help)
    if [[ -n "$flag_help" ]]; then
        echo "Options:"
        echo "$flag_help"
    fi

    echo "  --help, -h                Show this help message"
    echo "  --version                 Print version"
    echo ""
    echo "Modes:"
    echo "  shellia find large files  Single command mode (no quotes needed)"
    echo "  shellia                   REPL mode (interactive)"
    echo "  shellia serve             Web UI mode (browser)"
    echo "  cmd | shellia explain     Pipe mode (analyze input)"
}
