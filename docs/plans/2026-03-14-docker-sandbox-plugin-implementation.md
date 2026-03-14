# Docker Sandbox Plugin Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a built-in `docker` plugin that makes every `run_command` execution run inside a persistent Docker sandbox container with mounted working directory and configurable image.

**Architecture:** Implement a new plugin at `lib/plugins/docker/plugin.sh` that subscribes to `init` and `shutdown`, starts/stops a per-session container, and overrides `tool_run_command_schema` + `tool_run_command_execute` so all command execution routes through `docker exec`. Keep output/timeout/dry-run behavior compatible with current `run_command` semantics and verify with focused tests.

**Tech Stack:** Bash 3.2+, shellia plugin hooks, Docker CLI, existing shellia test runner (`tests/run_tests.sh`).

---

### Task 1: Add plugin discovery coverage for docker plugin

**Files:**
- Modify: `README.md`
- Modify: `tests/test_plugins.sh`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing test**

Add a test in `tests/test_plugins.sh` that calls `load_builtin_plugins` and asserts `docker` appears in `SHELLIA_LOADED_PLUGINS`.

```bash
test_load_builtin_plugins_includes_docker() {
    _reset_plugin_state
    load_builtin_plugins
    _plugin_is_loaded "docker"
    assert_eq "$?" "0" "builtin docker plugin is loaded"
}
```

**Step 2: Run test to verify it fails**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL because `lib/plugins/docker/plugin.sh` does not exist yet.

**Step 3: Write minimal implementation docs update**

Update `README.md` built-in plugins table to include `docker` with its hooks (`init`, `shutdown`).

**Step 4: Run test to verify current state**

Run: `bash tests/run_tests.sh plugins`
Expected: still FAIL until plugin file is created (expected at this stage).

**Step 5: Commit**

```bash
git add tests/test_plugins.sh README.md
git commit -m "test: add builtin docker plugin discovery coverage"
```

### Task 2: Implement docker plugin lifecycle hooks

**Files:**
- Create: `lib/plugins/docker/plugin.sh`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing tests**

In `tests/test_plugins.sh`, add tests that source/register the docker plugin and verify:

- `plugin_docker_hooks` returns `init shutdown`
- `plugin_docker_on_init` sets up a container name state variable
- `plugin_docker_on_shutdown` calls cleanup only when a container is active

Mock Docker by overriding `docker()` inside tests so no real Docker daemon is required.

```bash
docker() { _DOCKER_CALLS="${_DOCKER_CALLS}$*\n"; return 0; }
```

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL because docker plugin functions do not exist yet.

**Step 3: Write minimal implementation**

Create `lib/plugins/docker/plugin.sh` with:

- `plugin_docker_info`
- `plugin_docker_hooks`
- `plugin_docker_on_init`
- `plugin_docker_on_shutdown`
- internal helpers for reading config/defaults and container naming

Use defaults:

- image: `ubuntu:latest`
- mount_cwd: `true`
- extra_args: empty

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS for new docker lifecycle tests.

**Step 5: Commit**

```bash
git add lib/plugins/docker/plugin.sh tests/test_plugins.sh
git commit -m "feat: add docker plugin lifecycle management"
```

### Task 3: Override run_command schema + execution in docker plugin

**Files:**
- Modify: `lib/plugins/docker/plugin.sh`
- Modify: `tests/test_tools.sh`
- Test: `tests/test_tools.sh`

**Step 1: Write the failing tests**

In `tests/test_tools.sh`, add docker-specific tests that:

1. Ensure `tool_run_command_schema` still names tool `run_command` and requires `command`.
2. Ensure execution uses `docker exec ... sh -c <cmd>` when sandbox is active.
3. Ensure output includes command output and `[exit code: N]`.
4. Ensure dry-run returns dry-run message without docker execution.

