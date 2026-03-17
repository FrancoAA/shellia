# Scheduler Plugin Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a built-in `scheduler` plugin that can persistently schedule one-shot and recurring prompts using `launchd` or `cron`, with per-job logs and status tracking.

**Architecture:** Implement a new plugin at `lib/plugins/scheduler/plugin.sh` that owns job metadata, CLI and REPL command handling, backend adapters for `launchd` and `cron`, and wrapper-script generation. Store jobs in config-backed JSON files, render backend artifacts from that source of truth, and route every scheduled execution through a generated wrapper that logs results and updates job status.

**Tech Stack:** Bash 3.2+, shellia plugin hooks, `jq`, `launchctl`, `crontab`, existing shell test runner (`tests/run_tests.sh`).

---

### Task 1: Add scheduler plugin discovery and command coverage

**Files:**
- Modify: `tests/test_plugins.sh`
- Modify: `README.md`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing tests**

Add tests to `tests/test_plugins.sh` that call `load_builtin_plugins` and assert:

- `scheduler` is loaded
- `cli_cmd_schedule_handler` exists
- `cli_cmd_schedule_help` exists
- `repl_cmd_schedule_handler` exists
- `repl_cmd_schedule_help` exists

```bash
test_load_builtin_plugins_includes_scheduler() {
    _reset_plugin_state
    load_builtin_plugins
    _plugin_is_loaded "scheduler"
    assert_eq "$?" "0" "load_builtin_plugins loads scheduler plugin"
}
```

**Step 2: Run test to verify it fails**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL because `lib/plugins/scheduler/plugin.sh` does not exist yet.

**Step 3: Write minimal docs update**

Add `scheduler` to the built-in plugins section and REPL command table in `README.md`.

**Step 4: Run test to verify current state**

Run: `bash tests/run_tests.sh plugins`
Expected: still FAIL until the plugin file is created.

**Step 5: Commit**

```bash
git add tests/test_plugins.sh README.md
git commit -m "test: add scheduler plugin discovery coverage"
```

### Task 2: Create scheduler plugin skeleton and storage helpers

**Files:**
- Create: `lib/plugins/scheduler/plugin.sh`
- Modify: `tests/test_plugins.sh`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing tests**

Add tests for:

- `plugin_scheduler_info`
- `plugin_scheduler_hooks` returns empty string
- scheduler storage directories are derived under `${SHELLIA_CONFIG_DIR}/plugins/scheduler`
- helper for generating job ids returns a non-empty stable-safe identifier

