#!/usr/bin/env bash
# Tests for the tool system (lib/tools.sh and lib/tools/*.sh)

# --- Tool registry tests ---

test_load_tools_sources_tool_files() {
    # load_tools is already called by the test runner, so tool functions should exist
    assert_eq "$(declare -F tool_run_command_schema >/dev/null 2>&1 && echo "yes")" "yes" \
        "tool_run_command_schema is defined after load_tools"
    assert_eq "$(declare -F tool_run_command_execute >/dev/null 2>&1 && echo "yes")" "yes" \
        "tool_run_command_execute is defined after load_tools"
    assert_eq "$(declare -F tool_run_plan_schema >/dev/null 2>&1 && echo "yes")" "yes" \
        "tool_run_plan_schema is defined after load_tools"
    assert_eq "$(declare -F tool_ask_user_schema >/dev/null 2>&1 && echo "yes")" "yes" \
        "tool_ask_user_schema is defined after load_tools"
}

test_build_tools_array_returns_valid_json() {
    local result
    result=$(build_tools_array)
    assert_valid_json "$result" "build_tools_array returns valid JSON"
}

test_build_tools_array_contains_all_tools() {
    local result
    result=$(build_tools_array)

    local count
    count=$(echo "$result" | jq 'length')
    # At least 3 built-in tools; plugins may add more (e.g. load_skill)
    local has_enough=false
    [[ "$count" -ge 3 ]] && has_enough=true
    assert_eq "$has_enough" "true" "build_tools_array returns at least 3 tools (got ${count})"

    # Check all tool names are present
    local names
    names=$(echo "$result" | jq -r '.[].function.name' | sort | tr '\n' ',')
    assert_contains "$names" "ask_user" "tools array contains ask_user"
    assert_contains "$names" "delegate_task" "tools array contains delegate_task"
    assert_contains "$names" "run_command" "tools array contains run_command"
    assert_contains "$names" "run_plan" "tools array contains run_plan"
}

test_bundle_output_includes_delegate_task_tool() {
    local bundle_path="${TEST_TMP}/shellia_bundle"
    bash "${SHELLIA_DIR}/bundle.sh" "$bundle_path" >/dev/null

    local bundle_contents
    bundle_contents=$(cat "$bundle_path")

    assert_contains "$bundle_contents" "tool_delegate_task_schema" "bundled script includes delegate_task schema"
    assert_contains "$bundle_contents" "tool_delegate_task_execute" "bundled script includes delegate_task execute"
}

test_build_tools_array_has_correct_schema_structure() {
    local result
    result=$(build_tools_array)

    # Each tool should have type=function and function.name, function.description, function.parameters
    local first_type
    first_type=$(echo "$result" | jq -r '.[0].type')
    assert_eq "$first_type" "function" "first tool has type=function"

    local first_name
    first_name=$(echo "$result" | jq -r '.[0].function.name')
    assert_not_empty "$first_name" "first tool has a name"

    local first_desc
    first_desc=$(echo "$result" | jq -r '.[0].function.description')
    assert_not_empty "$first_desc" "first tool has a description"

    local first_params
    first_params=$(echo "$result" | jq -r '.[0].function.parameters.type')
    assert_eq "$first_params" "object" "first tool parameters.type is object"
}

# --- Individual tool schema tests ---

test_run_command_schema_valid() {
    local schema
    schema=$(tool_run_command_schema)
    assert_valid_json "$schema" "run_command schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "run_command" "run_command schema has correct name"

    local required
    required=$(echo "$schema" | jq -r '.function.parameters.required[0]')
    assert_eq "$required" "command" "run_command requires 'command' parameter"
}

test_run_plan_schema_valid() {
    local schema
    schema=$(tool_run_plan_schema)
    assert_valid_json "$schema" "run_plan schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "run_plan" "run_plan schema has correct name"

    local required
    required=$(echo "$schema" | jq -r '.function.parameters.required[0]')
    assert_eq "$required" "steps" "run_plan requires 'steps' parameter"
}

test_ask_user_schema_valid() {
    local schema
    schema=$(tool_ask_user_schema)
    assert_valid_json "$schema" "ask_user schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "ask_user" "ask_user schema has correct name"

    local required
    required=$(echo "$schema" | jq -r '.function.parameters.required[0]')
    assert_eq "$required" "question" "ask_user requires 'question' parameter"
}

