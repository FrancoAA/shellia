# Scheduler Plugin Design

Date: 2026-03-16
Project: shellia
Status: Approved

## Goal

Add a built-in `scheduler` plugin that lets users schedule prompts to run once at a specific future time or recur on a defined schedule, with persistence across shellia restarts and reboots.

## Requirements

- Scheduled jobs must persist across shellia restarts.
- Jobs must execute as fresh non-interactive one-shot shellia processes.
- The plugin must support both `launchd` and `cron` backends.
- Backend selection must be explicit or automatic.
- Each job must maintain execution logs and last-run status.
- Users must be able to add, list, inspect, run, and remove scheduled jobs.

## Proposed Architecture

Implement a new built-in plugin in `lib/plugins/scheduler/plugin.sh`.

The plugin owns a backend-neutral job model and renders that model into a concrete scheduler backend:

1. Stores job metadata under `~/.config/shellia/plugins/scheduler/jobs/`.
2. Creates a per-job wrapper script under `~/.config/shellia/plugins/scheduler/bin/`.
3. Installs the job into either:
   - `launchd` via a generated plist on macOS, or
   - `cron` via managed `crontab` entries.
4. Writes execution logs under `~/.config/shellia/plugins/scheduler/logs/`.
5. Updates job metadata after each run with status fields like `last_run_at`, `last_exit_code`, and `run_count`.

The scheduler plugin exposes CLI and REPL commands, while backend-specific logic stays behind adapter helpers so user-facing behavior remains consistent.

## Why This Approach

This design keeps the feature aligned with shellia's plugin model while avoiding a long-running daemon:

- Persistence comes from the operating system scheduler instead of an always-on shellia process.
- Backend-neutral metadata avoids duplicating user-facing logic across `launchd` and `cron`.
- The wrapper script provides one stable place for logging, metadata updates, and future extensions.
- Each execution runs a fresh `shellia` process, which avoids coupling scheduled jobs to REPL session state.

## User Experience

### CLI commands

- `shellia schedule add --at "2026-03-20 09:00" --prompt "..."`
- `shellia schedule add --every "daily" --prompt "..."`
- `shellia schedule list`
- `shellia schedule run <id>`
- `shellia schedule logs <id>`
- `shellia schedule remove <id>`

### REPL commands

- `schedule add ...`
- `schedule list`
- `schedule run <id>`
- `schedule logs <id>`
- `schedule remove <id>`

The initial implementation should keep arguments close to the CLI shape so parsing and help text stay simple.

## Job Model

Each job is stored as a JSON file at:

`~/.config/shellia/plugins/scheduler/jobs/<job-id>.json`

Recommended fields:

- `id`
- `prompt`
- `schedule_type` (`once` or `recurring`)
- `schedule_value` (normalized input such as datetime or cron expression)
- `backend` (`launchd`, `cron`, or resolved value from `auto`)
- `created_at`
- `enabled`
- `log_file`
- `wrapper_file`
- `backend_artifact`
- `last_run_at`
- `last_exit_code`
- `last_status`
- `run_count`

The JSON file is the source of truth. Backend-specific artifacts are generated from it and can be recreated if needed.

## Backend Model

### Backend selection

Support three modes:

- `auto` - prefer `launchd` on macOS, otherwise `cron`
- `launchd` - require `launchctl`
- `cron` - require `crontab`

### launchd backend

- Generate one plist per job under `~/.config/shellia/plugins/scheduler/launchd/`.
- Use `StartCalendarInterval` for one-time and calendar-style recurring schedules where possible.
- Use `StartInterval` only if the recurrence model needs simple fixed intervals later.
- Load and unload jobs via `launchctl`.
- Use a stable label prefix such as `com.shellia.scheduler.<job-id>`.

### cron backend

- Maintain a managed scheduler block inside the user's crontab.
- Render each recurring job as a cron line plus comment markers that include the job id.
- For run-once jobs, schedule a cron line that invokes the wrapper and self-disables by removing itself after a successful trigger.
- Keep generated cron material isolated so unrelated user crontab lines are preserved.

## Execution Flow

When a backend triggers a job:

1. The generated wrapper script loads the job metadata.
2. If the job is missing or disabled, it logs a skipped run and exits cleanly.
3. It records a start entry in the job log.
4. It executes `shellia "<prompt>"` as a fresh non-interactive process.
5. It captures stdout, stderr, and exit code.
6. It appends a completion entry to the log.
7. It updates the job metadata fields for last result.
8. If the job is run-once, it unregisters the backend artifact and marks the job completed or disabled.

## Logging and Observability

Each job gets a dedicated log file:

`~/.config/shellia/plugins/scheduler/logs/<job-id>.log`

Each execution appends structured plain-text records containing:

- start timestamp
- finish timestamp
- backend
- shellia command invoked
- exit code
- success or failure status
- captured output summary or output file pointers

The plugin also stores lightweight status fields in the job metadata so `schedule list` can show recent health without parsing the full log.

## Failure and Edge Cases

- Missing backend binary: fail job creation with a clear error.
- Invalid schedule syntax: reject at creation time before writing backend artifacts.
- Corrupt job metadata: log the failure and avoid repeated destructive cleanup.
- Wrapper invoked after job removal: exit cleanly after writing a skip entry if log path still exists.
- Partial backend installation failure: roll back generated artifacts and surface a clear error.
- Existing user crontab entries: preserve all non-shellia lines and only rewrite the shellia-managed block.

## Scope Boundaries

In scope:

- Run-once and recurring scheduled prompts.
- Persistent jobs across shellia restarts and reboots.
- `launchd` and `cron` backends.
- Per-job logs and last-run status.
- CLI and REPL job management commands.

Out of scope:

- Resuming existing conversation sessions.
- A long-running shellia scheduler daemon.
- UI for editing jobs in place.
- Rich timezone conversion beyond host-local scheduling.
- Distributed or multi-host scheduling.

## Testing Strategy

1. Add plugin discovery and command discovery tests in `tests/test_plugins.sh`.
2. Add scheduler plugin unit-style tests for:
   - backend selection
   - metadata creation
   - wrapper rendering
   - `launchd` plist generation
   - cron block rendering
   - removal and cleanup behavior
3. Mock `launchctl`, `crontab`, and `shellia` so tests stay deterministic.
4. Verify log file updates and metadata status updates through wrapper execution tests.
5. Update `README.md` with scheduler usage, backend selection, and log behavior.