```bash
test_scheduler_plugin_has_expected_metadata() {
    _reset_plugin_state
    load_builtin_plugins
    assert_eq "$(plugin_scheduler_hooks)" "" "scheduler plugin subscribes to no hooks"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL because scheduler helper functions do not exist yet.

**Step 3: Write minimal implementation**

Create `lib/plugins/scheduler/plugin.sh` with:

- plugin metadata functions
- CLI/REPL help and dispatch entrypoints
- directory helper functions for jobs, logs, wrappers, `launchd`, and `cron`
- job id generator helper
- filesystem bootstrap helper that creates required directories

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS for scheduler plugin metadata tests.

**Step 5: Commit**

```bash
git add lib/plugins/scheduler/plugin.sh tests/test_plugins.sh
git commit -m "feat: add scheduler plugin skeleton"
```

### Task 3: Add backend selection and schedule validation helpers

**Files:**
- Modify: `lib/plugins/scheduler/plugin.sh`
- Modify: `tests/test_plugins.sh`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing tests**

Add tests for helpers that:

- resolve `auto` to `launchd` on macOS and `cron` otherwise
- reject `launchd` when `launchctl` is unavailable
- reject `cron` when `crontab` is unavailable
- validate `--at` input for one-shot schedules
- validate recurring inputs for `--every` and raw cron expressions

```bash
test_scheduler_backend_auto_prefers_launchd_on_darwin() {
    local backend
    backend=$(_scheduler_resolve_backend "auto" "Darwin")
    assert_eq "$backend" "launchd" "auto backend prefers launchd on Darwin"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL because backend resolution and validation helpers are incomplete.

**Step 3: Write minimal implementation**

Implement helpers for:

- backend resolution
- command availability checks
- one-shot datetime normalization
- recurrence normalization for simple presets (`hourly`, `daily`, `weekly`) and raw cron expressions

Keep normalized values simple strings stored in the job JSON.

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS for backend and validation tests.

**Step 5: Commit**

```bash
git add lib/plugins/scheduler/plugin.sh tests/test_plugins.sh
git commit -m "feat: add scheduler backend resolution"
```

### Task 4: Implement job metadata creation and persistence

**Files:**
- Modify: `lib/plugins/scheduler/plugin.sh`
- Modify: `tests/test_plugins.sh`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing tests**

Add tests that create a job and assert:

- job JSON file is written under `jobs/`
- JSON contains prompt, backend, schedule fields, log path, wrapper path, and enabled state
- create helper returns the new job id

```bash
test_scheduler_create_job_writes_metadata_file() {
    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "say hello")
    assert_not_empty "$job_id" "scheduler create job returns id"
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL because metadata writing is not implemented.

**Step 3: Write minimal implementation**

Implement helpers to:

- compose job JSON with `jq -n`
- persist the file atomically
- read a job by id
- update status fields for later reuse

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS for metadata creation tests.

**Step 5: Commit**

```bash
git add lib/plugins/scheduler/plugin.sh tests/test_plugins.sh
git commit -m "feat: persist scheduler job metadata"
```

### Task 5: Generate wrapper scripts with logging and status updates

**Files:**
- Modify: `lib/plugins/scheduler/plugin.sh`
- Modify: `tests/test_plugins.sh`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing tests**

Add tests that render and execute a generated wrapper script with mocked `shellia`, then assert:

- wrapper reads job metadata
- wrapper appends log entries
- wrapper updates `last_run_at`, `last_exit_code`, `last_status`, and `run_count`
- wrapper disables a run-once job after a successful run

```bash
test_scheduler_wrapper_logs_successful_execution() {
    # mock shellia to print output and exit 0
    shellia() { echo "ok"; return 0; }
    # generate and run wrapper, then assert log file contents
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL because wrapper generation and execution logic is incomplete.

**Step 3: Write minimal implementation**

Implement helpers to:

- render a per-job wrapper script
- append structured plain-text log entries
- capture command output to temp files and summarize in the log
- update job metadata after each run
- disable and uninstall run-once jobs after execution

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS for wrapper execution and logging tests.

**Step 5: Commit**

```bash
git add lib/plugins/scheduler/plugin.sh tests/test_plugins.sh
git commit -m "feat: add scheduler execution wrapper"
```

### Task 6: Add launchd backend rendering and install/remove helpers

**Files:**
- Modify: `lib/plugins/scheduler/plugin.sh`
- Modify: `tests/test_plugins.sh`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing tests**

Add tests that mock `launchctl` and verify:

- plist file generation for run-once jobs
- plist file generation for recurring jobs
- label format is `com.shellia.scheduler.<job-id>`
- install helper calls `launchctl load` or equivalent
- remove helper calls `launchctl unload` and deletes the plist

```bash
launchctl() { _LAUNCHCTL_CALLS="${_LAUNCHCTL_CALLS}$*\n"; return 0; }
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL because launchd backend helpers do not exist yet.

**Step 3: Write minimal implementation**

Implement helpers to:

- render `launchd` plist files
- install them with `launchctl`
- unload and remove them on deletion
- record the plist path in job metadata

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS for launchd backend tests.

**Step 5: Commit**

```bash
git add lib/plugins/scheduler/plugin.sh tests/test_plugins.sh
git commit -m "feat: add launchd scheduler backend"
```

### Task 7: Add cron backend rendering and managed crontab updates

**Files:**
- Modify: `lib/plugins/scheduler/plugin.sh`
- Modify: `tests/test_plugins.sh`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing tests**

Add tests that mock `crontab` and verify:

- shellia-managed block is inserted into an existing crontab without removing unrelated lines
- recurring jobs render the expected cron line
- run-once jobs render a self-disabling cron line or managed removal path
- removing a job rewrites only the managed block entries for that job

```bash
crontab() {
    if [[ "$1" == "-l" ]]; then
        printf '%s\n' "$TEST_CRONTAB_CONTENT"
    else
        TEST_CRONTAB_LAST_WRITE=$(cat)
    fi
}
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL because cron backend helpers do not exist yet.

**Step 3: Write minimal implementation**

Implement helpers to:

- read the current crontab safely
- replace only the shellia-managed block
- render one line per job with job id comments
- remove job entries cleanly during uninstall

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS for cron backend tests.

**Step 5: Commit**

```bash
git add lib/plugins/scheduler/plugin.sh tests/test_plugins.sh
git commit -m "feat: add cron scheduler backend"
```

### Task 8: Implement `schedule` CLI and REPL command flows

**Files:**
- Modify: `lib/plugins/scheduler/plugin.sh`
- Modify: `tests/test_plugins.sh`
- Modify: `README.md`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing tests**

Add command-flow tests for:

- `schedule add --at ... --prompt ...`
- `schedule add --every daily --prompt ...`
- `schedule list`
- `schedule logs <id>`
- `schedule run <id>`
- `schedule remove <id>`

Assert command output is clear and references the job id, backend, and log path when relevant.

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL because command handlers do not yet dispatch subcommands fully.

**Step 3: Write minimal implementation**

Implement the shared command parser used by both CLI and REPL handlers.

Support:

- `add` with `--at`, `--every`, `--cron`, `--backend`, and `--prompt`
- `list`
- `logs <id>`
- `run <id>`
- `remove <id>`

Keep help text concise and aligned with existing plugin commands.

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS for scheduler command tests.

**Step 5: Commit**

```bash
git add lib/plugins/scheduler/plugin.sh tests/test_plugins.sh README.md
git commit -m "feat: add scheduler commands"
```

### Task 9: Verify focused tests and full regression coverage

**Files:**
- Modify: `tasks/todo.md`
- Test: `tests/test_plugins.sh`
- Test: `tests/test_entrypoint.sh`
- Test: full suite as needed

**Step 1: Run focused scheduler coverage**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS with new scheduler coverage.

**Step 2: Run entrypoint coverage for command discoverability**

Run: `bash tests/run_tests.sh entrypoint`
Expected: PASS with scheduler command/help output included.

**Step 3: Run broader regression suite**

Run: `bash tests/run_tests.sh`
Expected: PASS with no regressions.

**Step 4: Record results**

Update `tasks/todo.md` with the validation commands and observed pass counts.

**Step 5: Commit**

```bash
git add tasks/todo.md
git commit -m "test: verify scheduler plugin coverage"
```
