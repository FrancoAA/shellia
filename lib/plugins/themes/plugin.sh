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
