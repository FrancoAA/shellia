#!/usr/bin/env bash
# Plugin: scheduler — schedule shellia prompts to run on a timer

plugin_scheduler_info() {
    echo "Schedule shellia prompts to run automatically on a timer"
}

plugin_scheduler_hooks() {
    # No hooks — scheduler is invoked via CLI/REPL subcommands only
    echo ""
}

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

_scheduler_ensure_dirs() {
    mkdir -p "$(_scheduler_dir_jobs)" "$(_scheduler_dir_logs)" "$(_scheduler_dir_bin)" "$(_scheduler_dir_launchd)" "$(_scheduler_dir_cron)"
}

_scheduler_generate_id() {
    local label="${1:-job}"
    local id
    id=$(printf '%s' "$label" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9' '-' \
        | sed 's/^-//;s/-$//')
    local suffix
    suffix=$(printf '%04x' "$$" | tail -c 4)
    echo "${id}-${suffix}"
}

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

_scheduler_validate_at() {
    local datetime="${1:-}"

    if [[ -z "$datetime" ]]; then
        echo "error: --at requires a datetime string (YYYY-MM-DD HH:MM)" >&2
        return 1
    fi

    if [[ "$datetime" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then
        return 0
    else
        echo "error: invalid datetime '${datetime}' (expected YYYY-MM-DD HH:MM)" >&2
        return 1
    fi
}

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

_scheduler_validate_cron() {
    local expression="${1:-}"

    if [[ -z "$expression" ]]; then
        echo "error: cron expression must not be empty" >&2
        return 1
    fi

    local fields
    read -ra fields <<< "$expression"

    if [[ ${#fields[@]} -ne 5 ]]; then
        echo "error: cron expression must have exactly 5 fields, got ${#fields[@]}" >&2
        return 1
    fi

    local field
    for field in "${fields[@]}"; do
        if [[ ! "$field" =~ ^[0-9\*\/\,\-]+$ ]]; then
            echo "error: invalid cron field '${field}'" >&2
            return 1
        fi
    done

    return 0
}

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
                *)       echo "$schedule_value" ;;
            esac
            ;;
        *)
            echo "error: unknown schedule type '${schedule_type}'" >&2
            return 1
            ;;
    esac
}

_scheduler_job_file() {
    local job_id="${1:-}"
    echo "$(_scheduler_dir_jobs)/${job_id}.json"
}

_scheduler_create_job() {
    local schedule_type="${1:-}"
    local schedule_value="${2:-}"
    local backend="${3:-}"
    local prompt="${4:-}"

    local job_id
    job_id=$(_scheduler_generate_id "$prompt")

    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    local backend_artifact
    case "$backend" in
        launchd) backend_artifact="$(_scheduler_dir_launchd)/${job_id}.plist" ;;
        cron)    backend_artifact="$(_scheduler_dir_cron)/${job_id}.cron" ;;
        *)       backend_artifact="" ;;
    esac

    local created_at
    created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local job_file
    job_file=$(_scheduler_job_file "$job_id")

    jq -n \
        --arg id "$job_id" \
        --arg prompt "$prompt" \
        --arg schedule_type "$schedule_type" \
        --arg schedule_value "$schedule_value" \
        --arg backend "$backend" \
        --arg created_at "$created_at" \
        --argjson enabled true \
        --arg log_file "$log_file" \
        --arg wrapper_file "$wrapper_file" \
        --arg backend_artifact "$backend_artifact" \
        --arg last_run_at "" \
        --arg last_exit_code "" \
        --arg last_status "" \
        --argjson run_count 0 \
        '{
            id: $id,
            prompt: $prompt,
            schedule_type: $schedule_type,
            schedule_value: $schedule_value,
            backend: $backend,
            created_at: $created_at,
            enabled: $enabled,
            log_file: $log_file,
            wrapper_file: $wrapper_file,
            backend_artifact: $backend_artifact,
            last_run_at: $last_run_at,
            last_exit_code: $last_exit_code,
            last_status: $last_status,
            run_count: $run_count
        }' > "$job_file" || return 1

    echo "$job_id"
}

