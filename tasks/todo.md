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
