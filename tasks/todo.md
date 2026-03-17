# Shellia review follow-up: security and distribution parity fixes

- [x] Review confirmed web/skills/bundle findings and define concrete fix plan.
- [x] Implement web session_id validation and safe ID generation in `shellia`.
- [x] Implement matching session_id sanitization in `lib/plugins/serve/server.py`.
- [x] Add per-session serialization in web handler to avoid concurrent session file races.
- [x] Inject loaded skill content into next prompt context for REPL skill load flow.
- [x] Include `delegate_task` in bundle tool embedding list.
- [x] Add regression tests for: session traversal rejection, skill context injection, and bundle parity.
- [x] Run focused test suite and report results in final handoff.
- [x] Add REPL end-to-end one-shot skill context test.

Accomplished in this pass:
- Added session_id allowlist validation and random fallback in shellia and server.
- Added per-session lock map in serve handler to serialize chat execution by session.
- Updated skills prompt hook to inject loaded skill content.
- Cleared loaded-skill context in request code paths after prompt construction so skill content is one-shot per request.
- Added `delegate_task` to bundle tool list.
- Added tests for bundle tool parity, skill prompt injection, and traversal-resistant reset.

## 2026-03-09 tool-state fix plan (REPL + web)

- [x] Add failing/coverage tests for tool lifecycle UX in API loop and web-mode safety for `ask_user`.
- [x] Implement API tool lifecycle handling that pauses CLI spinner during tool execution.
- [x] Emit explicit web tool lifecycle events (`tool_start` / `tool_end`) in addition to `tool_call`.
- [x] Update web UI status handling to show a distinct running-tool state instead of thinking.
- [x] Prevent `ask_user` from blocking in web mode and return a clear error.
- [x] Add network timeouts to `web_search` tool requests to avoid indefinite hanging.
- [x] Run focused tests (`test_api`, `test_tools`, `test_serve`) and document results.

Validation results:
- `bash tests/run_tests.sh test_api` -> 29 passed, 0 failed.
- `bash tests/run_tests.sh test_tools` -> 45 passed, 0 failed.
- `bash tests/run_tests.sh test_serve` -> 33 passed, 0 failed.

## 2026-03-10 markdown todo persistence plan

- [x] Add failing tool tests for a new `todo_write` tool schema and markdown persistence behavior.
- [x] Implement `lib/tools/todo_write.sh` with strict status/priority validation and markdown file output.
- [x] Run focused tests (`bash tests/run_tests.sh test_tools`) and capture results.

Validation results:
- `bash tests/run_tests.sh test_tools` -> 63 passed, 0 failed.
- `bash tests/run_tests.sh` -> 408 passed, 0 failed.

## 2026-03-10 todos REPL command

- [x] Add failing tests for a `todos` REPL command that prints persisted markdown todos.
- [x] Implement `repl_cmd_todos_handler` and `repl_cmd_todos_help` in `lib/tools/todo_write.sh`.
- [x] Update README REPL command table with `todos` command.
- [x] Run focused tests and capture results.

Validation results:
- `bash tests/run_tests.sh test_tools` -> 67 passed, 0 failed.

## 2026-03-16 scheduler plugin design + planning

- [x] Explore existing plugin architecture, docs, and test patterns.
- [x] Confirm persistence model and execution mode for scheduled prompts.
- [x] Approve backend strategy with `launchd` + `cron` support and per-job logs.
- [x] Write scheduler plugin design doc in `docs/plans/`.
- [x] Write scheduler plugin implementation plan in `docs/plans/`.
- [x] Choose execution mode for implementation.

## 2026-03-17 schedule-task skill migration

- [x] Remove scheduler plugin implementation and scheduler plugin test coverage.
- [x] Add shared scheduler helpers in `scripts/scheduler/common.sh`.
- [x] Add launchd backend script in `scripts/scheduler/darwin.sh`.
- [x] Add cron backend script in `scripts/scheduler/linux.sh`.
- [x] Add `schedule_task` tool in `lib/tools/schedule_task.sh`.
- [x] Add built-in `schedule-task` skill and built-in skill discovery path.
- [x] Update docs for skill-based scheduling and remove `shellia schedule` docs.
- [x] Run focused suites and full regression suite.

Validation results:
- `bash tests/run_tests.sh plugins` -> 65 passed, 0 failed.
- `bash tests/run_tests.sh tools` -> 201 passed, 0 failed.
- `bash tests/run_tests.sh skills` -> 85 passed, 0 failed.
- `bash tests/run_tests.sh scheduler` -> 38 passed, 0 failed.
- `bash tests/run_tests.sh` -> 604 passed, 0 failed.