test_ask_user_execute_rejects_web_mode() {
    local result
    local exit_code=0
    result=$(SHELLIA_WEB_MODE=true tool_ask_user_execute '{"question":"Need input"}' 2>/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "ask_user exits with error in web mode"
    assert_contains "$result" "not supported in web mode" "ask_user shows clear web-mode error"
}

# --- Dispatch tests ---

test_dispatch_tool_call_run_command() {
    DANGEROUS_PATTERNS=()
    SHELLIA_DRY_RUN=false
    local result
    result=$(dispatch_tool_call "run_command" '{"command":"echo dispatch_test_ok"}' 2>/dev/null)
    assert_contains "$result" "dispatch_test_ok" "dispatch_tool_call routes to run_command correctly"
    assert_contains "$result" "[exit code: 0]" "dispatch_tool_call includes exit code"
}

test_dispatch_tool_call_unknown_tool() {
    local exit_code=0
    dispatch_tool_call "nonexistent_tool" '{}' >/dev/null 2>&1 || exit_code=$?
    assert_eq "$exit_code" "1" "dispatch_tool_call returns 1 for unknown tool"
}

# --- run_command tool execution tests ---

test_run_command_execute_basic() {
    DANGEROUS_PATTERNS=()
    SHELLIA_DRY_RUN=false
    local result
    result=$(tool_run_command_execute '{"command":"echo hello_tool"}' 2>/dev/null)
    assert_contains "$result" "hello_tool" "run_command executes and captures output"
    assert_contains "$result" "[exit code: 0]" "run_command reports exit code 0 for success"
}

test_run_command_execute_failing_command() {
    DANGEROUS_PATTERNS=()
    SHELLIA_DRY_RUN=false
    local result
    result=$(tool_run_command_execute '{"command":"false"}' 2>/dev/null)
    assert_contains "$result" "[exit code: 1]" "run_command reports non-zero exit code"
}

test_run_command_execute_dry_run() {
    DANGEROUS_PATTERNS=()
    SHELLIA_DRY_RUN=true
    local result
    result=$(tool_run_command_execute '{"command":"echo should_not_run"}' 2>/dev/null)
    assert_contains "$result" "dry-run" "run_command shows dry-run message"
    assert_not_contains "$result" "should_not_run" "run_command does not execute in dry-run"
    SHELLIA_DRY_RUN=false
}

test_run_command_execute_multiline() {
    DANGEROUS_PATTERNS=()
    SHELLIA_DRY_RUN=false
    local result
    result=$(tool_run_command_execute '{"command":"for i in 1 2 3; do echo item_$i; done"}' 2>/dev/null)
    assert_contains "$result" "item_1" "run_command handles multiline - item 1"
    assert_contains "$result" "item_2" "run_command handles multiline - item 2"
    assert_contains "$result" "item_3" "run_command handles multiline - item 3"
}

# --- run_plan tool execution tests ---

test_run_plan_execute_dry_run() {
    DANGEROUS_PATTERNS=()
    SHELLIA_DRY_RUN=true
    local result
    result=$(tool_run_plan_execute '{"steps":[{"description":"Step one","command":"echo step1"},{"description":"Step two","command":"echo step2"}]}' 2>/dev/null)
    assert_contains "$result" "dry-run" "run_plan shows dry-run message"
    SHELLIA_DRY_RUN=false
}

# --- delegate_task tool tests ---

test_delegate_task_schema_valid() {
    local schema
    schema=$(tool_delegate_task_schema)
    assert_valid_json "$schema" "delegate_task schema is valid JSON"

    local name
    name=$(echo "$schema" | jq -r '.function.name')
    assert_eq "$name" "delegate_task" "delegate_task schema has correct name"

    local required
    required=$(echo "$schema" | jq -r '.function.parameters.required[0]')
    assert_eq "$required" "task" "delegate_task requires 'task' parameter"
}

test_delegate_task_schema_has_context_param() {
    local schema
    schema=$(tool_delegate_task_schema)

    local has_context
    has_context=$(echo "$schema" | jq '.function.parameters.properties | has("context")')
    assert_eq "$has_context" "true" "delegate_task schema has 'context' parameter"
}

test_delegate_task_loaded() {
    assert_eq "$(declare -F tool_delegate_task_schema >/dev/null 2>&1 && echo "yes")" "yes" \
        "tool_delegate_task_schema is defined after load_tools"
    assert_eq "$(declare -F tool_delegate_task_execute >/dev/null 2>&1 && echo "yes")" "yes" \
        "tool_delegate_task_execute is defined after load_tools"
}
