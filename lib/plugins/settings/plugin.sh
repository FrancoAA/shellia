#!/usr/bin/env bash
# Plugin: settings — runtime settings, CLI flags, and profile management

plugin_settings_info() {
    echo "Settings, flags, and profile management (model, mode, dry-run, debug, profiles, profile)"
}

plugin_settings_hooks() {
    echo ""
}

# === CLI flags ===

# --- --dry-run ---
cli_flag_dry_run_handler() {
    SHELLIA_DRY_RUN=true
    echo 0
}

cli_flag_dry_run_help() {
    echo "  --dry-run                 Show command without executing"
}

# --- --debug ---
cli_flag_debug_handler() {
    SHELLIA_DEBUG=true
    echo 0
}

cli_flag_debug_help() {
    echo "  --debug                   Show debug information"
}

# --- --profile ---
cli_flag_profile_handler() {
    if [[ -z "${1:-}" ]]; then
        die "Usage: --profile <name>"
    fi
    SHELLIA_PROFILE="$1"
    echo 1
}

cli_flag_profile_help() {
    echo "  --profile <name>          Use a specific profile"
}

# === CLI subcommands ===

# --- profiles ---
cli_cmd_profiles_handler() {
    list_profiles
}

cli_cmd_profiles_help() {
    echo "  profiles                  List all profiles"
}

cli_cmd_profiles_setup() {
    echo "config theme"
}

# --- profile add|remove ---
cli_cmd_profile_handler() {
    local action="${1:-}"
    local name="${2:-}"

    case "$action" in
        add)
            [[ -z "$name" ]] && die "Usage: shellia profile add <name>"
            add_profile "$name"
            ;;
        remove)
            [[ -z "$name" ]] && die "Usage: shellia profile remove <name>"
            remove_profile "$name"
            ;;
        *)
            die "Usage: shellia profile add|remove <name>"
            ;;
    esac
}

cli_cmd_profile_help() {
    echo "  profile add|remove <name> Add or remove a profile"
}

cli_cmd_profile_setup() {
    echo "config theme"
}

# === REPL commands ===

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

# REPL command: mode
repl_cmd_mode_handler() {
    local new_mode="$1"
    if [[ -z "$new_mode" ]]; then
        log_info "Agent mode: ${SHELLIA_AGENT_MODE:-build}"
        return 0
    fi

    case "$new_mode" in
        build|plan)
            SHELLIA_AGENT_MODE="$new_mode"
            log_info "Switched to agent mode: ${SHELLIA_AGENT_MODE}"
            ;;
        *)
            log_error "Usage: mode <build|plan>"
            return 1
            ;;
    esac
}

repl_cmd_mode_help() {
    echo -e "  ${THEME_ACCENT}mode ${THEME_MUTED}<build|plan>${NC}  Switch agent mode (or show current)"
}

# REPL command: dry-run (dispatched as dry_run via hyphen conversion)
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
