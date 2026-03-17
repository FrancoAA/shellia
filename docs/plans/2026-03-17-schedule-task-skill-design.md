# Schedule Task Skill — Design

Date: 2026-03-17
Project: shellia
Status: Approved

## Goal

Replace the scheduler plugin with a lightweight skill + tool + OS scripts approach. The LLM learns how to schedule prompts via the skill, calls a `schedule_task` tool for operations, and OS scripts handle launchd/cron directly. Shellia prompts execute without a wrapper.

## What Gets Removed

- `lib/plugins/scheduler/plugin.sh` — entire file
- All scheduler tests in `tests/test_plugins.sh`
- Scheduler sections in `README.md` (REPL command table row, Scheduler section, built-in plugins row)
- `shellia schedule` CLI subcommand and REPL command

## What Gets Added

### 1. Skill: `schedule-task`

Location: `~/.config/shellia/skills/schedule-task/SKILL.md` (installed by user) OR bundled as the first built-in skill at `lib/skills/schedule-task/SKILL.md`.

The SKILL.md teaches the LLM:
- How to translate natural language schedules into cron expressions or datetime strings
- When to use `schedule_task` tool with `add`, `list`, or `remove` actions
- OS-specific behavior (launchd on macOS, cron on Linux)
- How to interpret results and present them to the user

### 2. Tool: `schedule_task`

Location: `lib/tools/schedule_task.sh`

Defines `tool_schedule_task_schema()` and `tool_schedule_task_execute()`.

Actions:
- `add` — creates a scheduled job (params: prompt, schedule_type, schedule_value, backend)
- `list` — lists all scheduled jobs from metadata
- `remove` — removes a job by id (uninstalls OS artifact, removes metadata entry)

The tool delegates to OS scripts for backend operations and manages the metadata file.

### 3. OS Scripts

Location: `scripts/scheduler/`

Files:
- `common.sh` — shared metadata helpers (read/write jobs.json, generate ids, validate schedules)
- `darwin.sh` — launchd plist generation, launchctl load/unload
- `linux.sh` — cron managed-block install/remove

Each script is sourced by the tool at runtime. The tool detects OS and sources the appropriate backend script.

### 4. Metadata

Single file: `~/.config/shellia/scheduler/jobs.json`

Array of job objects. Fields per job:
- `id`, `prompt`, `backend`, `schedule_type` (once|recurring), `schedule_value` (datetime or cron expression), `created_at`, `enabled`, `log_file`, `artifact_ref`

Log files: `~/.config/shellia/scheduler/logs/<id>.log`

### 5. Execution

- launchd: ProgramArguments invokes `shellia "<prompt>"`, StandardOutPath/StandardErrorPath point to log file
- cron: line invokes `shellia "<prompt>" >> <log_file> 2>&1`
- No wrapper script. No runtime metadata updates. Logs are the source of execution truth.

## Data Flow

```
User: "schedule a daily disk check"
  → LLM loads schedule-task skill (if not already loaded)
  → LLM calls schedule_task tool: {action: "add", prompt: "check disk space", schedule_type: "recurring", schedule_value: "0 0 * * *"}
  → tool sources common.sh + darwin.sh (or linux.sh)
  → common.sh writes job to jobs.json
  → darwin.sh generates plist and calls launchctl load
  → tool returns confirmation to LLM
  → LLM tells user the job is scheduled
```

## Scope Boundaries

In scope:
- add, list, remove operations
- launchd and cron backends
- single metadata file
- per-job log files (stdout/stderr capture by OS scheduler)
- skill that teaches LLM scheduling semantics
- OS scripts for backend operations

Out of scope:
- Wrapper scripts
- Runtime status tracking in metadata (last_run_at, etc.)
- `run` command (user can just run `shellia "<prompt>"` directly)
- `logs` command (user can `cat` the log file; LLM can use read_file tool)
- Session resumption
- Timezone conversion beyond host-local

## Testing Strategy

- Unit tests for common.sh: metadata CRUD, id generation, validation
- Unit tests for darwin.sh: plist rendering, launchctl mock
- Unit tests for linux.sh: cron block rendering, crontab mock
- Integration tests for schedule_task tool: add/list/remove flows
- Verify scheduler plugin removal causes no regressions
- Full suite passes after removal + addition