_scheduler_read_job() {
    local job_id="${1:-}"
    local job_file
    job_file=$(_scheduler_job_file "$job_id")

    if [[ ! -f "$job_file" ]]; then
        echo "error: job '${job_id}' not found" >&2
        return 1
    fi

    cat "$job_file"
}

_scheduler_update_job() {
    local job_id="${1:-}"
    local field="${2:-}"
    local value="${3:-}"
    local job_file
    job_file=$(_scheduler_job_file "$job_id")

    if [[ ! -f "$job_file" ]]; then
        echo "error: job '${job_id}' not found" >&2
        return 1
    fi

    local tmp_file="${job_file}.tmp"

    if printf '%s' "$value" | jq -e 'tonumber' >/dev/null 2>&1; then
        jq --arg f "$field" --argjson v "$value" '.[$f] = $v' "$job_file" > "$tmp_file" || return 1
    else
        jq --arg f "$field" --arg v "$value" '.[$f] = $v' "$job_file" > "$tmp_file" || return 1
    fi

    mv "$tmp_file" "$job_file"
}

_scheduler_list_jobs() {
    local jobs_dir="$(_scheduler_dir_jobs)"
    local found=false

    for f in "$jobs_dir"/*.json; do
        [[ -f "$f" ]] || continue
        found=true
        jq -c '.' "$f"
    done

    if ! $found; then
        return 0
    fi
}

_scheduler_delete_job_file() {
    local job_id="${1:-}"
    local job_file
    job_file=$(_scheduler_job_file "$job_id")

    if [[ ! -f "$job_file" ]]; then
        echo "error: job '${job_id}' not found" >&2
        return 1
    fi

    rm "$job_file"
}

_scheduler_log_entry() {
    local job_id="${1:-}"
    local message="${2:-}"
    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    echo "[${timestamp}] ${message}" >> "$log_file"
}

_scheduler_render_wrapper() {
    local job_id="${1:-}"
    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    local job_file="$(_scheduler_dir_jobs)/${job_id}.json"
    local log_file="$(_scheduler_dir_logs)/${job_id}.log"

    cat > "$wrapper_file" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# Auto-generated scheduler wrapper — do not edit
set -uo pipefail

JOB_ID="__JOB_ID__"
JOB_FILE="__JOB_FILE__"
LOG_FILE="__LOG_FILE__"
SHELLIA_BIN="${SHELLIA_DIR:-__SHELLIA_DIR__}/shellia"

_log() {
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    echo "[${ts}] $1" >> "$LOG_FILE"
}

# --- Pre-flight checks ---

# If job metadata is missing, log a skip and exit
if [[ ! -f "$JOB_FILE" ]]; then
    _log "skip: job metadata file missing for ${JOB_ID}"
    exit 0
fi

# Read job metadata
PROMPT=$(jq -r '.prompt' "$JOB_FILE")
ENABLED=$(jq -r '.enabled' "$JOB_FILE")
SCHEDULE_TYPE=$(jq -r '.schedule_type' "$JOB_FILE")

# If disabled, log a skip and exit
if [[ "$ENABLED" != "true" ]]; then
    _log "skip: job ${JOB_ID} is disabled"
    exit 0
fi

# --- Execute ---

START_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Capture output and exit code
TMPOUT=$(mktemp)
EXIT_CODE=0
"$SHELLIA_BIN" "$PROMPT" > "$TMPOUT" 2>&1 || EXIT_CODE=$?

# Determine status
if [[ "$EXIT_CODE" -eq 0 ]]; then
    STATUS="success"
else
    STATUS="failed"
fi

# Truncate output to first 500 chars
OUTPUT_SUMMARY=$(head -c 500 "$TMPOUT")
rm -f "$TMPOUT"

FINISH_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# --- Log the run ---

{
    echo "--- Run: ${START_TS} ---"
    echo "Job: ${JOB_ID}"
    echo "Prompt: ${PROMPT}"
    echo "Exit code: ${EXIT_CODE}"
    echo "Status: ${STATUS}"
    echo "Output:"
    echo "${OUTPUT_SUMMARY}"
    echo ""
} >> "$LOG_FILE"

# --- Update job metadata ---

# Read current run_count and increment
RUN_COUNT=$(jq -r '.run_count' "$JOB_FILE")
NEW_RUN_COUNT=$(( RUN_COUNT + 1 ))

# Atomic update via temp file + mv
TMP_JOB="${JOB_FILE}.tmp"
jq \
    --arg last_run_at "$FINISH_TS" \
    --arg last_exit_code "$EXIT_CODE" \
    --arg last_status "$STATUS" \
    --argjson run_count "$NEW_RUN_COUNT" \
    '.last_run_at = $last_run_at | .last_exit_code = $last_exit_code | .last_status = $last_status | .run_count = $run_count' \
    "$JOB_FILE" > "$TMP_JOB" && mv "$TMP_JOB" "$JOB_FILE"

# --- Disable run-once jobs on success ---

if [[ "$SCHEDULE_TYPE" == "once" && "$EXIT_CODE" -eq 0 ]]; then
    TMP_JOB="${JOB_FILE}.tmp"
    jq '.enabled = false' "$JOB_FILE" > "$TMP_JOB" && mv "$TMP_JOB" "$JOB_FILE"
fi
WRAPPER_EOF

    # Replace placeholders with actual values
    local escaped_job_file escaped_log_file escaped_shellia_dir
    escaped_job_file=$(printf '%s\n' "$job_file" | sed 's/[&/\]/\\&/g')
    escaped_log_file=$(printf '%s\n' "$log_file" | sed 's/[&/\]/\\&/g')
    escaped_shellia_dir=$(printf '%s\n' "${SHELLIA_DIR:-}" | sed 's/[&/\]/\\&/g')

    sed -i '' \
        -e "s|__JOB_ID__|${job_id}|g" \
        -e "s|__JOB_FILE__|${escaped_job_file}|g" \
        -e "s|__LOG_FILE__|${escaped_log_file}|g" \
        -e "s|__SHELLIA_DIR__|${escaped_shellia_dir}|g" \
        "$wrapper_file" 2>/dev/null || \
    sed -i \
        -e "s|__JOB_ID__|${job_id}|g" \
        -e "s|__JOB_FILE__|${escaped_job_file}|g" \
        -e "s|__LOG_FILE__|${escaped_log_file}|g" \
        -e "s|__SHELLIA_DIR__|${escaped_shellia_dir}|g" \
        "$wrapper_file"

    chmod +x "$wrapper_file"
}

_scheduler_launchd_label() {
    local job_id="${1:-}"
    echo "com.shellia.scheduler.${job_id}"
}

_scheduler_launchd_render_plist() {
    local job_id="${1:-}"
    local plist_file="$(_scheduler_dir_launchd)/${job_id}.plist"
    local job_json
    job_json=$(_scheduler_read_job "$job_id") || return 1

    local label
    label=$(_scheduler_launchd_label "$job_id")

    local wrapper_file
    wrapper_file=$(echo "$job_json" | jq -r '.wrapper_file')
    local log_file
    log_file=$(echo "$job_json" | jq -r '.log_file')
    local schedule_type
    schedule_type=$(echo "$job_json" | jq -r '.schedule_type')
    local schedule_value
    schedule_value=$(echo "$job_json" | jq -r '.schedule_value')

    local calendar_entries=""

    if [[ "$schedule_type" == "once" ]]; then
        local date_part="${schedule_value%% *}"
        local time_part="${schedule_value##* }"
        local year month day hour minute
        year="${date_part%%-*}"
        local md="${date_part#*-}"
        month="${md%%-*}"
        day="${md##*-}"
        hour="${time_part%%:*}"
        minute="${time_part##*:}"

        month=$((10#$month))
        day=$((10#$day))
        hour=$((10#$hour))
        minute=$((10#$minute))

        calendar_entries="            <key>Month</key>
            <integer>${month}</integer>
            <key>Day</key>
            <integer>${day}</integer>
            <key>Hour</key>
            <integer>${hour}</integer>
            <key>Minute</key>
            <integer>${minute}</integer>"
    else
        local fields
        read -ra fields <<< "$schedule_value"
        local cron_min="${fields[0]:-*}"
        local cron_hour="${fields[1]:-*}"
        local cron_dom="${fields[2]:-*}"
        local cron_month="${fields[3]:-*}"
        local cron_dow="${fields[4]:-*}"

        if [[ "$cron_min" != "*" ]]; then
            calendar_entries="${calendar_entries}            <key>Minute</key>
            <integer>$((10#$cron_min))</integer>
"
        fi
        if [[ "$cron_hour" != "*" ]]; then
            calendar_entries="${calendar_entries}            <key>Hour</key>
            <integer>$((10#$cron_hour))</integer>
"
        fi
        if [[ "$cron_dom" != "*" ]]; then
            calendar_entries="${calendar_entries}            <key>Day</key>
            <integer>$((10#$cron_dom))</integer>
"
        fi
        if [[ "$cron_month" != "*" ]]; then
            calendar_entries="${calendar_entries}            <key>Month</key>
            <integer>$((10#$cron_month))</integer>
"
        fi
        if [[ "$cron_dow" != "*" ]]; then
            calendar_entries="${calendar_entries}            <key>Weekday</key>
            <integer>$((10#$cron_dow))</integer>
"
        fi

        calendar_entries=$(printf '%s' "$calendar_entries" | sed '$s/$//')
    fi

    cat > "$plist_file" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${wrapper_file}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
${calendar_entries}
    </dict>
    <key>StandardOutPath</key>
    <string>${log_file}</string>
    <key>StandardErrorPath</key>
    <string>${log_file}</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST_EOF
}

_scheduler_launchd_install() {
    local job_id="${1:-}"
    local plist_file="$(_scheduler_dir_launchd)/${job_id}.plist"

    launchctl load "$plist_file"
}

_scheduler_launchd_remove() {
    local job_id="${1:-}"
    local plist_file="$(_scheduler_dir_launchd)/${job_id}.plist"

    launchctl unload "$plist_file" 2>/dev/null || true
    rm -f "$plist_file"
}

_scheduler_cron_read_crontab() {
    local content
    content=$(crontab -l 2>/dev/null) || true
    printf '%s' "$content"
}

_scheduler_cron_write_crontab() {
    local content="${1:-}"
    crontab - <<< "$content"
}

_scheduler_append_line() {
    local var_name="${1:-}"
    local line="${2:-}"
    local current="${!var_name:-}"
    if [[ -z "$current" ]]; then
        printf -v "$var_name" '%s' "$line"
    else
        printf -v "$var_name" '%s\n%s' "$current" "$line"
    fi
}

_scheduler_cron_render_line() {
    local job_id="${1:-}"
    local job_json
    job_json=$(_scheduler_read_job "$job_id") || return 1

    local schedule_type schedule_value wrapper_file
    schedule_type=$(echo "$job_json" | jq -r '.schedule_type')
    schedule_value=$(echo "$job_json" | jq -r '.schedule_value')
    wrapper_file=$(echo "$job_json" | jq -r '.wrapper_file')

    local cron_expr
    if [[ "$schedule_type" == "once" ]]; then
        local date_part="${schedule_value%% *}"
        local time_part="${schedule_value##* }"
        local md="${date_part#*-}"
        local month="${md%%-*}"
        local day="${md##*-}"
        local hour="${time_part%%:*}"
        local minute="${time_part##*:}"

        minute=$((10#$minute))
        hour=$((10#$hour))
        day=$((10#$day))
        month=$((10#$month))

        cron_expr="${minute} ${hour} ${day} ${month} *"
    else
        cron_expr="$schedule_value"
    fi

    echo "${cron_expr} /bin/bash ${wrapper_file} # shellia-scheduler:${job_id}"
}

_scheduler_cron_install() {
    local job_id="${1:-}"
    local cron_line
    cron_line=$(_scheduler_cron_render_line "$job_id") || return 1

    local current
    current=$(_scheduler_cron_read_crontab)

    local begin_marker="# BEGIN shellia-scheduler"
    local end_marker="# END shellia-scheduler"

    if [[ "$current" == *"$begin_marker"* ]]; then
        local before_block="" in_block="" after_block=""
        local state="before"

        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$state" in
                before)
                    if [[ "$line" == "$begin_marker" ]]; then
                        state="inside"
                        _scheduler_append_line in_block "$begin_marker"
                    else
                        _scheduler_append_line before_block "$line"
                    fi
                    ;;
                inside)
                    if [[ "$line" == "$end_marker" ]]; then
                        state="after"
                        _scheduler_append_line in_block "$cron_line"
                        _scheduler_append_line in_block "$end_marker"
                    else
                        _scheduler_append_line in_block "$line"
                    fi
                    ;;
                after)
                    _scheduler_append_line after_block "$line"
                    ;;
            esac
        done <<< "$current"

        local new_crontab=""
        [[ -n "$before_block" ]] && _scheduler_append_line new_crontab "$before_block"
        _scheduler_append_line new_crontab "$in_block"
        [[ -n "$after_block" ]] && _scheduler_append_line new_crontab "$after_block"

        _scheduler_cron_write_crontab "$new_crontab"
    else
        local new_crontab=""
        [[ -n "$current" ]] && _scheduler_append_line new_crontab "$current"
        _scheduler_append_line new_crontab "$begin_marker"
        _scheduler_append_line new_crontab "$cron_line"
        _scheduler_append_line new_crontab "$end_marker"
        _scheduler_cron_write_crontab "$new_crontab"
    fi
}

_scheduler_cron_remove() {
    local job_id="${1:-}"
    local current
    current=$(_scheduler_cron_read_crontab)

    local begin_marker="# BEGIN shellia-scheduler"
    local end_marker="# END shellia-scheduler"
    local job_marker="shellia-scheduler:${job_id}"

    local before_block="" block_lines="" after_block=""
    local state="before"

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$state" in
            before)
                if [[ "$line" == "$begin_marker" ]]; then
                    state="inside"
                else
                    _scheduler_append_line before_block "$line"
                fi
                ;;
            inside)
                if [[ "$line" == "$end_marker" ]]; then
                    state="after"
                elif [[ "$line" != *"$job_marker"* ]]; then
                    _scheduler_append_line block_lines "$line"
                fi
                ;;
            after)
                _scheduler_append_line after_block "$line"
                ;;
        esac
    done <<< "$current"

    local new_crontab=""
    [[ -n "$before_block" ]] && _scheduler_append_line new_crontab "$before_block"

    if [[ -n "$block_lines" ]]; then
        _scheduler_append_line new_crontab "$begin_marker"
        _scheduler_append_line new_crontab "$block_lines"
        _scheduler_append_line new_crontab "$end_marker"
    fi
    [[ -n "$after_block" ]] && _scheduler_append_line new_crontab "$after_block"

    _scheduler_cron_write_crontab "$new_crontab"
}

_scheduler_dispatch() {
    local subcmd="${1:-}"
    shift 2>/dev/null || true

    case "$subcmd" in
        add)    _scheduler_cmd_add "$@" ;;
        list)   _scheduler_cmd_list ;;
        logs)   _scheduler_cmd_logs "$@" ;;
        run)    _scheduler_cmd_run "$@" ;;
        remove) _scheduler_cmd_remove "$@" ;;
        help)   _scheduler_cmd_help ;;
        *)      _scheduler_cmd_help ;;
    esac
}

_scheduler_cmd_help() {
    echo "Usage: schedule <subcommand> [options]"
    echo ""
    echo "Subcommands:"
    echo "  add      Schedule a new prompt"
    echo "  list     Show all scheduled jobs"
    echo "  logs     Show logs for a job"
    echo "  run      Execute a job wrapper immediately"
    echo "  remove   Remove a scheduled job"
    echo "  help     Show this help"
    echo ""
    echo "Options for 'add':"
    echo "  --at <YYYY-MM-DD HH:MM>   Run once at a specific time"
    echo "  --every <preset>           Run on a recurring preset (hourly|daily|weekly|monthly)"
    echo "  --cron <expression>        Run on a raw cron schedule (5-field)"
    echo "  --backend <choice>         Force backend (auto|launchd|cron)"
    echo "  --prompt <text>            The prompt to execute (required, consumes remaining args)"
}

_scheduler_cmd_add() {
    local at_datetime="" every_preset="" cron_expr="" backend_choice="auto" prompt_text=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --at)
                shift
                if [[ $# -ge 2 && "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && "$2" =~ ^[0-9]{2}:[0-9]{2}$ ]]; then
                    at_datetime="$1 $2"
                    shift 2
                elif [[ $# -ge 1 ]]; then
                    at_datetime="$1"
                    shift
                fi
                ;;
            --every)
                shift
                every_preset="${1:-}"
                shift 2>/dev/null || true
                ;;
            --cron)
                shift
                cron_expr="${1:-}"
                shift 2>/dev/null || true
                ;;
            --backend)
                shift
                backend_choice="${1:-auto}"
                shift 2>/dev/null || true
                ;;
            --prompt)
                shift
                prompt_text="$*"
                break
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ -z "$prompt_text" ]]; then
        echo "error: --prompt is required" >&2
        return 1
    fi

    local schedule_type="" schedule_value=""

    if [[ -n "$at_datetime" ]]; then
        if ! _scheduler_validate_at "$at_datetime"; then
            return 1
        fi
        schedule_type="once"
        schedule_value="$at_datetime"
    elif [[ -n "$every_preset" ]]; then
        if ! _scheduler_validate_every "$every_preset"; then
            return 1
        fi
        schedule_type="recurring"
        schedule_value=$(_scheduler_normalize_schedule "recurring" "$every_preset")
    elif [[ -n "$cron_expr" ]]; then
        if ! _scheduler_validate_cron "$cron_expr"; then
            return 1
        fi
        schedule_type="recurring"
        schedule_value="$cron_expr"
    else
        echo "error: one of --at, --every, or --cron is required" >&2
        return 1
    fi

    local backend
    backend=$(_scheduler_resolve_backend "$backend_choice") || return 1

    _scheduler_ensure_dirs

    local job_id
    job_id=$(_scheduler_create_job "$schedule_type" "$schedule_value" "$backend" "$prompt_text") || return 1

    _scheduler_render_wrapper "$job_id"

    _scheduler_backend_install "$backend" "$job_id"

    echo "Job ${job_id} scheduled (${schedule_type}, backend: ${backend})"
}

_scheduler_cmd_list() {
    _scheduler_ensure_dirs

    local jsonl
    jsonl=$(_scheduler_list_jobs)
    if [[ -z "$jsonl" ]]; then
        echo "No scheduled jobs."
        return 0
    fi

    printf "%-30s %-10s %-20s %-8s %-8s %-10s %s\n" \
        "ID" "TYPE" "SCHEDULE" "BACKEND" "ENABLED" "STATUS" "PROMPT"
    printf "%-30s %-10s %-20s %-8s %-8s %-10s %s\n" \
        "---" "----" "--------" "-------" "-------" "------" "------"

    echo "$jsonl" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local id stype svalue backend enabled status prompt
        id=$(echo "$line" | jq -r '.id')
        stype=$(echo "$line" | jq -r '.schedule_type')
        svalue=$(echo "$line" | jq -r '.schedule_value')
        backend=$(echo "$line" | jq -r '.backend')
        enabled=$(echo "$line" | jq -r '.enabled')
        status=$(echo "$line" | jq -r '.last_status')
        prompt=$(echo "$line" | jq -r '.prompt')

        [[ "$status" == "" || "$status" == "null" ]] && status="-"
        printf "%-30s %-10s %-20s %-8s %-8s %-10s %s\n" \
            "$id" "$stype" "$svalue" "$backend" "$enabled" "$status" "$prompt"
    done
}

_scheduler_cmd_logs() {
    local job_id="${1:-}"

    if [[ -z "$job_id" ]]; then
        echo "error: job id required" >&2
        return 1
    fi

    _scheduler_ensure_dirs

    local log_file="$(_scheduler_dir_logs)/${job_id}.log"

    if [[ ! -f "$log_file" ]] || [[ ! -s "$log_file" ]]; then
        echo "No logs for job ${job_id}."
        return 0
    fi

    cat "$log_file"
}

_scheduler_cmd_run() {
    local job_id="${1:-}"

    if [[ -z "$job_id" ]]; then
        echo "error: job id required" >&2
        return 1
    fi

    _scheduler_ensure_dirs

    local job_json
    job_json=$(_scheduler_read_job "$job_id") || return 1

    local wrapper_file
    wrapper_file=$(echo "$job_json" | jq -r '.wrapper_file')

    if [[ ! -f "$wrapper_file" ]]; then
        echo "error: wrapper script not found for job ${job_id}" >&2
        return 1
    fi

    echo "Running job ${job_id}..."
    bash "$wrapper_file"
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo "Job ${job_id} completed successfully."
    else
        echo "Job ${job_id} failed with exit code ${exit_code}."
    fi
}

_scheduler_cmd_remove() {
    local job_id="${1:-}"

    if [[ -z "$job_id" ]]; then
        echo "error: job id required" >&2
        return 1
    fi

    _scheduler_ensure_dirs

    local job_json
    job_json=$(_scheduler_read_job "$job_id") || return 1

    local backend wrapper_file
    backend=$(echo "$job_json" | jq -r '.backend')
    wrapper_file=$(echo "$job_json" | jq -r '.wrapper_file')

    _scheduler_backend_remove "$backend" "$job_id"

    rm -f "$wrapper_file"

    _scheduler_delete_job_file "$job_id"

    echo "Removed job ${job_id}."
}

_scheduler_backend_install() {
    local backend="${1:-}"
    local job_id="${2:-}"
    case "$backend" in
        launchd)
            _scheduler_launchd_render_plist "$job_id" && _scheduler_launchd_install "$job_id"
            ;;
        cron)
            _scheduler_cron_install "$job_id"
            ;;
    esac
}

_scheduler_backend_remove() {
    local backend="${1:-}"
    local job_id="${2:-}"
    case "$backend" in
        launchd) _scheduler_launchd_remove "$job_id" ;;
        cron)    _scheduler_cron_remove "$job_id" ;;
    esac
}

cli_cmd_schedule_handler() {
    _scheduler_dispatch "$@"
}

cli_cmd_schedule_help() {
    echo "  schedule <action>         Manage scheduled prompts (add|list|run|logs|remove)"
}

cli_cmd_schedule_setup() {
    echo "config theme plugins"
}

repl_cmd_schedule_handler() {
    local input="${1:-}"
    local args_array=()
    read -ra args_array <<< "$input"
    _scheduler_dispatch "${args_array[@]+"${args_array[@]}"}"
}

repl_cmd_schedule_help() {
    echo -e "  ${THEME_ACCENT:-}schedule${NC:-}          Manage scheduled prompts"
}
