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

# === Job metadata CRUD ===
# All job state is stored as JSON files under jobs/<id>.json.
# Uses jq for all JSON operations.

# Create a new job and write its metadata to disk.
# Usage: _scheduler_create_job <schedule_type> <schedule_value> <backend> <prompt>
# Echoes the new job id. Returns 1 on failure.
_scheduler_create_job() {
    local schedule_type="${1:-}"
    local schedule_value="${2:-}"
    local backend="${3:-}"
    local prompt="${4:-}"

    # Generate a filesystem-safe id from the prompt
    local job_id
    job_id=$(_scheduler_generate_id "$prompt")

    # Derive paths from the id
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

    local job_file="$(_scheduler_dir_jobs)/${job_id}.json"

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

# Read a job's metadata by id.
# Usage: _scheduler_read_job <job_id>
# Echoes the JSON. Returns 1 if not found.
_scheduler_read_job() {
    local job_id="${1:-}"
    local job_file="$(_scheduler_dir_jobs)/${job_id}.json"

    if [[ ! -f "$job_file" ]]; then
        echo "error: job '${job_id}' not found" >&2
        return 1
    fi

    cat "$job_file"
}

# Update a single field in a job's metadata.
# Usage: _scheduler_update_job <job_id> <field> <value>
# Writes atomically (temp file + mv). Returns 1 if job not found.
_scheduler_update_job() {
    local job_id="${1:-}"
    local field="${2:-}"
    local value="${3:-}"
    local job_file="$(_scheduler_dir_jobs)/${job_id}.json"

    if [[ ! -f "$job_file" ]]; then
        echo "error: job '${job_id}' not found" >&2
        return 1
    fi

    local tmp_file="${job_file}.tmp"

    # Use jq to update the field; attempt numeric parse, fall back to string
    if printf '%s' "$value" | jq -e 'tonumber' >/dev/null 2>&1; then
        jq --arg f "$field" --argjson v "$value" '.[$f] = $v' "$job_file" > "$tmp_file" || return 1
    else
        jq --arg f "$field" --arg v "$value" '.[$f] = $v' "$job_file" > "$tmp_file" || return 1
    fi

    mv "$tmp_file" "$job_file"
}

# List all jobs as JSONL (one JSON object per line).
# Usage: _scheduler_list_jobs
# Outputs nothing if no jobs exist.
_scheduler_list_jobs() {
    local jobs_dir="$(_scheduler_dir_jobs)"
    local found=false

    for f in "$jobs_dir"/*.json; do
        [[ -f "$f" ]] || continue
        found=true
        cat "$f"
    done

    if ! $found; then
        return 0
    fi
}

# Delete a job's metadata file.
# Usage: _scheduler_delete_job_file <job_id>
# Returns 1 if the file does not exist.
_scheduler_delete_job_file() {
    local job_id="${1:-}"
    local job_file="$(_scheduler_dir_jobs)/${job_id}.json"

    if [[ ! -f "$job_file" ]]; then
        echo "error: job '${job_id}' not found" >&2
        return 1
    fi

    rm "$job_file"
}

# === Logging helper ===
# Appends a timestamped line to a job's log file.
# Usage: _scheduler_log_entry <job_id> <message>

_scheduler_log_entry() {
    local job_id="${1:-}"
    local message="${2:-}"
    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    echo "[${timestamp}] ${message}" >> "$log_file"
}

# === Wrapper script generation ===
# Generates a self-contained shell script that launchd/cron will invoke.
# The wrapper uses jq directly to read/update job JSON — no sourcing of
# shellia internals required.
# Usage: _scheduler_render_wrapper <job_id>

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

# === Launchd backend helpers ===
# Render, install, and remove launchd plist files for scheduled jobs.

# Return the launchd label for a job.
# Usage: _scheduler_launchd_label <job_id>
_scheduler_launchd_label() {
    local job_id="${1:-}"
    echo "com.shellia.scheduler.${job_id}"
}

# Generate a launchd plist XML file for a job.
# Usage: _scheduler_launchd_render_plist <job_id>
# Reads job metadata to determine schedule_type, schedule_value, and paths.
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

    # Build the StartCalendarInterval dict entries
    local calendar_entries=""

    if [[ "$schedule_type" == "once" ]]; then
        # Parse "YYYY-MM-DD HH:MM" into components
        local date_part="${schedule_value%% *}"
        local time_part="${schedule_value##* }"
        local year month day hour minute
        year="${date_part%%-*}"
        local md="${date_part#*-}"
        month="${md%%-*}"
        day="${md##*-}"
        hour="${time_part%%:*}"
        minute="${time_part##*:}"

        # Strip leading zeros for integer values
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
        # Parse cron expression: minute hour day_of_month month weekday
        local fields
        read -ra fields <<< "$schedule_value"
        local cron_min="${fields[0]:-*}"
        local cron_hour="${fields[1]:-*}"
        local cron_dom="${fields[2]:-*}"
        local cron_month="${fields[3]:-*}"
        local cron_dow="${fields[4]:-*}"

        # Map non-wildcard cron fields to launchd keys
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

        # Remove trailing newline from calendar_entries
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

# Load a job's plist with launchctl.
# Usage: _scheduler_launchd_install <job_id>
_scheduler_launchd_install() {
    local job_id="${1:-}"
    local plist_file="$(_scheduler_dir_launchd)/${job_id}.plist"

    launchctl load "$plist_file"
}

# Unload a job's plist and delete the file.
# Usage: _scheduler_launchd_remove <job_id>
# Ignores errors on unload (job may already be unloaded).
_scheduler_launchd_remove() {
    local job_id="${1:-}"
    local plist_file="$(_scheduler_dir_launchd)/${job_id}.plist"

    launchctl unload "$plist_file" 2>/dev/null || true
    rm -f "$plist_file"
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
