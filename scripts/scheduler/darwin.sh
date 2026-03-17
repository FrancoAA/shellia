#!/usr/bin/env bash

_sched_darwin_plist_dir() {
    echo "$(_sched_base_dir)/launchd"
}

_sched_darwin_plist_file() {
    local job_id="${1:-}"
    echo "$(_sched_darwin_plist_dir)/${job_id}.plist"
}

_sched_darwin_label() {
    local job_id="${1:-}"
    echo "com.shellia.scheduler.${job_id}"
}

_sched_darwin_calendar_entries() {
    local schedule_type="${1:-}"
    local schedule_value="${2:-}"
    local entries=""

    if [[ "$schedule_type" == "once" ]]; then
        local date_part="${schedule_value%% *}"
        local time_part="${schedule_value##* }"
        local md="${date_part#*-}"
        local month="${md%%-*}"
        local day="${md##*-}"
        local hour="${time_part%%:*}"
        local minute="${time_part##*:}"
        month=$((10#$month))
        day=$((10#$day))
        hour=$((10#$hour))
        minute=$((10#$minute))
        entries="            <key>Month</key>\n            <integer>${month}</integer>\n            <key>Day</key>\n            <integer>${day}</integer>\n            <key>Hour</key>\n            <integer>${hour}</integer>\n            <key>Minute</key>\n            <integer>${minute}</integer>"
    else
        local fields
        read -ra fields <<< "$schedule_value"
        local min="${fields[0]:-*}"
        local hour="${fields[1]:-*}"
        local day="${fields[2]:-*}"
        local month="${fields[3]:-*}"
        local dow="${fields[4]:-*}"

        if [[ "$min" != "*" ]]; then
            entries="${entries}            <key>Minute</key>\n            <integer>$((10#$min))</integer>\n"
        fi
        if [[ "$hour" != "*" ]]; then
            entries="${entries}            <key>Hour</key>\n            <integer>$((10#$hour))</integer>\n"
        fi
        if [[ "$day" != "*" ]]; then
            entries="${entries}            <key>Day</key>\n            <integer>$((10#$day))</integer>\n"
        fi
        if [[ "$month" != "*" ]]; then
            entries="${entries}            <key>Month</key>\n            <integer>$((10#$month))</integer>\n"
        fi
        if [[ "$dow" != "*" ]]; then
            entries="${entries}            <key>Weekday</key>\n            <integer>$((10#$dow))</integer>\n"
        fi
        entries=$(printf '%s' "$entries" | sed '$s/\n$//')
    fi

    printf '%b' "$entries"
}

_sched_darwin_install() {
    local job_id="${1:-}"
    local job
    job=$(_sched_get_job "$job_id") || return 1

    mkdir -p "$(_sched_darwin_plist_dir)"

    local prompt log_file schedule_type schedule_value label plist_file shellia_cmd cal
    prompt=$(echo "$job" | jq -r '.prompt')
    log_file=$(echo "$job" | jq -r '.log_file')
    schedule_type=$(echo "$job" | jq -r '.schedule_type')
    schedule_value=$(echo "$job" | jq -r '.schedule_value')
    label=$(_sched_darwin_label "$job_id")
    plist_file=$(_sched_darwin_plist_file "$job_id")
    shellia_cmd="${SHELLIA_DIR}/shellia"
    cal=$(_sched_darwin_calendar_entries "$schedule_type" "$schedule_value")

    cat > "$plist_file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${shellia_cmd}</string>
        <string>${prompt}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
${cal}
    </dict>
    <key>StandardOutPath</key>
    <string>${log_file}</string>
    <key>StandardErrorPath</key>
    <string>${log_file}</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST

    launchctl load "$plist_file"
    _sched_update_job_field "$job_id" "artifact_ref" "$label" >/dev/null
}

_sched_darwin_remove() {
    local job_id="${1:-}"
    local plist_file
    plist_file=$(_sched_darwin_plist_file "$job_id")
    launchctl unload "$plist_file" 2>/dev/null || true
    rm -f "$plist_file"
}
