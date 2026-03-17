#!/usr/bin/env bash

_sched_base_dir() {
    echo "${SHELLIA_CONFIG_DIR}/scheduler"
}

_sched_jobs_file() {
    echo "$(_sched_base_dir)/jobs.json"
}

_sched_logs_dir() {
    echo "$(_sched_base_dir)/logs"
}

_sched_ensure_dirs() {
    mkdir -p "$(_sched_base_dir)" "$(_sched_logs_dir)"
    local jobs_file
    jobs_file=$(_sched_jobs_file)
    if [[ ! -f "$jobs_file" ]]; then
        printf '[]\n' > "$jobs_file"
    fi
}

_sched_generate_id() {
    local label="${1:-job}"
    local id
    id=$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
    [[ -z "$id" ]] && id="job"
    echo "${id}-$$"
}

_sched_validate_at() {
    local datetime="${1:-}"
    [[ "$datetime" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]
}

_sched_validate_cron() {
    local expression="${1:-}"
    [[ -z "$expression" ]] && return 1
    local fields
    read -ra fields <<< "$expression"
    [[ "${#fields[@]}" -eq 5 ]] || return 1
    local f
    for f in "${fields[@]}"; do
        [[ "$f" =~ ^[0-9\*\/,\-]+$ ]] || return 1
    done
}

_sched_normalize_every() {
    case "${1:-}" in
        hourly) echo "0 * * * *" ;;
        daily) echo "0 0 * * *" ;;
        weekly) echo "0 0 * * 0" ;;
        monthly) echo "0 0 1 * *" ;;
        *) return 1 ;;
    esac
}

_sched_detect_backend() {
    local os_name="${1:-$(uname -s)}"
    if [[ "$os_name" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
        echo "launchd"
    else
        echo "cron"
    fi
}

_sched_resolve_backend() {
    local choice="${1:-auto}"
    local os_name="${2:-$(uname -s)}"
    case "$choice" in
        auto) _sched_detect_backend "$os_name" ;;
        launchd)
            command -v launchctl >/dev/null 2>&1 || return 1
            echo "launchd"
            ;;
        cron)
            command -v crontab >/dev/null 2>&1 || return 1
            echo "cron"
            ;;
        *) return 1 ;;
    esac
}

_sched_list_jobs() {
    _sched_ensure_dirs
    cat "$(_sched_jobs_file)"
}

_sched_get_job() {
    local job_id="${1:-}"
    _sched_ensure_dirs
    jq -cer --arg id "$job_id" '.[] | select(.id == $id)' "$(_sched_jobs_file)" 2>/dev/null
}

_sched_add_job() {
    local schedule_type="${1:-}"
    local schedule_value="${2:-}"
    local backend="${3:-}"
    local prompt="${4:-}"
    _sched_ensure_dirs

    local job_id created_at log_file
    job_id=$(_sched_generate_id "$prompt")
    created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    log_file="$(_sched_logs_dir)/${job_id}.log"

    local jobs_file
    jobs_file=$(_sched_jobs_file)
    local tmp
    tmp=$(mktemp)

    jq -c \
        --arg id "$job_id" \
        --arg prompt "$prompt" \
        --arg backend "$backend" \
        --arg st "$schedule_type" \
        --arg sv "$schedule_value" \
        --arg ca "$created_at" \
        --arg lf "$log_file" \
        '. + [{id:$id,prompt:$prompt,backend:$backend,schedule_type:$st,schedule_value:$sv,created_at:$ca,enabled:true,log_file:$lf,artifact_ref:""}]' \
        "$jobs_file" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$jobs_file"
    echo "$job_id"
}

_sched_remove_job() {
    local job_id="${1:-}"
    _sched_ensure_dirs
    local jobs_file tmp
    jobs_file=$(_sched_jobs_file)
    tmp=$(mktemp)
    jq -c --arg id "$job_id" '[.[] | select(.id != $id)]' "$jobs_file" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$jobs_file"
}

_sched_update_job_field() {
    local job_id="${1:-}"
    local field="${2:-}"
    local value="${3:-}"
    _sched_ensure_dirs
    local jobs_file tmp
    jobs_file=$(_sched_jobs_file)
    tmp=$(mktemp)
    jq -c --arg id "$job_id" --arg f "$field" --arg v "$value" 'map(if .id == $id then .[$f] = $v else . end)' "$jobs_file" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$jobs_file"
}