Stub dependencies (`docker`, `detect_shell`, timeout behavior) to keep tests deterministic.

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh tools`
Expected: FAIL because docker-backed run_command override does not exist yet.

**Step 3: Write minimal implementation**

Extend `lib/plugins/docker/plugin.sh` with:

- `tool_run_command_schema()` (schema parity)
- `tool_run_command_execute(args_json)` that:
  - parses command via `jq`
  - checks `SHELLIA_DRY_RUN`
  - runs `docker exec "$SHELLIA_DOCKER_CONTAINER" sh -c "$cmd"`
  - enforces timeout using same pattern as existing tool
  - returns matching output format

Fallback behavior:

- if sandbox inactive, return clear error and non-zero code
- keep stderr user feedback style similar to current tool

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh tools`
Expected: PASS for new docker run_command tests and no regressions in existing tools tests.

**Step 5: Commit**

```bash
git add lib/plugins/docker/plugin.sh tests/test_tools.sh
git commit -m "feat: run commands in docker sandbox via plugin override"
```

### Task 4: Ensure plugin is loaded in normal shellia flows

**Files:**
- Modify: `tests/test_entrypoint.sh`
- Test: `tests/test_entrypoint.sh`

**Step 1: Write the failing test**

Add an entrypoint-level test that verifies plugin loading makes docker override available before single-prompt dispatch.

Approach: stub `api_chat_loop` to request `run_command`, then assert mocked docker path is used.

**Step 2: Run test to verify it fails**

Run: `bash tests/run_tests.sh entrypoint`
Expected: FAIL until docker plugin is fully wired in test setup.

**Step 3: Write minimal implementation (if needed)**

If test fails because test harness does not source built-in plugins in same way as entrypoint, minimally adjust harness setup in `tests/test_entrypoint.sh` to call `load_plugins` and fire `init` where required.

**Step 4: Run test to verify it passes**

Run: `bash tests/run_tests.sh entrypoint`
Expected: PASS for new integration case.

**Step 5: Commit**

```bash
git add tests/test_entrypoint.sh
git commit -m "test: verify docker sandbox plugin in entrypoint flow"
```

### Task 5: Add config documentation and examples

**Files:**
- Modify: `README.md`
- Create: `defaults/plugins/docker/config.example`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing test**

Add a plugins test that verifies config fallback behavior for docker plugin defaults (`ubuntu:latest`, `true`, empty extra args).

**Step 2: Run test to verify it fails**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL before config helper behavior is finalized.

**Step 3: Write minimal implementation**

Add `defaults/plugins/docker/config.example`:

```ini
image=ubuntu:latest
mount_cwd=true
extra_args=
```

Update `README.md` plugin section with config path and keys.

**Step 4: Run test to verify it passes**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS for config defaults test.

**Step 5: Commit**

```bash
git add README.md defaults/plugins/docker/config.example tests/test_plugins.sh
git commit -m "docs: document docker sandbox plugin configuration"
```

### Task 6: Full regression + manual verification

**Files:**
- Modify: `docs/plans/2026-03-14-docker-sandbox-plugin-implementation.md`

**Step 1: Run full automated tests**

Run: `bash tests/run_tests.sh`
Expected: All tests PASS.

**Step 2: Run manual smoke checks**

Run:

```bash
shellia plugins
shellia --dry-run "echo hello"
shellia "create a file named sandbox_check.txt with hello"
```

Expected:

- `docker` appears in plugin list
- dry-run does not execute command
- command execution occurs in container and writes to mounted cwd on host

**Step 3: Capture verification notes**

Append a short "Verification Results" section in this plan file with:

- test command outputs summary
- manual smoke outcome
- any follow-up work

**Step 4: Final commit**

```bash
git add lib/plugins/docker/plugin.sh tests/test_plugins.sh tests/test_tools.sh tests/test_entrypoint.sh README.md defaults/plugins/docker/config.example docs/plans/2026-03-14-docker-sandbox-plugin-implementation.md
git commit -m "feat: add docker sandbox plugin for run_command execution"
```
