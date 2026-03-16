#!/usr/bin/env bash
# Plugin: scheduler — schedule shellia prompts to run on a timer
# Stores job metadata, logs, wrapper scripts, and platform-specific
# scheduling artefacts under ${SHELLIA_CONFIG_DIR}/plugins/scheduler/

# === Plugin metadata ===

plugin_scheduler_info() {
    echo "Schedule shellia prompts to run automatically on a timer"
}

plugin_scheduler_hooks() {
    # No hooks — scheduler is invoked via CLI/REPL subcommands only
    echo ""
}

# === Directory helpers ===
# Each returns the absolute path for one category of scheduler data.

_scheduler_base_dir() {
    echo "${SHELLIA_CONFIG_DIR}/plugins/scheduler"
}

_scheduler_dir_jobs() {
    echo "$(_scheduler_base_dir)/jobs"
}

_scheduler_dir_logs() {
    echo "$(_scheduler_base_dir)/logs"
}

_scheduler_dir_bin() {
    echo "$(_scheduler_base_dir)/bin"
}

_scheduler_dir_launchd() {
    echo "$(_scheduler_base_dir)/launchd"
}

_scheduler_dir_cron() {
    echo "$(_scheduler_base_dir)/cron"
}

# Create all required directories if they don't already exist.
_scheduler_ensure_dirs() {
    mkdir -p "$(_scheduler_dir_jobs)"
    mkdir -p "$(_scheduler_dir_logs)"
    mkdir -p "$(_scheduler_dir_bin)"
    mkdir -p "$(_scheduler_dir_launchd)"
    mkdir -p "$(_scheduler_dir_cron)"
}

# === Job ID generator ===
# Produces a short, filesystem-safe identifier from an arbitrary label.
# Output contains only lowercase alphanumeric characters and hyphens.

_scheduler_generate_id() {
    local label="${1:-job}"
    # Lowercase, replace non-alnum with hyphens, collapse runs, trim edges
    local id
    id=$(printf '%s' "$label" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9' '-' \
        | sed 's/^-//;s/-$//')
    # Append a short pseudo-random suffix for uniqueness
    local suffix
    suffix=$(printf '%04x' "$$" | tail -c 4)
    echo "${id}-${suffix}"
}

# === Backend resolution ===
# Resolves the scheduling backend to use: "launchd" or "cron".
# Usage: _scheduler_resolve_backend <backend_choice> [os_name]
#   backend_choice: "auto", "launchd", or "cron"
#   os_name:        optional; defaults to $(uname -s)
# Echoes the resolved backend name. Returns 1 on failure.

_scheduler_resolve_backend() {
    local choice="${1:-auto}"
    local os_name="${2:-$(uname -s)}"

    case "$choice" in
        auto)
            if [[ "$os_name" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
                echo "launchd"
            elif command -v crontab >/dev/null 2>&1; then
                echo "cron"
            else
                echo "error: no supported scheduler backend found" >&2
                return 1
            fi
            ;;
        launchd)
            if command -v launchctl >/dev/null 2>&1; then
                echo "launchd"
            else
                echo "error: launchd backend requires launchctl" >&2
                return 1
            fi
            ;;
        cron)
            if command -v crontab >/dev/null 2>&1; then
                echo "cron"
            else
                echo "error: cron backend requires crontab" >&2
                return 1
            fi
            ;;
        *)
            echo "error: unknown backend '${choice}' (use auto, launchd, or cron)" >&2
            return 1
            ;;
    esac
}

# === Schedule validation helpers ===

# Validate a one-shot datetime string in "YYYY-MM-DD HH:MM" format.
# Returns 0 if valid, 1 if invalid (with error on stderr).
_scheduler_validate_at() {
    local datetime="${1:-}"

    if [[ -z "$datetime" ]]; then
        echo "error: --at requires a datetime string (YYYY-MM-DD HH:MM)" >&2
        return 1
    fi

    # Basic pattern match: YYYY-MM-DD HH:MM
    if [[ "$datetime" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then
        return 0
    else
        echo "error: invalid datetime '${datetime}' (expected YYYY-MM-DD HH:MM)" >&2
        return 1
    fi
}

# Validate a recurring schedule preset name.
# Accepts: hourly, daily, weekly, monthly.
# Returns 0 if valid, 1 if invalid.
_scheduler_validate_every() {
    local value="${1:-}"

    case "$value" in
        hourly|daily|weekly|monthly) return 0 ;;
        "")
            echo "error: --every requires a preset name (hourly, daily, weekly, monthly)" >&2
            return 1
            ;;
        *)
            echo "error: unknown schedule preset '${value}' (use hourly, daily, weekly, monthly)" >&2
            return 1
            ;;
    esac
}

# Validate a raw cron expression (5-field format).
# Each field may contain digits, *, /, -, and commas.
# Returns 0 if valid, 1 if invalid.
_scheduler_validate_cron() {
    local expression="${1:-}"

    if [[ -z "$expression" ]]; then
        echo "error: cron expression must not be empty" >&2
        return 1
    fi

    # Split into fields and count them
    local fields
    read -ra fields <<< "$expression"

    if [[ ${#fields[@]} -ne 5 ]]; then
        echo "error: cron expression must have exactly 5 fields, got ${#fields[@]}" >&2
        return 1
    fi

    # Each field must contain only digits, *, /, -, commas
    local field
    for field in "${fields[@]}"; do
        if [[ ! "$field" =~ ^[0-9\*\/\,\-]+$ ]]; then
            echo "error: invalid cron field '${field}'" >&2
            return 1
        fi
    done

    return 0
}

# === Schedule normalization ===
# Converts validated schedule input to a uniform representation.
# Usage: _scheduler_normalize_schedule <schedule_type> <schedule_value>
#   schedule_type:  "once" or "recurring"
#   schedule_value: datetime string (once) or preset/cron (recurring)
# Echoes the normalized schedule value.

_scheduler_normalize_schedule() {
    local schedule_type="${1:-}"
    local schedule_value="${2:-}"

    case "$schedule_type" in
        once)
            echo "$schedule_value"
            ;;
        recurring)
            case "$schedule_value" in
                hourly)  echo "0 * * * *" ;;
                daily)   echo "0 0 * * *" ;;
                weekly)  echo "0 0 * * 0" ;;
                monthly) echo "0 0 1 * *" ;;
                *)       echo "$schedule_value" ;;  # raw cron passthrough
            esac
            ;;
        *)
            echo "error: unknown schedule type '${schedule_type}'" >&2
            return 1
            ;;
    esac
}

# === CLI subcommand: shellia schedule <action> ===

cli_cmd_schedule_handler() {
    local action="${1:-}"
    shift 2>/dev/null || true

    case "$action" in
        add|list|run|logs|remove)
            echo "schedule ${action}: not yet implemented"
            ;;
        *)
            echo "Usage: schedule add|list|run|logs|remove"
            ;;
    esac
}

cli_cmd_schedule_help() {
    echo "  schedule <action>         Manage scheduled prompts (add|list|run|logs|remove)"
}

cli_cmd_schedule_setup() {
    echo "config theme plugins"
}

# === REPL command: /schedule <action> ===

repl_cmd_schedule_handler() {
    local action="${1:-}"
    shift 2>/dev/null || true

    case "$action" in
        add|list|run|logs|remove)
            echo "schedule ${action}: not yet implemented"
            ;;
        *)
            echo "Usage: schedule add|list|run|logs|remove"
            ;;
    esac
}

repl_cmd_schedule_help() {
    echo -e "  ${THEME_ACCENT:-}schedule${NC:-}          Manage scheduled prompts"
}
