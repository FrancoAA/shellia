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
