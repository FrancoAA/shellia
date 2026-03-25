# Webfetch Plugin Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move `webfetch` from `lib/tools/` into a built-in plugin while preserving the existing `webfetch` tool contract and behavior.

**Architecture:** Add a new `lib/plugins/webfetch/plugin.sh` file that owns the `webfetch` tool schema, execution, and helpers. Remove `lib/tools/webfetch.sh`, update tests to load `webfetch` through the plugin system, and keep `build_tools_array()` behavior unchanged because plugin-defined tools are already supported by the existing sourcing model.

**Tech Stack:** Bash 3.2+, shellia plugin system, jq, curl, existing shellia test runner (`tests/run_tests.sh`).

---

### Task 1: Add plugin discovery coverage for webfetch

**Files:**
- Modify: `tests/test_plugins.sh`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing test**

Add a plugin test that calls `load_builtin_plugins`, then asserts `_plugin_is_loaded "webfetch"` succeeds.

```bash
test_load_builtin_plugins_includes_webfetch() {
    _reset_plugin_state
    load_builtin_plugins
    _plugin_is_loaded "webfetch"
    assert_eq "$?" "0" "load_builtin_plugins loads webfetch plugin"
}
```

**Step 2: Run test to verify it fails**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL because `lib/plugins/webfetch/plugin.sh` does not exist yet.

**Step 3: Write minimal test-only implementation**

Save the new plugin discovery test without changing production code yet.

**Step 4: Run test to verify the expected failure remains**

Run: `bash tests/run_tests.sh plugins`
Expected: FAIL for missing `webfetch` plugin.

### Task 2: Move webfetch into a built-in plugin

**Files:**
- Create: `lib/plugins/webfetch/plugin.sh`
- Delete: `lib/tools/webfetch.sh`
- Test: `tests/test_plugins.sh`
- Test: `tests/test_webfetch.sh`

**Step 1: Write the failing tests**

Update `tests/test_webfetch.sh` so `webfetch` availability is asserted after plugin loading rather than built-in tool loading.

Key expectations:

- `tool_webfetch_schema` exists after `load_builtin_plugins`
- `tool_webfetch_execute` exists after `load_builtin_plugins`

**Step 2: Run tests to verify they fail**

Run: `bash tests/run_tests.sh webfetch`
Expected: FAIL because the plugin file does not exist yet and tests now expect plugin-based loading.

**Step 3: Write minimal implementation**

Create `lib/plugins/webfetch/plugin.sh` by moving the existing `webfetch` implementation from `lib/tools/webfetch.sh` and adding:

```bash
plugin_webfetch_info() {
    echo "Fetch web content and convert it to LLM-friendly formats"
}

plugin_webfetch_hooks() {
    echo ""
}
```

Then remove `lib/tools/webfetch.sh`.

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh webfetch`
Expected: PASS for `webfetch` tests with no behavior regressions.

### Task 3: Verify tool registry behavior still includes webfetch

**Files:**
- Modify: `tests/test_tools.sh`
- Test: `tests/test_tools.sh`

**Step 1: Write the failing test**

Add a tool-registry test that loads built-in plugins and asserts `build_tools_array()` still contains `webfetch`.

```bash
test_build_tools_array_includes_plugin_defined_webfetch() {
    load_builtin_plugins
    local result
    result=$(build_tools_array)
    local names
    names=$(echo "$result" | jq -r '.[].function.name' | sort | tr '\n' ',')
    assert_contains "$names" "webfetch" "tools array contains plugin-defined webfetch"
}
```

**Step 2: Run tests to verify they fail or expose regressions**

Run: `bash tests/run_tests.sh tools`
Expected: FAIL if plugin loading assumptions are incomplete.

**Step 3: Write minimal implementation**

Adjust only the relevant tests or setup if needed. No production code change should be required if plugin sourcing happens before tool array generation in normal flows.

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh tools`
Expected: PASS with `webfetch` still exposed through the tool registry.

### Task 4: Update user-facing docs for plugin ownership

**Files:**
- Modify: `README.md`
- Test: `tests/test_plugins.sh`

**Step 1: Write the failing test**

If appropriate, add or update plugin-listing expectations so built-in plugin documentation covers `webfetch`.

**Step 2: Run test to verify failure or identify doc coverage gaps**

Run: `bash tests/run_tests.sh plugins`
Expected: Optional failure only if doc-coupled tests exist.

**Step 3: Write minimal implementation**

Update `README.md` to describe `webfetch` as plugin-backed rather than built-in-tool-backed.

**Step 4: Run tests to verify they pass**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS.

### Task 5: Run regression verification

**Files:**
- Test: `tests/test_plugins.sh`
- Test: `tests/test_webfetch.sh`
- Test: `tests/test_tools.sh`
- Test: `tests/run_tests.sh`

**Step 1: Run focused verification**

Run: `bash tests/run_tests.sh plugins`
Expected: PASS

Run: `bash tests/run_tests.sh webfetch`
Expected: PASS

Run: `bash tests/run_tests.sh tools`
Expected: PASS

**Step 2: Run full verification**

Run: `bash tests/run_tests.sh`
Expected: PASS with no regressions from moving `webfetch` out of `lib/tools/`.
