# Webfetch Plugin Design

Date: 2026-03-25
Project: shellia
Status: Approved

## Goal

Move `webfetch` out of the built-in tool set and make it a first-class built-in plugin that exposes the tool through the plugin loading interface.

## Requirements

- `webfetch` must no longer live under `lib/tools/`.
- The plugin must expose the standard plugin interface:
  - `plugin_webfetch_info()`
  - `plugin_webfetch_hooks()`
- The plugin must continue exposing the `webfetch` AI tool through:
  - `tool_webfetch_schema()`
  - `tool_webfetch_execute()`
- Existing `webfetch` behavior and schema should remain stable unless a plugin-specific change is required.
- `build_tools_array()` must still include `webfetch` in normal build mode.
- Tests must verify `webfetch` is provided by plugin loading rather than built-in tool loading.

## Proposed Architecture

Implement a new built-in plugin at `lib/plugins/webfetch/plugin.sh`.

This plugin will own all existing `webfetch` logic:

1. Plugin metadata functions (`plugin_webfetch_info`, `plugin_webfetch_hooks`)
2. Tool schema and execution (`tool_webfetch_schema`, `tool_webfetch_execute`)
3. Internal helpers for timeout normalization, content-type detection, HTML conversion, and binary/image handling

The entrypoint and tool registry do not need new infrastructure. The current architecture already supports plugin-defined tools because plugin files are sourced before `build_tools_array()` and `dispatch_tool_call()` are used in normal command flows.

## Why This Approach

This keeps ownership aligned with the project architecture:

- Built-in tools remain reserved for core primitives under `lib/tools/`.
- Integrations and optional capabilities live under `lib/plugins/`.
- The external AI-facing contract stays stable because the tool name remains `webfetch`.
- The refactor is low-risk because it reuses the existing plugin loading model rather than adding a second registration system.

## Migration Plan

### Code movement

- Create `lib/plugins/webfetch/plugin.sh`.
- Move the current contents of `lib/tools/webfetch.sh` into the plugin file.
- Add plugin metadata functions.
- Remove `lib/tools/webfetch.sh`.

### Behavior compatibility

- Keep the tool name as `webfetch`.
- Keep the existing JSON schema unless a test reveals plugin-specific adjustments are needed.
- Keep helper function names unchanged unless namespacing collisions appear.

### Test strategy

Update tests to reflect plugin ownership:

- `tests/test_plugins.sh` should verify the built-in `webfetch` plugin is loaded by `load_builtin_plugins`.
- `tests/test_webfetch.sh` should load built-in plugins and assert the tool functions are available from plugin sourcing.
- Tool-array coverage should continue asserting that `webfetch` appears in `build_tools_array()`.
- Existing behavior tests for URL validation, format handling, and helpers should remain in place to protect the refactor.

## Failure and Edge Cases

- If tests rely on `load_tools` to make `webfetch` available, they must be updated to load plugins first.
- If any other plugin or test defines `tool_webfetch_*`, plugin load order may affect which implementation wins. This is acceptable and consistent with existing plugin override behavior.
- If bundle generation assumes all shipped tools live under `lib/tools`, it may need explicit verification that plugin-sourced tools are still bundled or intentionally excluded.

## Scope Boundaries

In scope:

- Moving `webfetch` into a built-in plugin
- Preserving the `webfetch` tool contract
- Updating tests and docs to match plugin ownership

Out of scope:

- Changing `webfetch` semantics or adding new fetch features
- Introducing a new generic plugin-tool registry abstraction
- Renaming the `webfetch` AI tool

## Testing Strategy

1. Add plugin discovery coverage for `webfetch`.
2. Update `webfetch` tests so they load the plugin and verify the same behavior contract.
3. Run focused tests for plugins, tools, and webfetch.
4. Run the full test suite to catch loading-order regressions.
