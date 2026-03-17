---
name: schedule-task
description: Use when users ask to schedule prompts or automate future shellia runs.
---

# Skill: schedule-task

Use this skill when the user asks to run a prompt later, on a recurring cadence, or as a scheduled automation.

## Workflow

1. Parse the schedule from natural language.
2. Convert to either:
   - `schedule_type: "once"` with `schedule_value: "YYYY-MM-DD HH:MM"`
   - `schedule_type: "recurring"` with `schedule_value` as a 5-field cron expression
3. Call `schedule_task` with `action: "add"` and include the prompt.
4. Report the returned `id`, backend, and effective schedule.

## Preferred Mappings

- hourly -> `0 * * * *`
- daily -> `0 0 * * *`
- weekly -> `0 0 * * 0`
- monthly -> `0 0 1 * *`

## Tool Usage

### Add

```json
{"action":"add","prompt":"check disk space","schedule_type":"recurring","schedule_value":"0 0 * * *","backend":"auto"}
```

### List

```json
{"action":"list"}
```

### Remove

```json
{"action":"remove","job_id":"<id>"}
```

## Notes

- `backend: "auto"` uses `launchd` on macOS and `cron` on Linux.
- Scheduled execution runs `shellia "<prompt>"` directly.
- Logs are written to each job's `log_file` path.
