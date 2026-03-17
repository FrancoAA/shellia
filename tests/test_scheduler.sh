#!/usr/bin/env bash

source "${PROJECT_DIR}/scripts/scheduler/common.sh"

test_sched_generate_id_returns_safe_identifier() {
    local id
    id=$(_sched_generate_id "My Cool Job")
    assert_not_empty "$id" "generated scheduler id is not empty"

    local cleaned
    cleaned=$(echo "$id" | tr -d 'a-zA-Z0-9-')
    assert_eq "$cleaned" "" "generated scheduler id is filesystem-safe"
}

test_sched_ensure_dirs_creates_layout() {
    _sched_ensure_dirs
    assert_eq "$(test -d "$(_sched_base_dir)" && echo yes)" "yes" "scheduler base dir exists"
    assert_eq "$(test -d "$(_sched_logs_dir)" && echo yes)" "yes" "scheduler logs dir exists"
    assert_file_exists "$(_sched_jobs_file)" "scheduler jobs.json exists"
}

test_sched_validate_at_checks_datetime_format() {
    _sched_validate_at "2026-03-20 09:00"
    assert_eq "$?" "0" "validate_at accepts valid datetime"

    local code=0
    _sched_validate_at "bad-date" || code=$?
    assert_eq "$code" "1" "validate_at rejects invalid datetime"
}

test_sched_validate_cron_checks_expression_format() {
    _sched_validate_cron "0 9 * * 1"
    assert_eq "$?" "0" "validate_cron accepts valid cron"

    local code=0
    _sched_validate_cron "0 9 * *" || code=$?
    assert_eq "$code" "1" "validate_cron rejects invalid cron"
}

test_sched_normalize_every_maps_presets() {
    assert_eq "$(_sched_normalize_every hourly)" "0 * * * *" "normalize hourly"
    assert_eq "$(_sched_normalize_every daily)" "0 0 * * *" "normalize daily"
    assert_eq "$(_sched_normalize_every weekly)" "0 0 * * 0" "normalize weekly"
    assert_eq "$(_sched_normalize_every monthly)" "0 0 1 * *" "normalize monthly"
}

test_sched_add_and_get_job_round_trip() {
    local job_id
    job_id=$(_sched_add_job "recurring" "0 0 * * *" "cron" "check disk")
    assert_not_empty "$job_id" "add_job returns id"

    local job
    job=$(_sched_get_job "$job_id")
    assert_valid_json "$job" "get_job returns valid JSON"
    assert_eq "$(echo "$job" | jq -r '.prompt')" "check disk" "job prompt matches"
    assert_eq "$(echo "$job" | jq -r '.backend')" "cron" "job backend matches"
}

test_sched_list_jobs_returns_all_jobs() {
    _sched_add_job "recurring" "0 0 * * *" "cron" "job one" >/dev/null
    _sched_add_job "once" "2026-03-20 09:00" "launchd" "job two" >/dev/null

    local jobs
    jobs=$(_sched_list_jobs)
    assert_valid_json "$jobs" "list_jobs returns valid JSON"
    assert_eq "$(echo "$jobs" | jq 'length')" "2" "list_jobs returns both jobs"
}

test_sched_remove_job_deletes_entry() {
    local job_id
    job_id=$(_sched_add_job "recurring" "0 0 * * *" "cron" "remove me")
    _sched_remove_job "$job_id"

    local jobs
    jobs=$(_sched_list_jobs)
    assert_eq "$(echo "$jobs" | jq 'length')" "0" "remove_job deletes entry"
}

test_sched_detect_backend_prefers_launchd_on_darwin() {
    command() {
        if [[ "${2:-}" == "launchctl" ]]; then
            return 0
        fi
        builtin command "$@"
    }

    assert_eq "$(_sched_detect_backend Darwin)" "launchd" "detect_backend uses launchd on Darwin"
    unset -f command
}

test_sched_detect_backend_uses_cron_on_linux() {
    assert_eq "$(_sched_detect_backend Linux)" "cron" "detect_backend uses cron on Linux"
}

