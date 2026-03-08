#!/usr/bin/env bash
# Plugin: core — essential CLI subcommands

plugin_core_info() {
    echo "Core CLI commands (init, plugins)"
}

plugin_core_hooks() {
    echo ""
}

# === CLI subcommands ===

# --- init ---
cli_cmd_init_handler() {
    shellia_init
}

cli_cmd_init_help() {
    echo "  init                      Run setup wizard"
}

cli_cmd_init_setup() {
    echo ""
}

# --- plugins ---
cli_cmd_plugins_handler() {
    list_plugins
}

cli_cmd_plugins_help() {
    echo "  plugins                   List loaded plugins"
}

cli_cmd_plugins_setup() {
    echo "config theme tools plugins"
}

# --- REPL: plugins (convenience alias) ---
repl_cmd_plugins_handler() {
    list_plugins
}

repl_cmd_plugins_help() {
    echo -e "  ${THEME_ACCENT}plugins${NC}           List loaded plugins"
}
