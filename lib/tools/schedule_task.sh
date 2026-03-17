#!/usr/bin/env bash

tool_schedule_task_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "schedule_task",
        "description": "Schedule, list, or remove shellia prompt jobs using OS schedulers (launchd on macOS, cron on Linux).",
        "parameters": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "description": "Operation to perform",
                    "enum": ["add", "list", "remove"]
                },
                "prompt": {
                    "type": "string",
                    "description": "Prompt text to execute when the schedule triggers"
                },
                "schedule_type": {
                    "type": "string",
                    "description": "Schedule mode for add",
                    "enum": ["once", "recurring"]
                },
                "schedule_value": {
                    "type": "string",
                    "description": "Datetime (YYYY-MM-DD HH:MM), preset (hourly/daily/weekly/monthly), or 5-field cron expression"
                },
                "backend": {
                    "type": "string",
                    "description": "Scheduler backend override",
                    "enum": ["auto", "launchd", "cron"]
                },
                "job_id": {
                    "type": "string",
                    "description": "Job identifier for remove"
                }
            },
            "required": ["action"]
        }
    }
}
EOF
}

_schedule_task_load_backends() {
    source "${SHELLIA_DIR}/scripts/scheduler/common.sh"
    case "$(uname -s)" in
        Darwin) source "${SHELLIA_DIR}/scripts/scheduler/darwin.sh" ;;
        *) source "${SHELLIA_DIR}/scripts/scheduler/linux.sh" ;;
    esac
}

tool_schedule_task_execute() {
    local args_json="$1"
    local action prompt schedule_type schedule_value backend job_id
    action=$(echo "$args_json" | jq -r '.action // empty')
    prompt=$(echo "$args_json" | jq -r '.prompt // empty')
    schedule_type=$(echo "$args_json" | jq -r '.schedule_type // empty')
    schedule_value=$(echo "$args_json" | jq -r '.schedule_value // empty')
    backend=$(echo "$args_json" | jq -r '.backend // "auto"')
    job_id=$(echo "$args_json" | jq -r '.job_id // empty')

    _schedule_task_load_backends
    _sched_ensure_dirs

    case "$action" in
        add)
            if [[ -z "$prompt" ]]; then
                echo "Error: 'prompt' is required for action=add"
                return 1
            fi
            if [[ "$schedule_type" != "once" && "$schedule_type" != "recurring" ]]; then
                echo "Error: 'schedule_type' must be 'once' or 'recurring'"
                return 1
            fi
            if [[ "$schedule_type" == "once" ]]; then
                if ! _sched_validate_at "$schedule_value"; then
                    echo "Error: invalid once schedule format; use YYYY-MM-DD HH:MM"
                    return 1
                fi
            else
                if ! _sched_validate_cron "$schedule_value"; then
                    schedule_value=$(_sched_normalize_every "$schedule_value" 2>/dev/null) || {
                        echo "Error: invalid recurring schedule; use cron or preset"
                        return 1
                    }
                fi
            fi

            local resolved_backend
            resolved_backend=$(_sched_resolve_backend "$backend") || {
                echo "Error: backend '$backend' is unavailable"
                return 1
            }

            local created_id
            created_id=$(_sched_add_job "$schedule_type" "$schedule_value" "$resolved_backend" "$prompt") || return 1

            if [[ "$resolved_backend" == "launchd" ]]; then
                _sched_darwin_install "$created_id" || return 1
            else
                _sched_cron_install "$created_id" || return 1
            fi

            jq -cn --arg id "$created_id" --arg backend "$resolved_backend" --arg schedule_type "$schedule_type" --arg schedule_value "$schedule_value" '{ok:true, action:"add", id:$id, backend:$backend, schedule_type:$schedule_type, schedule_value:$schedule_value}'
            ;;
        list)
            _sched_list_jobs
            ;;
        remove)
            if [[ -z "$job_id" ]]; then
                echo "Error: 'job_id' is required for action=remove"
                return 1
            fi
            local job
            job=$(_sched_get_job "$job_id") || {
                echo "Error: job '${job_id}' not found"
                return 1
            }
            local job_backend
            job_backend=$(echo "$job" | jq -r '.backend')
            if [[ "$job_backend" == "launchd" ]]; then
                _sched_darwin_remove "$job_id"
            else
                _sched_cron_remove "$job_id"
            fi
            _sched_remove_job "$job_id"
            jq -cn --arg id "$job_id" '{ok:true, action:"remove", id:$id}'
            ;;
        *)
            echo "Error: action must be one of add, list, remove"
            return 1
            ;;
    esac
}
