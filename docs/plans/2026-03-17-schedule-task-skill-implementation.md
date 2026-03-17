# Schedule Task Skill Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the scheduler plugin with a skill + tool + OS scripts approach that lets the LLM schedule shellia prompts directly via launchd/cron with no wrapper scripts.

**Architecture:** A `schedule_task` tool in `lib/tools/schedule_task.sh` handles add/list/remove. It sources shared helpers from `scripts/scheduler/common.sh` and OS-specific backends from `scripts/scheduler/darwin.sh` or `scripts/scheduler/linux.sh`. A SKILL.md at `lib/skills/schedule-task/SKILL.md` teaches the LLM how to use the tool. The skills plugin is extended to also scan `${SHELLIA_DIR}/lib/skills/` as a third discovery path for built-in skills.

**Tech Stack:** Bash 3.2+, jq, launchctl (macOS), crontab (Linux), shellia test runner.

---

### Task 1: Remove scheduler plugin and all references

**Files:**
- Delete: `lib/plugins/scheduler/plugin.sh`
- Modify: `tests/test_plugins.sh`
- Modify: `README.md`
- Test: `tests/test_plugins.sh`

**Step 1: Delete the plugin file**

```bash
rm lib/plugins/scheduler/plugin.sh
rmdir lib/plugins/scheduler
```

**Step 2: Remove scheduler tests from test_plugins.sh**

Remove all test functions that start with `test_scheduler_` or `test_load_builtin_plugins_includes_scheduler`. Also remove scheduler helper functions like `_scheduler_setup_launchd_test`, `_scheduler_setup_cmd_test`, `_scheduler_teardown_cmd_test`, and similar.

**Step 3: Remove scheduler from README.md**

- Remove the `| schedule | scheduler | ...` row from the REPL commands table (line ~125)
- Remove the entire `## Scheduler` section (lines ~159-221)
- Remove the `| scheduler | ...` row from the built-in plugins table (line ~332)

**Step 4: Run tests to verify no regressions**

Run: `bash tests/run_tests.sh`
Expected: PASS with reduced test count, 0 failures.

**Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove scheduler plugin"
```

### Task 2: Create shared scheduler helpers (common.sh)

**Files:**
- Create: `scripts/scheduler/common.sh`
- Create: `tests/test_scheduler.sh`
- Test: `tests/test_scheduler.sh`

**Step 1: Write the failing tests**

Create `tests/test_scheduler.sh` with tests for:

- `_sched_generate_id` returns non-empty filesystem-safe id
- `_sched_ensure_dirs` creates `~/.config/shellia/scheduler/` and `logs/` subdirectory
- `_sched_validate_at` accepts "YYYY-MM-DD HH:MM", rejects invalid
- `_sched_validate_cron` accepts 5-field cron, rejects invalid
- `_sched_normalize_every` converts presets (hourly/daily/weekly/monthly) to cron expressions
- `_sched_add_job` writes a job entry to jobs.json and returns the id
- `_sched_list_jobs` returns all jobs from jobs.json
- `_sched_remove_job` removes a job entry from jobs.json by id
- `_sched_get_job` returns a single job by id
- `_sched_detect_backend` returns "launchd" on Darwin, "cron" on Linux

Source `scripts/scheduler/common.sh` in each test. Use `TEST_TMP` for `SHELLIA_CONFIG_DIR`.

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh scheduler`
Expected: FAIL because common.sh does not exist yet.

**Step 3: Write minimal implementation**

Create `scripts/scheduler/common.sh` with:

- `_sched_base_dir()` — echoes `${SHELLIA_CONFIG_DIR}/scheduler`
- `_sched_jobs_file()` — echoes `$(_sched_base_dir)/jobs.json`
- `_sched_logs_dir()` — echoes `$(_sched_base_dir)/logs`
- `_sched_ensure_dirs()` — mkdir -p base dir and logs dir, create jobs.json as `[]` if missing
- `_sched_generate_id label` — lowercase, strip non-alnum, append pid suffix
- `_sched_validate_at datetime` — regex match YYYY-MM-DD HH:MM
- `_sched_validate_cron expression` — 5 fields, each field contains only [0-9*/,-]
- `_sched_normalize_every preset` — case switch: hourly/daily/weekly/monthly to cron
- `_sched_detect_backend [os_name]` — launchd on Darwin if launchctl available, else cron
- `_sched_add_job schedule_type schedule_value backend prompt` — generate id, build JSON object, append to jobs.json array with jq, return id
- `_sched_get_job job_id` — jq select from jobs.json by id
- `_sched_list_jobs` — cat jobs.json (or echo `[]` if missing)
- `_sched_remove_job job_id` — jq delete from jobs.json by id

Metadata fields per job: `id`, `prompt`, `backend`, `schedule_type`, `schedule_value`, `created_at`, `enabled`, `log_file`, `artifact_ref`

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh scheduler`
Expected: PASS.

**Step 5: Commit**

```bash
git add scripts/scheduler/common.sh tests/test_scheduler.sh
git commit -m "feat: add shared scheduler helpers"
```

### Task 3: Create darwin.sh (launchd backend)

**Files:**
- Create: `scripts/scheduler/darwin.sh`
- Modify: `tests/test_scheduler.sh`
- Test: `tests/test_scheduler.sh`

**Step 1: Write the failing tests**

Add tests that mock `launchctl` and verify:

- `_sched_darwin_install job_id` generates plist at correct path and calls `launchctl load`
- plist Label is `com.shellia.scheduler.<job_id>`
- plist ProgramArguments invokes shellia with the prompt
- plist StandardOutPath/StandardErrorPath point to log file
- plist StartCalendarInterval maps correctly from cron/datetime
- `_sched_darwin_remove job_id` calls `launchctl unload` and removes plist

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh scheduler`

**Step 3: Write minimal implementation**

Create `scripts/scheduler/darwin.sh` with:

- `_sched_darwin_plist_dir()` — `$(_sched_base_dir)/launchd`
- `_sched_darwin_install job_id` — reads job from jobs.json, generates plist with heredoc, loads via launchctl. ProgramArguments: `["shellia", "<prompt>"]`. Update artifact_ref in jobs.json.
- `_sched_darwin_remove job_id` — unloads plist, removes file

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh scheduler`

**Step 5: Commit**

```bash
git add scripts/scheduler/darwin.sh tests/test_scheduler.sh
git commit -m "feat: add launchd scheduler backend"
```

### Task 4: Create linux.sh (cron backend)

**Files:**
- Create: `scripts/scheduler/linux.sh`
- Modify: `tests/test_scheduler.sh`
- Test: `tests/test_scheduler.sh`

**Step 1: Write the failing tests**

Add tests that mock `crontab` and verify:

- `_sched_cron_install job_id` adds a managed-block cron line
- cron line invokes `shellia "<prompt>" >> <log_file> 2>&1`
- managed block uses `# BEGIN shellia-scheduler` / `# END shellia-scheduler` markers
- existing user crontab lines are preserved
- `_sched_cron_remove job_id` removes the job's cron line from managed block
- removing last job removes the markers

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh scheduler`

**Step 3: Write minimal implementation**

Create `scripts/scheduler/linux.sh` with:

- `_sched_cron_install job_id` — reads job, renders cron line with comment marker, inserts into managed block
- `_sched_cron_remove job_id` — removes line from managed block, clean up empty block

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh scheduler`

**Step 5: Commit**

```bash
git add scripts/scheduler/linux.sh tests/test_scheduler.sh
git commit -m "feat: add cron scheduler backend"
```

### Task 5: Create schedule_task tool

**Files:**
- Create: `lib/tools/schedule_task.sh`
- Modify: `tests/test_tools.sh`
- Test: `tests/test_tools.sh`

**Step 1: Write the failing tests**

Add tests to `tests/test_tools.sh` for:

- `tool_schedule_task_schema` returns valid JSON with correct name and parameters
- `tool_schedule_task_execute` with action=add creates a job and installs backend
- `tool_schedule_task_execute` with action=list returns jobs JSON
- `tool_schedule_task_execute` with action=remove removes job and uninstalls backend
- `tool_schedule_task_execute` with missing action returns error
- `tool_schedule_task_execute` with add missing prompt returns error
- `build_tools_array` output contains `schedule_task`

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh tools`

**Step 3: Write minimal implementation**

Create `lib/tools/schedule_task.sh`:

- `tool_schedule_task_schema()` — JSON schema with parameters: action (enum: add/list/remove), prompt, schedule_type (once/recurring), schedule_value, backend (auto/launchd/cron), job_id
- `tool_schedule_task_execute()` — parses action, sources common.sh + OS backend script, dispatches:
  - add: validate inputs, ensure dirs, add job to metadata, install backend, return confirmation
  - list: list jobs, format for LLM
  - remove: remove backend artifact, remove from metadata, return confirmation

The tool sources scripts at runtime:
```bash
source "${SHELLIA_DIR}/scripts/scheduler/common.sh"
case "$(uname -s)" in
    Darwin) source "${SHELLIA_DIR}/scripts/scheduler/darwin.sh" ;;
    *)      source "${SHELLIA_DIR}/scripts/scheduler/linux.sh" ;;
esac
```

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh tools`

**Step 5: Commit**

```bash
git add lib/tools/schedule_task.sh tests/test_tools.sh
git commit -m "feat: add schedule_task tool"
```

### Task 6: Create schedule-task skill and extend skill discovery

**Files:**
- Create: `lib/skills/schedule-task/SKILL.md`
- Modify: `lib/plugins/skills/plugin.sh`
- Modify: `tests/test_skills.sh`
- Modify: `README.md`
- Test: `tests/test_skills.sh`

**Step 1: Write the failing tests**

Add tests to `tests/test_skills.sh` for:

- Built-in skills directory `${SHELLIA_DIR}/lib/skills/` is scanned during discovery
- `schedule-task` skill is discovered from built-in skills
- `schedule-task` skill has a description
- Skill discovery priority: hub < built-in < shellia-exclusive

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh skills`

**Step 3: Extend skill discovery**

Modify `_skills_discover()` in `lib/plugins/skills/plugin.sh` to add a third scan path between hub and shellia-exclusive:

```bash
_skills_discover() {
    _SHELLIA_SKILL_NAMES=()
    _SHELLIA_SKILL_ENTRIES=()

    # 1. Shared hub (lowest priority)
    _skills_scan_dir "${HOME}/.agents/skills"

    # 2. Built-in shellia skills (medium priority)
    _skills_scan_dir "${SHELLIA_DIR}/lib/skills"

    # 3. Shellia-exclusive (highest priority — overrides all)
    _skills_scan_dir "${SHELLIA_CONFIG_DIR}/skills"
}
```

**Step 4: Create the skill SKILL.md**

Create `lib/skills/schedule-task/SKILL.md` with frontmatter and body that teaches the LLM:

- How to translate natural language schedules to cron expressions
- Preset mappings (daily = "0 0 * * *", hourly = "0 * * * *", etc.)
- When to use schedule_type "once" vs "recurring"
- Backend selection logic (auto detects OS)
- How to call schedule_task tool with add/list/remove
- How to present results to the user
- Error handling guidance

**Step 5: Update README.md**

Add a "Scheduling" section that explains the skill-based approach, replacing the old plugin-based scheduler documentation.

**Step 6: Run tests to verify they pass**

Run: `bash tests/run_tests.sh skills`

**Step 7: Commit**

```bash
git add lib/skills/schedule-task/SKILL.md lib/plugins/skills/plugin.sh tests/test_skills.sh README.md
git commit -m "feat: add schedule-task skill with built-in skill discovery"
```

### Task 7: Full regression verification

**Files:**
- Modify: `tasks/todo.md`

**Step 1: Run full test suite**

Run: `bash tests/run_tests.sh`
Expected: PASS with 0 failures.

**Step 2: Record results in tasks/todo.md**

**Step 3: Commit**

```bash
git add tasks/todo.md
git commit -m "test: verify schedule-task skill full regression"
```
