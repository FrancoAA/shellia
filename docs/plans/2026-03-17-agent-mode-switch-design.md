# Agent Mode Switching Design

## Goal

Allow users to switch the agent between `build` mode and `plan` mode at runtime.

- `build` mode: current behavior, all tools available.
- `plan` mode: read-only planning workflow with a restricted toolset.

Startup default should remain `build`.

## Scope

In scope:

- Add runtime mode state and a REPL command to switch mode.
- Enforce tool exposure by mode in the tool registry.
- Surface current mode in REPL UX and system prompt context.
- Add tests for default mode, tool filtering, and mode command behavior.

Out of scope:

- Persisting mode to disk/profile.
- Web-mode-specific mode controls.
- New tool capabilities.

## Mode Model

Introduce `SHELLIA_AGENT_MODE` with valid values:

- `build`
- `plan`

Behavior:

- Default to `build` when unset.
- Validate unknown values and safely fall back to `build`.
- Mode changes apply immediately to subsequent turns in REPL.

## Tool Access Policy

### Build Mode

Expose all tools exactly as today.

### Plan Mode

Expose only:

- `read_file`
- `search_files`
- `search_content`
- `todo_write`
- `ask_user`

All other tools are omitted from the `tools` array sent to the model.

## Implementation Plan

1. Add mode defaults/validation in config/runtime setup.
2. Update tool schema discovery to support filtering by mode.
3. Wire REPL to rebuild available tools after mode changes.
4. Add REPL command `mode [build|plan]` in settings plugin.
5. Display mode in REPL banner/help and include it in system prompt context.
6. Add tests for filtering and mode command behavior.

## UX Details

- Header example: `shellia vX | model: Y | mode: build | ...`
- `mode` (no args) prints current mode.
- `mode plan` and `mode build` switch modes with confirmation output.
- Invalid values show usage: `mode <build|plan>`.

## Testing Strategy

- Unit tests for tool filtering function in both modes.
- REPL/plugin command tests for `mode` status and toggling.
- Regression check that build mode still includes `run_command` and `write_file`.

## Risks and Mitigations

- Risk: stale tool list after mode switch.
  - Mitigation: rebuild tools array at each turn (or after `mode` command).
- Risk: accidental lockout due to bad mode value.
  - Mitigation: strict validation + fallback to `build`.
- Risk: drift between prompt mode and tool mode.
  - Mitigation: derive both from the same runtime variable.

## Success Criteria

- Users can switch mode during REPL with `mode plan` / `mode build`.
- In `plan` mode, model only receives read-only planning tools.
- In `build` mode, full toolset remains available.
- Tests cover and validate the behavior.
