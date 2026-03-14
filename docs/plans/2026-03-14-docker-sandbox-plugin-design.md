# Docker Sandbox Plugin Design

Date: 2026-03-14
Project: shellia
Status: Approved

## Goal

Run all `run_command` tool executions inside a persistent Docker container sandbox instead of on the host machine.

## Requirements

- Default image is `ubuntu:latest`.
- Image must be configurable via plugin config.
- Host current working directory must be mounted into container.
- Reuse one persistent container per shellia session.
- Preserve existing `run_command` tool contract so the model behavior and call shape stay stable.

## Proposed Architecture

Implement a new built-in plugin in `lib/plugins/docker/plugin.sh`.

The plugin does three things:

1. Uses lifecycle hooks:
   - `init`: start a persistent container.
   - `shutdown`: stop and remove that container.
2. Overrides `tool_run_command_schema()` with an identical schema.
3. Overrides `tool_run_command_execute()` to route commands through `docker exec`.

Because plugin files are sourced after built-in tools load, defining `tool_run_command_*` in the plugin replaces the built-in implementation in the current shell process.

## Why This Approach

This is the most reliable way to enforce sandboxing:

- No dependence on prompt instructions or model compliance.
- No changes required to core tool dispatching.
- Existing tools that invoke `run_command` (for example `run_plan`) are automatically sandboxed.
- Safety plugin behavior is preserved because `before_tool_call` still triggers for `run_command`.

## Container Lifecycle

### Init flow

On `plugin_docker_on_init`:

1. Read plugin config values.
2. Validate Docker availability (`command -v docker`).
3. Start container in detached mode with:
   - Unique name: `shellia_sandbox_<pid>`
   - Working dir: `/workspace`
   - Volume mount: `$(pwd)` -> `/workspace`
   - Image: configured image (default `ubuntu:latest`)
   - Command: `sleep infinity`
4. Persist container name in a plugin-global variable.

### Shutdown flow

On `plugin_docker_on_shutdown`:

1. If container name is set, run `docker rm -f <name>`.
2. Ignore cleanup failures and continue shutdown.

## Tool Behavior

### Schema

`tool_run_command_schema()` returns the same JSON schema as current built-in `run_command`.

### Execution

`tool_run_command_execute(args_json)`:

1. Parse `command` from JSON with `jq`.
2. Respect `SHELLIA_DRY_RUN` exactly like current behavior.
3. Execute command with timeout using:
   - `docker exec <container> sh -c "<command>"`
4. Capture stdout/stderr, preserve exit code.
5. Return output format identical to current tool:
   - `<output>\n[exit code: N]` or `[exit code: N]`
6. If container is unavailable, return a clear error and non-zero status.

## Configuration

Config path:

`~/.config/shellia/plugins/docker/config`

Supported keys:

- `image` (default: `ubuntu:latest`)
- `mount_cwd` (default: `true`)
- `extra_args` (default: empty)

Notes:

- `mount_cwd=false` disables host mount and still runs in `/workspace` inside container.
- `extra_args` is appended to `docker run` for advanced usage.

## Failure and Edge Cases

- Docker missing: plugin logs warning and marks sandbox inactive.
- Image pull/start failure: plugin logs warning and marks sandbox inactive.
- Container dies mid-session: command execution returns error and non-zero code.
- Concurrent shellia sessions: PID-based container naming avoids collisions.

## Testing Strategy

1. Unit/behavioral checks by invoking shellia with plugin enabled:
   - Verify `shellia plugins` shows `docker`.
   - Verify `run_command` creates files in mounted cwd from inside container.
2. Dry-run parity:
   - `shellia --dry-run ...` should not start execution and should return dry-run message.
3. Timeout parity:
   - Long-running command should timeout and return same timeout suffix format.
4. Safety parity:
   - Dangerous command still prompts via safety plugin.
5. Cleanup:
   - On normal exit, container removed.

## Scope Boundaries

In scope:

- Docker-backed execution for `run_command`.
- Persistent per-session container lifecycle.
- Configurable image with default `ubuntu:latest`.

Out of scope:

- Network isolation policy tuning.
- Resource limits and seccomp profile hardening.
- Multi-container/session orchestration beyond one container per shellia process.