test_sched_darwin_install_writes_plist_and_loads_launchctl() {
    source "${PROJECT_DIR}/scripts/scheduler/darwin.sh"
    local launchctl_calls=""
    launchctl() {
        launchctl_calls="${launchctl_calls}$*\n"
        return 0
    }

    local job_id
    job_id=$(_sched_add_job "once" "2026-07-15 14:30" "launchd" "hello launchd")
    _sched_darwin_install "$job_id"

    local plist_file
    plist_file=$(_sched_darwin_plist_file "$job_id")
    assert_file_exists "$plist_file" "darwin install creates plist"

    local plist
    plist=$(cat "$plist_file")
    assert_contains "$plist" "com.shellia.scheduler.${job_id}" "plist contains scheduler label"
    assert_contains "$plist" "${SHELLIA_DIR}/shellia" "plist uses shellia executable"
    assert_contains "$plist" "hello launchd" "plist passes prompt"
    assert_contains "$plist" "StandardOutPath" "plist includes stdout path"
    assert_contains "$plist" "StandardErrorPath" "plist includes stderr path"
    assert_contains "$launchctl_calls" "load" "darwin install calls launchctl load"

    unset -f launchctl
}

test_sched_darwin_remove_unloads_and_deletes_plist() {
    source "${PROJECT_DIR}/scripts/scheduler/darwin.sh"
    local launchctl_calls=""
    launchctl() {
        launchctl_calls="${launchctl_calls}$*\n"
        return 0
    }

    local job_id
    job_id=$(_sched_add_job "recurring" "0 0 * * *" "launchd" "remove me")
    _sched_darwin_install "$job_id"
    local plist_file
    plist_file=$(_sched_darwin_plist_file "$job_id")

    _sched_darwin_remove "$job_id"
    assert_eq "$(test -f "$plist_file" && echo yes || echo no)" "no" "darwin remove deletes plist"
    assert_contains "$launchctl_calls" "unload" "darwin remove calls launchctl unload"

    unset -f launchctl
}

test_sched_cron_install_adds_managed_block_and_preserves_lines() {
    source "${PROJECT_DIR}/scripts/scheduler/linux.sh"
    local test_crontab_content="MAILTO=me@example.com"
    local test_crontab_last_write=""

    crontab() {
        if [[ "${1:-}" == "-l" ]]; then
            printf '%s\n' "$test_crontab_content"
            return 0
        fi
        if [[ "${1:-}" == "-" ]]; then
            test_crontab_last_write=$(cat)
            test_crontab_content="$test_crontab_last_write"
            return 0
        fi
        return 1
    }

    local job_id
    job_id=$(_sched_add_job "recurring" "0 9 * * 1" "cron" "weekly report")
    _sched_cron_install "$job_id"

    assert_contains "$test_crontab_last_write" "# BEGIN shellia-scheduler" "cron install writes begin marker"
    assert_contains "$test_crontab_last_write" "# END shellia-scheduler" "cron install writes end marker"
    assert_contains "$test_crontab_last_write" "shellia-scheduler:${job_id}" "cron install writes job marker"
    assert_contains "$test_crontab_last_write" "MAILTO=me@example.com" "cron install preserves user lines"

    unset -f crontab
}

test_sched_cron_remove_deletes_job_and_drops_empty_block() {
    source "${PROJECT_DIR}/scripts/scheduler/linux.sh"
    local test_crontab_content=""
    local test_crontab_last_write=""

    crontab() {
        if [[ "${1:-}" == "-l" ]]; then
            printf '%s\n' "$test_crontab_content"
            return 0
        fi
        if [[ "${1:-}" == "-" ]]; then
            test_crontab_last_write=$(cat)
            test_crontab_content="$test_crontab_last_write"
            return 0
        fi
        return 1
    }

    local job_id
    job_id=$(_sched_add_job "recurring" "0 0 * * *" "cron" "daily")
    _sched_cron_install "$job_id"
    _sched_cron_remove "$job_id"

    assert_not_contains "$test_crontab_last_write" "shellia-scheduler:${job_id}" "cron remove deletes job line"
    assert_not_contains "$test_crontab_last_write" "# BEGIN shellia-scheduler" "cron remove drops empty begin marker"
    assert_not_contains "$test_crontab_last_write" "# END shellia-scheduler" "cron remove drops empty end marker"

    unset -f crontab
}
