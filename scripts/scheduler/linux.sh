#!/usr/bin/env bash

_sched_cron_read() {
    local content
    content=$(crontab -l 2>/dev/null) || true
    printf '%s' "$content"
}

_sched_cron_write() {
    local content="${1:-}"
    crontab - <<< "$content"
}

_sched_shell_quote() {
    local value="${1:-}"
    printf '%q' "$value"
}

_sched_cron_line_for_job() {
    local job_id="${1:-}"
    local job
    job=$(_sched_get_job "$job_id") || return 1

    local schedule_type schedule_value prompt log_file shellia_cmd cron_expr
    schedule_type=$(echo "$job" | jq -r '.schedule_type')
    schedule_value=$(echo "$job" | jq -r '.schedule_value')
    prompt=$(echo "$job" | jq -r '.prompt')
    log_file=$(echo "$job" | jq -r '.log_file')
    shellia_cmd="${SHELLIA_DIR}/shellia"

    if [[ "$schedule_type" == "once" ]]; then
        local date_part="${schedule_value%% *}"
        local time_part="${schedule_value##* }"
        local md="${date_part#*-}"
        local month="${md%%-*}"
        local day="${md##*-}"
        local hour="${time_part%%:*}"
        local minute="${time_part##*:}"
        cron_expr="$((10#$minute)) $((10#$hour)) $((10#$day)) $((10#$month)) *"
    else
        cron_expr="$schedule_value"
    fi

    local quoted_prompt quoted_log quoted_cmd
    quoted_prompt=$(_sched_shell_quote "$prompt")
    quoted_log=$(_sched_shell_quote "$log_file")
    quoted_cmd=$(_sched_shell_quote "$shellia_cmd")

    echo "${cron_expr} ${quoted_cmd} ${quoted_prompt} >> ${quoted_log} 2>&1 # shellia-scheduler:${job_id}"
}

_sched_cron_install() {
    local job_id="${1:-}"
    local cron_line
    cron_line=$(_sched_cron_line_for_job "$job_id") || return 1

    local current
    current=$(_sched_cron_read)
    local begin="# BEGIN shellia-scheduler"
    local end="# END shellia-scheduler"

    local new=""
    if [[ "$current" == *"$begin"* ]]; then
        local before="" inside="" after=""
        local state="before"
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$state" in
                before)
                    if [[ "$line" == "$begin" ]]; then
                        state="inside"
                        inside="$begin"
                    else
                        [[ -z "$before" ]] && before="$line" || before="${before}\n${line}"
                    fi
                    ;;
                inside)
                    if [[ "$line" == "$end" ]]; then
                        state="after"
                        inside="${inside}\n${cron_line}\n${end}"
                    else
                        inside="${inside}\n${line}"
                    fi
                    ;;
                after)
                    [[ -z "$after" ]] && after="$line" || after="${after}\n${line}"
                    ;;
            esac
        done <<< "$current"
        [[ -n "$before" ]] && new="$before\n$inside" || new="$inside"
        [[ -n "$after" ]] && new="$new\n$after"
    else
        [[ -n "$current" ]] && new="$current\n"
        new="${new}${begin}\n${cron_line}\n${end}"
    fi

    _sched_cron_write "$(printf '%b' "$new")"
    _sched_update_job_field "$job_id" "artifact_ref" "shellia-scheduler:${job_id}" >/dev/null
}

_sched_cron_remove() {
    local job_id="${1:-}"
    local marker="shellia-scheduler:${job_id}"
    local current
    current=$(_sched_cron_read)
    local begin="# BEGIN shellia-scheduler"
    local end="# END shellia-scheduler"
    local before="" block="" after=""
    local state="before"

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$state" in
            before)
                if [[ "$line" == "$begin" ]]; then
                    state="inside"
                else
                    [[ -z "$before" ]] && before="$line" || before="${before}\n${line}"
                fi
                ;;
            inside)
                if [[ "$line" == "$end" ]]; then
                    state="after"
                elif [[ "$line" != *"$marker"* ]]; then
                    [[ -z "$block" ]] && block="$line" || block="${block}\n${line}"
                fi
                ;;
            after)
                [[ -z "$after" ]] && after="$line" || after="${after}\n${line}"
                ;;
        esac
    done <<< "$current"

    local new=""
    [[ -n "$before" ]] && new="$before"
    if [[ -n "$block" ]]; then
        [[ -n "$new" ]] && new="$new\n"
        new="${new}${begin}\n${block}\n${end}"
    fi
    if [[ -n "$after" ]]; then
        [[ -n "$new" ]] && new="$new\n"
        new="${new}${after}"
    fi

    _sched_cron_write "$(printf '%b' "$new")"
}
