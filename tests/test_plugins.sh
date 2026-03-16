#!/usr/bin/env bash
# Tests for the plugin system (lib/plugins.sh)

# Source plugins.sh since the test runner doesn't include it yet
source "${PROJECT_DIR}/lib/plugins.sh"

# Helper: reset plugin state (tests share the same process)
_reset_plugin_state() {
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
}

# Helper: create a single-file plugin in a directory
# Args: dir, name, [hooks...]
_create_test_plugin() {
    local dir="$1"
    local name="$2"
    shift 2
    local hooks=("$@")

    mkdir -p "$dir"
    local hook_list="${hooks[*]}"

    cat > "${dir}/${name}.sh" <<PLUGIN_EOF
plugin_${name}_info() { echo "Test plugin ${name}"; }
plugin_${name}_hooks() { echo "${hook_list}"; }
PLUGIN_EOF

    # Add hook handler functions for each hook
    for hook in "${hooks[@]}"; do
        cat >> "${dir}/${name}.sh" <<HANDLER_EOF
plugin_${name}_on_${hook}() { debug_log "plugin" "${name}:${hook} called with: \$*"; }
HANDLER_EOF
    done
}

# --- Loading tests ---

test_load_single_file_plugin() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_single"
    _create_test_plugin "$plugin_dir" "alpha" "init"

    _load_plugins_from_dir "$plugin_dir"

    assert_eq "${#SHELLIA_LOADED_PLUGINS[@]}" "1" "one plugin loaded"
    assert_eq "${SHELLIA_LOADED_PLUGINS[0]}" "alpha" "loaded plugin is alpha"
    _plugin_is_loaded "alpha"
    assert_eq "$?" "0" "alpha is loaded"
}

test_load_directory_format_plugin() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_dir"
    mkdir -p "${plugin_dir}/beta"

    cat > "${plugin_dir}/beta/plugin.sh" <<'EOF'
plugin_beta_info() { echo "Beta plugin"; }
plugin_beta_hooks() { echo "init"; }
plugin_beta_on_init() { :; }
EOF

    _load_plugins_from_dir "$plugin_dir"

    assert_eq "${#SHELLIA_LOADED_PLUGINS[@]}" "1" "one plugin loaded (dir format)"
    assert_eq "${SHELLIA_LOADED_PLUGINS[0]}" "beta" "loaded plugin is beta"
    _plugin_is_loaded "beta"
    assert_eq "$?" "0" "beta is loaded"
}

test_load_multiple_plugins_same_hook() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_multi"
    _create_test_plugin "$plugin_dir" "first" "init"
    _create_test_plugin "$plugin_dir" "second" "init"

    _load_plugins_from_dir "$plugin_dir"

    assert_eq "${#SHELLIA_LOADED_PLUGINS[@]}" "2" "two plugins loaded"

    local init_plugins
    init_plugins=$(_hook_get_plugins "init")
    assert_contains "$init_plugins" "first" "init hook has first plugin"
    assert_contains "$init_plugins" "second" "init hook has second plugin"
}

test_load_plugins_from_builtin_and_user() {
    _reset_plugin_state

    # Temporarily override SHELLIA_DIR and SHELLIA_CONFIG_DIR
    local orig_dir="$SHELLIA_DIR"
    local orig_config="$SHELLIA_CONFIG_DIR"
    SHELLIA_DIR="${TEST_TMP}/shellia_home"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/user_config"
    mkdir -p "${SHELLIA_DIR}/lib/plugins"
    mkdir -p "${SHELLIA_CONFIG_DIR}/plugins"
    _create_test_plugin "${SHELLIA_DIR}/lib/plugins" "builtin_p" "init"
    _create_test_plugin "${SHELLIA_CONFIG_DIR}/plugins" "user_p" "init"

    load_plugins

    assert_eq "${#SHELLIA_LOADED_PLUGINS[@]}" "2" "load_plugins loads builtin and user plugins"
    assert_eq "${SHELLIA_LOADED_PLUGINS[0]}" "builtin_p" "builtin loaded first"
    assert_eq "${SHELLIA_LOADED_PLUGINS[1]}" "user_p" "user loaded second"

    SHELLIA_DIR="$orig_dir"
    SHELLIA_CONFIG_DIR="$orig_config"
}

test_load_builtin_plugins_includes_docker() {
    _reset_plugin_state

    load_builtin_plugins

    _plugin_is_loaded "docker"
    assert_eq "$?" "0" "load_builtin_plugins loads docker plugin"
}

test_load_builtin_plugins_includes_scheduler() {
    _reset_plugin_state
    load_builtin_plugins
    _plugin_is_loaded "scheduler"
    assert_eq "$?" "0" "load_builtin_plugins loads scheduler plugin"
}

test_scheduler_cli_subcommand_is_discoverable() {
    _reset_plugin_state
    load_builtin_plugins

    declare -F cli_cmd_schedule_handler >/dev/null 2>&1
    assert_eq "$?" "0" "cli_cmd_schedule_handler exists"

    declare -F cli_cmd_schedule_help >/dev/null 2>&1
    assert_eq "$?" "0" "cli_cmd_schedule_help exists"
}

test_scheduler_repl_command_is_discoverable() {
    _reset_plugin_state
    load_builtin_plugins

    declare -F repl_cmd_schedule_handler >/dev/null 2>&1
    assert_eq "$?" "0" "repl_cmd_schedule_handler exists"

    declare -F repl_cmd_schedule_help >/dev/null 2>&1
    assert_eq "$?" "0" "repl_cmd_schedule_help exists"
}

# --- Scheduler plugin: metadata & storage helpers (Task 2) ---

test_scheduler_plugin_has_expected_metadata() {
    _reset_plugin_state
    load_builtin_plugins

    local info
    info=$(plugin_scheduler_info)
    assert_not_empty "$info" "scheduler plugin info is non-empty"

    assert_eq "$(plugin_scheduler_hooks)" "" "scheduler plugin subscribes to no hooks"
}

test_scheduler_storage_dirs_derive_under_config() {
    _reset_plugin_state
    load_builtin_plugins

    local base="${SHELLIA_CONFIG_DIR}/plugins/scheduler"

    assert_eq "$(_scheduler_dir_jobs)"    "${base}/jobs"    "jobs dir derives under scheduler config"
    assert_eq "$(_scheduler_dir_logs)"    "${base}/logs"    "logs dir derives under scheduler config"
    assert_eq "$(_scheduler_dir_bin)"     "${base}/bin"     "bin dir derives under scheduler config"
    assert_eq "$(_scheduler_dir_launchd)" "${base}/launchd" "launchd dir derives under scheduler config"
    assert_eq "$(_scheduler_dir_cron)"    "${base}/cron"    "cron dir derives under scheduler config"
}

test_scheduler_generate_id_returns_safe_identifier() {
    _reset_plugin_state
    load_builtin_plugins

    local id
    id=$(_scheduler_generate_id "My Cool Job!")
    assert_not_empty "$id" "generated id is non-empty"

    # Must be alphanumeric + hyphens only (filesystem-safe)
    local cleaned
    cleaned=$(echo "$id" | tr -d 'a-zA-Z0-9-')
    assert_eq "$cleaned" "" "generated id contains only alphanumeric chars and hyphens"
}

test_scheduler_ensure_dirs_creates_directories() {
    _reset_plugin_state
    load_builtin_plugins

    _scheduler_ensure_dirs

    local base="${SHELLIA_CONFIG_DIR}/plugins/scheduler"
    [[ -d "${base}/jobs" ]]
    assert_eq "$?" "0" "_scheduler_ensure_dirs creates jobs dir"
    [[ -d "${base}/logs" ]]
    assert_eq "$?" "0" "_scheduler_ensure_dirs creates logs dir"
    [[ -d "${base}/bin" ]]
    assert_eq "$?" "0" "_scheduler_ensure_dirs creates bin dir"
    [[ -d "${base}/launchd" ]]
    assert_eq "$?" "0" "_scheduler_ensure_dirs creates launchd dir"
    [[ -d "${base}/cron" ]]
    assert_eq "$?" "0" "_scheduler_ensure_dirs creates cron dir"
}

test_scheduler_cli_setup_returns_expected_steps() {
    _reset_plugin_state
    load_builtin_plugins

    local setup
    setup=$(cli_cmd_schedule_setup)
    assert_contains "$setup" "config"  "schedule setup includes config"
    assert_contains "$setup" "plugins" "schedule setup includes plugins"
}

test_docker_plugin_is_opt_in() {
    _reset_plugin_state
    load_builtin_plugins

    local hooks
    hooks=$(plugin_docker_hooks)
    assert_eq "$hooks" "" "docker plugin subscribes to no hooks (opt-in only)"
    assert_eq "$SHELLIA_DOCKER_SANDBOX_ACTIVE" "false" "docker sandbox is inactive by default"
}

test_docker_sandbox_start_and_stop() {
    _reset_plugin_state
    load_builtin_plugins

    local _docker_calls=""
    docker() {
        _docker_calls="${_docker_calls}$*\n"
        return 0
    }

    _docker_sandbox_start
    assert_eq "$SHELLIA_DOCKER_IMAGE" "ubuntu:latest" "docker plugin default image is ubuntu:latest"
    assert_eq "$SHELLIA_DOCKER_MOUNT_CWD" "true" "docker plugin mount_cwd defaults to true"
    assert_eq "$SHELLIA_DOCKER_SANDBOX_ACTIVE" "true" "docker sandbox activates after _docker_sandbox_start"
    assert_contains "$_docker_calls" "run" "docker sandbox starts container"

    _docker_sandbox_stop
    assert_eq "$SHELLIA_DOCKER_SANDBOX_ACTIVE" "false" "docker sandbox deactivates after _docker_sandbox_stop"
    assert_eq "$SHELLIA_DOCKER_CONTAINER" "" "docker sandbox clears container name after stop"

    unset -f docker
}

test_docker_cli_subcommand_is_discoverable() {
    _reset_plugin_state
    load_builtin_plugins

    declare -F cli_cmd_docker_handler >/dev/null 2>&1
    assert_eq "$?" "0" "cli_cmd_docker_handler exists"

    declare -F cli_cmd_docker_help >/dev/null 2>&1
    assert_eq "$?" "0" "cli_cmd_docker_help exists"
}

test_docker_repl_command_is_discoverable() {
    _reset_plugin_state
    load_builtin_plugins

    local cmds
    cmds=$(get_plugin_repl_commands)
    assert_contains "$cmds" "docker" "docker REPL command is discoverable"
}

# --- Override test ---

test_user_plugin_overrides_builtin() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_override"

    # Register first version
    mkdir -p "$plugin_dir"
    cat > "${plugin_dir}/myplug.sh" <<'EOF'
plugin_myplug_info() { echo "original"; }
plugin_myplug_hooks() { echo "init cleanup"; }
plugin_myplug_on_init() { :; }
plugin_myplug_on_cleanup() { :; }
EOF
    _load_plugins_from_dir "$plugin_dir"

    assert_eq "${#SHELLIA_LOADED_PLUGINS[@]}" "1" "one plugin before override"

    local init_plugins
    init_plugins=$(_hook_get_plugins "init")
    assert_contains "$init_plugins" "myplug" "init hook before override"

    local cleanup_plugins
    cleanup_plugins=$(_hook_get_plugins "cleanup")
    assert_contains "$cleanup_plugins" "myplug" "cleanup hook before override"

    # Now override with a version that only subscribes to "init" (not "cleanup")
    local override_dir="${TEST_TMP}/plugins_override2"
    mkdir -p "$override_dir"
    cat > "${override_dir}/myplug.sh" <<'EOF'
plugin_myplug_info() { echo "overridden"; }
plugin_myplug_hooks() { echo "init"; }
plugin_myplug_on_init() { :; }
EOF
    _load_plugins_from_dir "$override_dir"

    assert_eq "${#SHELLIA_LOADED_PLUGINS[@]}" "1" "still one plugin after override"

    init_plugins=$(_hook_get_plugins "init")
    assert_contains "$init_plugins" "myplug" "init hook still present after override"

    # cleanup hook should be removed since override doesn't subscribe to it
    cleanup_plugins=$(_hook_get_plugins "cleanup")
    assert_eq "$cleanup_plugins" "" "cleanup hook removed after override"

    # Verify info returns the overridden version
    local info
    info=$(plugin_myplug_info)
    assert_eq "$info" "overridden" "info returns overridden value"
}

# --- Hook dispatch tests ---

test_fire_hook_no_subscribers() {
    _reset_plugin_state

    # Should be a no-op, no errors
    fire_hook "nonexistent_hook" "arg1" "arg2"
    assert_eq "$?" "0" "fire_hook with no subscribers returns 0"
}

test_fire_hook_passes_arguments() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_args"
    mkdir -p "$plugin_dir"

    # Create a plugin that records arguments it receives
    cat > "${plugin_dir}/argtest.sh" <<'EOF'
_ARGTEST_RECEIVED=""
plugin_argtest_info() { echo "argument test plugin"; }
plugin_argtest_hooks() { echo "test_event"; }
plugin_argtest_on_test_event() { _ARGTEST_RECEIVED="$*"; }
EOF

    _load_plugins_from_dir "$plugin_dir"
    fire_hook "test_event" "hello" "world" "42"

    assert_eq "$_ARGTEST_RECEIVED" "hello world 42" "fire_hook passes all arguments to handler"
}

test_fire_hook_multiple_subscribers_called() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_multi_fire"
    mkdir -p "$plugin_dir"

    cat > "${plugin_dir}/aaa.sh" <<'EOF'
_AAA_CALLED=false
plugin_aaa_info() { echo "aaa plugin"; }
plugin_aaa_hooks() { echo "on_start"; }
plugin_aaa_on_on_start() { _AAA_CALLED=true; }
EOF

    cat > "${plugin_dir}/bbb.sh" <<'EOF'
_BBB_CALLED=false
plugin_bbb_info() { echo "bbb plugin"; }
plugin_bbb_hooks() { echo "on_start"; }
plugin_bbb_on_on_start() { _BBB_CALLED=true; }
EOF

    _load_plugins_from_dir "$plugin_dir"
    fire_hook "on_start"

    assert_eq "$_AAA_CALLED" "true" "first subscriber called"
    assert_eq "$_BBB_CALLED" "true" "second subscriber called"
}

test_fire_prompt_hook() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_prompt"
    mkdir -p "$plugin_dir"

    cat > "${plugin_dir}/prompta.sh" <<'EOF'
plugin_prompta_info() { echo "prompt plugin a"; }
plugin_prompta_hooks() { echo "prompt_build"; }
plugin_prompta_on_prompt_build() { echo "Context from A."; }
EOF

    cat > "${plugin_dir}/promptb.sh" <<'EOF'
plugin_promptb_info() { echo "prompt plugin b"; }
plugin_promptb_hooks() { echo "prompt_build"; }
plugin_promptb_on_prompt_build() { echo "Context from B."; }
EOF

    _load_plugins_from_dir "$plugin_dir"
    local result
    result=$(fire_prompt_hook "chat")

    assert_contains "$result" "Context from A." "prompt hook includes output from plugin A"
    assert_contains "$result" "Context from B." "prompt hook includes output from plugin B"
}

test_fire_prompt_hook_no_subscribers() {
    _reset_plugin_state

    local result
    result=$(fire_prompt_hook "chat")

    assert_eq "$result" "" "fire_prompt_hook with no subscribers returns empty"
}

# --- Config tests ---

test_plugin_config_get_reads_value() {
    _reset_plugin_state

    local config_dir="${SHELLIA_CONFIG_DIR}/plugins/myplug"
    mkdir -p "$config_dir"
    echo "api_key=secret123" > "${config_dir}/config"
    echo "timeout=30" >> "${config_dir}/config"

    local val
    val=$(plugin_config_get "myplug" "api_key" "default_val")
    assert_eq "$val" "secret123" "config_get reads api_key"

    val=$(plugin_config_get "myplug" "timeout" "10")
    assert_eq "$val" "30" "config_get reads timeout"
}

test_plugin_config_get_returns_default() {
    _reset_plugin_state

    local val
    val=$(plugin_config_get "nonexistent" "key" "fallback")
    assert_eq "$val" "fallback" "config_get returns default when no config file"
}

test_plugin_config_get_returns_default_for_missing_key() {
    _reset_plugin_state

    local config_dir="${SHELLIA_CONFIG_DIR}/plugins/partial"
    mkdir -p "$config_dir"
    echo "existing_key=value" > "${config_dir}/config"

    local val
    val=$(plugin_config_get "partial" "missing_key" "default_val")
    assert_eq "$val" "default_val" "config_get returns default for missing key"
}

# --- list_plugins tests ---

test_list_plugins_shows_loaded() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_list"
    _create_test_plugin "$plugin_dir" "listme" "init"

    _load_plugins_from_dir "$plugin_dir"

    local output
    output=$(list_plugins 2>&1)

    assert_contains "$output" "listme" "list_plugins shows plugin name"
    assert_contains "$output" "Test plugin listme" "list_plugins shows plugin info"
}

test_list_plugins_empty() {
    _reset_plugin_state

    local output
    output=$(list_plugins 2>&1)

    assert_contains "$output" "No plugins loaded" "list_plugins shows empty message"
}

# --- REPL command integration tests ---

test_get_plugin_repl_commands() {
    _reset_plugin_state

    # Define test REPL command handlers
    repl_cmd_foo_handler() { echo "foo"; }
    repl_cmd_bar_handler() { echo "bar"; }

    local cmds
    cmds=$(get_plugin_repl_commands)

    assert_contains "$cmds" "foo" "get_plugin_repl_commands finds foo"
    assert_contains "$cmds" "bar" "get_plugin_repl_commands finds bar"

    unset -f repl_cmd_foo_handler repl_cmd_bar_handler
}

test_dispatch_repl_command() {
    _reset_plugin_state

    _DISPATCH_RESULT=""
    repl_cmd_test_cmd_handler() { _DISPATCH_RESULT="got: $*"; }

    dispatch_repl_command "test_cmd" "arg1" "arg2"

    assert_eq "$_DISPATCH_RESULT" "got: arg1 arg2" "dispatch_repl_command calls handler with args"

    unset -f repl_cmd_test_cmd_handler
}

test_dispatch_repl_command_hyphen_conversion() {
    _reset_plugin_state

    _HYPHEN_RESULT=""
    repl_cmd_my_cmd_handler() { _HYPHEN_RESULT="called"; }

    dispatch_repl_command "my-cmd"

    assert_eq "$_HYPHEN_RESULT" "called" "dispatch converts hyphens to underscores"

    unset -f repl_cmd_my_cmd_handler
}

test_dispatch_repl_command_unknown() {
    _reset_plugin_state

    local exit_code=0
    dispatch_repl_command "nonexistent_cmd" 2>/dev/null || exit_code=$?

    assert_eq "$exit_code" "1" "dispatch_repl_command returns 1 for unknown command"
}

test_get_plugin_repl_help() {
    _reset_plugin_state

    repl_cmd_demo_help() { echo "  /demo  - Demo command"; }
    repl_cmd_other_help() { echo "  /other - Other command"; }

    local help_output
    help_output=$(get_plugin_repl_help)

    assert_contains "$help_output" "/demo" "get_plugin_repl_help includes demo help"
    assert_contains "$help_output" "/other" "get_plugin_repl_help includes other help"

    unset -f repl_cmd_demo_help repl_cmd_other_help
}

# --- Edge case tests ---

test_plugin_is_loaded_returns_false_for_unknown() {
    _reset_plugin_state

    _plugin_is_loaded "nonexistent"
    assert_eq "$?" "1" "_plugin_is_loaded returns 1 for unknown plugin"
}

test_plugin_missing_info_function() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_bad"
    mkdir -p "$plugin_dir"
    cat > "${plugin_dir}/bad.sh" <<'EOF'
# Missing plugin_bad_info
plugin_bad_hooks() { echo "init"; }
EOF

    _load_plugins_from_dir "$plugin_dir" 2>/dev/null

    _plugin_is_loaded "bad"
    assert_eq "$?" "1" "plugin without info function is not loaded"
}

test_plugin_missing_hooks_function() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_bad2"
    mkdir -p "$plugin_dir"
    cat > "${plugin_dir}/bad2.sh" <<'EOF'
plugin_bad2_info() { echo "bad plugin"; }
# Missing plugin_bad2_hooks
EOF

    _load_plugins_from_dir "$plugin_dir" 2>/dev/null

    _plugin_is_loaded "bad2"
    assert_eq "$?" "1" "plugin without hooks function is not loaded"
}

# --- Integration tests ---

test_integration_full_lifecycle_hook_sequence() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_lifecycle"
    mkdir -p "$plugin_dir"

    # Create a plugin that records the sequence of hooks it receives
    cat > "${plugin_dir}/recorder.sh" <<'EOF'
_RECORDER_SEQUENCE=""
plugin_recorder_info() { echo "lifecycle recorder"; }
plugin_recorder_hooks() { echo "init user_message assistant_message conversation_reset shutdown"; }
plugin_recorder_on_init() { _RECORDER_SEQUENCE="${_RECORDER_SEQUENCE}init,"; }
plugin_recorder_on_user_message() { _RECORDER_SEQUENCE="${_RECORDER_SEQUENCE}user_message,"; }
plugin_recorder_on_assistant_message() { _RECORDER_SEQUENCE="${_RECORDER_SEQUENCE}assistant_message,"; }
plugin_recorder_on_conversation_reset() { _RECORDER_SEQUENCE="${_RECORDER_SEQUENCE}conversation_reset,"; }
plugin_recorder_on_shutdown() { _RECORDER_SEQUENCE="${_RECORDER_SEQUENCE}shutdown,"; }
EOF

    _load_plugins_from_dir "$plugin_dir"

    # Simulate a session lifecycle: init, user sends message, assistant replies, reset, shutdown
    fire_hook "init"
    fire_hook "user_message" "hello"
    fire_hook "assistant_message" "hi there"
    fire_hook "conversation_reset"
    fire_hook "shutdown"

    assert_eq "$_RECORDER_SEQUENCE" "init,user_message,assistant_message,conversation_reset,shutdown," \
        "lifecycle hooks fire in correct sequence"

    unset -f plugin_recorder_info plugin_recorder_hooks
    unset -f plugin_recorder_on_init plugin_recorder_on_user_message plugin_recorder_on_assistant_message
    unset -f plugin_recorder_on_conversation_reset plugin_recorder_on_shutdown
}

test_integration_multiple_plugins_hook_ordering() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_ordering"
    mkdir -p "$plugin_dir"

    # Two plugins subscribing to the same hooks — verify load-order execution
    cat > "${plugin_dir}/alpha.sh" <<'EOF'
_ORDERING_LOG=""
plugin_alpha_info() { echo "alpha plugin"; }
plugin_alpha_hooks() { echo "init shutdown"; }
plugin_alpha_on_init() { _ORDERING_LOG="${_ORDERING_LOG}alpha:init,"; }
plugin_alpha_on_shutdown() { _ORDERING_LOG="${_ORDERING_LOG}alpha:shutdown,"; }
EOF

    cat > "${plugin_dir}/beta.sh" <<'EOF'
plugin_beta_info() { echo "beta plugin"; }
plugin_beta_hooks() { echo "init shutdown"; }
plugin_beta_on_init() { _ORDERING_LOG="${_ORDERING_LOG}beta:init,"; }
plugin_beta_on_shutdown() { _ORDERING_LOG="${_ORDERING_LOG}beta:shutdown,"; }
EOF

    _load_plugins_from_dir "$plugin_dir"
    fire_hook "init"
    fire_hook "shutdown"

    assert_eq "$_ORDERING_LOG" "alpha:init,beta:init,alpha:shutdown,beta:shutdown," \
        "multiple plugins fire in load order per hook"

    unset -f plugin_alpha_info plugin_alpha_hooks plugin_alpha_on_init plugin_alpha_on_shutdown
    unset -f plugin_beta_info plugin_beta_hooks plugin_beta_on_init plugin_beta_on_shutdown
}

test_integration_plugin_provides_repl_commands() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_repl_integration"
    mkdir -p "$plugin_dir"

    # Plugin that defines REPL commands and help
    cat > "${plugin_dir}/myplugin.sh" <<'EOF'
plugin_myplugin_info() { echo "repl command plugin"; }
plugin_myplugin_hooks() { echo "init"; }
plugin_myplugin_on_init() { :; }
repl_cmd_custom_handler() { echo "custom_output: $*"; }
repl_cmd_custom_help() { echo "  /custom  - Custom test command"; }
EOF

    _load_plugins_from_dir "$plugin_dir"

    # Verify REPL command is discoverable
    local cmds
    cmds=$(get_plugin_repl_commands)
    assert_contains "$cmds" "custom" "plugin-provided REPL command is discoverable"

    # Verify dispatch works
    local output
    output=$(dispatch_repl_command "custom" "test_arg")
    assert_eq "$output" "custom_output: test_arg" "plugin REPL command dispatches correctly"

    # Verify help text
    local help
    help=$(get_plugin_repl_help)
    assert_contains "$help" "/custom" "plugin REPL help is included"

    unset -f plugin_myplugin_info plugin_myplugin_hooks plugin_myplugin_on_init
    unset -f repl_cmd_custom_handler repl_cmd_custom_help
}

test_integration_plugin_provides_tool() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_tool_integration"
    mkdir -p "$plugin_dir"

    # Plugin that provides a tool via tool_* convention
    cat > "${plugin_dir}/toolplugin.sh" <<'EOF'
plugin_toolplugin_info() { echo "tool provider plugin"; }
plugin_toolplugin_hooks() { echo "init"; }
plugin_toolplugin_on_init() { :; }
tool_plugin_test() { echo "tool_plugin_test_result"; }
tool_plugin_test_description() { echo "A test tool provided by a plugin"; }
EOF

    _load_plugins_from_dir "$plugin_dir"

    # Verify the tool function exists after plugin load
    declare -F "tool_plugin_test" >/dev/null 2>&1
    assert_eq "$?" "0" "plugin-provided tool function exists"

    # Verify the tool works
    local tool_output
    tool_output=$(tool_plugin_test)
    assert_eq "$tool_output" "tool_plugin_test_result" "plugin-provided tool executes correctly"

    # Verify description function exists
    declare -F "tool_plugin_test_description" >/dev/null 2>&1
    assert_eq "$?" "0" "plugin-provided tool description function exists"

    unset -f plugin_toolplugin_info plugin_toolplugin_hooks plugin_toolplugin_on_init
    unset -f tool_plugin_test tool_plugin_test_description
}

test_integration_before_tool_call_blocking() {
    _reset_plugin_state

    local plugin_dir="${TEST_TMP}/plugins_block"
    mkdir -p "$plugin_dir"

    # Plugin that blocks tool calls via SHELLIA_TOOL_BLOCKED
    cat > "${plugin_dir}/blocker.sh" <<'EOF'
plugin_blocker_info() { echo "tool blocker"; }
plugin_blocker_hooks() { echo "before_tool_call"; }
plugin_blocker_on_before_tool_call() {
    local tool_name="$1"
    if [[ "$tool_name" == "dangerous_tool" ]]; then
        SHELLIA_TOOL_BLOCKED="true"
    fi
}
EOF

    _load_plugins_from_dir "$plugin_dir"

    # Simulate blocking a dangerous tool
    SHELLIA_TOOL_BLOCKED="false"
    fire_hook "before_tool_call" "dangerous_tool" "rm -rf /"
    assert_eq "$SHELLIA_TOOL_BLOCKED" "true" "before_tool_call hook can block a dangerous tool"

    # Non-dangerous tool should not be blocked
    SHELLIA_TOOL_BLOCKED="false"
    fire_hook "before_tool_call" "safe_tool" "echo hello"
    assert_eq "$SHELLIA_TOOL_BLOCKED" "false" "before_tool_call hook does not block safe tool"

    unset -f plugin_blocker_info plugin_blocker_hooks plugin_blocker_on_before_tool_call
    SHELLIA_TOOL_BLOCKED="false"
}

# --- Scheduler plugin: backend resolution helpers (Task 3) ---

test_scheduler_backend_auto_prefers_launchd_on_darwin() {
    _reset_plugin_state
    load_builtin_plugins

    # Mock launchctl as available
    launchctl() { return 0; }

    local backend
    backend=$(_scheduler_resolve_backend "auto" "Darwin")
    assert_eq "$backend" "launchd" "auto backend prefers launchd on Darwin"

    unset -f launchctl
}

test_scheduler_backend_auto_uses_cron_on_linux() {
    _reset_plugin_state
    load_builtin_plugins

    # Mock crontab as available
    crontab() { return 0; }

    local backend
    backend=$(_scheduler_resolve_backend "auto" "Linux")
    assert_eq "$backend" "cron" "auto backend uses cron on Linux"

    unset -f crontab
}

test_scheduler_backend_explicit_launchd_when_available() {
    _reset_plugin_state
    load_builtin_plugins

    # Mock launchctl as available
    launchctl() { return 0; }

    local backend
    backend=$(_scheduler_resolve_backend "launchd")
    assert_eq "$backend" "launchd" "explicit launchd resolves when launchctl available"

    unset -f launchctl
}

test_scheduler_backend_explicit_cron_when_available() {
    _reset_plugin_state
    load_builtin_plugins

    # Mock crontab as available
    crontab() { return 0; }

    local backend
    backend=$(_scheduler_resolve_backend "cron")
    assert_eq "$backend" "cron" "explicit cron resolves when crontab available"

    unset -f crontab
}

test_scheduler_backend_rejects_launchd_when_unavailable() {
    _reset_plugin_state
    load_builtin_plugins

    # Override command to report launchctl unavailable
    command() {
        if [[ "${2:-}" == "launchctl" ]]; then
            return 1
        fi
        builtin command "$@"
    }

    local result
    local exit_code=0
    result=$(_scheduler_resolve_backend "launchd" 2>/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "launchd rejected when launchctl unavailable"

    unset -f command
}

test_scheduler_backend_rejects_cron_when_unavailable() {
    _reset_plugin_state
    load_builtin_plugins

    # Override command to report crontab unavailable
    command() {
        if [[ "${2:-}" == "crontab" ]]; then
            return 1
        fi
        builtin command "$@"
    }

    local result
    local exit_code=0
    result=$(_scheduler_resolve_backend "cron" 2>/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "cron rejected when crontab unavailable"

    unset -f command
}

test_scheduler_backend_auto_falls_back_to_cron_on_darwin_without_launchctl() {
    _reset_plugin_state
    load_builtin_plugins

    # Override command to report launchctl unavailable but crontab available
    command() {
        if [[ "${2:-}" == "launchctl" ]]; then
            return 1
        fi
        if [[ "${2:-}" == "crontab" ]]; then
            return 0
        fi
        builtin command "$@"
    }

    local backend
    backend=$(_scheduler_resolve_backend "auto" "Darwin")
    assert_eq "$backend" "cron" "auto falls back to cron on Darwin without launchctl"

    unset -f command
}

# --- Scheduler plugin: schedule validation helpers (Task 3) ---

test_scheduler_validate_at_accepts_valid_datetime() {
    _reset_plugin_state
    load_builtin_plugins

    _scheduler_validate_at "2026-03-20 09:00" 2>/dev/null
    assert_eq "$?" "0" "validate_at accepts valid datetime"
}

test_scheduler_validate_at_accepts_various_valid_datetimes() {
    _reset_plugin_state
    load_builtin_plugins

    _scheduler_validate_at "2026-12-31 23:59" 2>/dev/null
    assert_eq "$?" "0" "validate_at accepts end-of-year datetime"

    _scheduler_validate_at "2026-01-01 00:00" 2>/dev/null
    assert_eq "$?" "0" "validate_at accepts start-of-year datetime"
}

test_scheduler_validate_at_rejects_invalid_datetime() {
    _reset_plugin_state
    load_builtin_plugins

    local exit_code=0
    _scheduler_validate_at "not-a-date" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_at rejects invalid string"
}

test_scheduler_validate_at_rejects_partial_datetime() {
    _reset_plugin_state
    load_builtin_plugins

    local exit_code=0
    _scheduler_validate_at "2026-03-20" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_at rejects date-only string"
}

test_scheduler_validate_at_rejects_empty() {
    _reset_plugin_state
    load_builtin_plugins

    local exit_code=0
    _scheduler_validate_at "" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_at rejects empty string"
}

test_scheduler_validate_every_accepts_presets() {
    _reset_plugin_state
    load_builtin_plugins

    _scheduler_validate_every "hourly"
    assert_eq "$?" "0" "validate_every accepts hourly"

    _scheduler_validate_every "daily"
    assert_eq "$?" "0" "validate_every accepts daily"

    _scheduler_validate_every "weekly"
    assert_eq "$?" "0" "validate_every accepts weekly"

    _scheduler_validate_every "monthly"
    assert_eq "$?" "0" "validate_every accepts monthly"
}

test_scheduler_validate_every_rejects_invalid() {
    _reset_plugin_state
    load_builtin_plugins

    local exit_code=0
    _scheduler_validate_every "biweekly" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_every rejects unknown preset"
}

test_scheduler_validate_every_rejects_empty() {
    _reset_plugin_state
    load_builtin_plugins

    local exit_code=0
    _scheduler_validate_every "" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_every rejects empty string"
}

test_scheduler_validate_cron_accepts_valid_expression() {
    _reset_plugin_state
    load_builtin_plugins

    _scheduler_validate_cron "0 9 * * 1"
    assert_eq "$?" "0" "validate_cron accepts valid 5-field expression"

    _scheduler_validate_cron "*/15 * * * *"
    assert_eq "$?" "0" "validate_cron accepts step expression"

    _scheduler_validate_cron "0 0 1 1 *"
    assert_eq "$?" "0" "validate_cron accepts specific month/day"
}

test_scheduler_validate_cron_rejects_invalid_expression() {
    _reset_plugin_state
    load_builtin_plugins

    local exit_code=0
    _scheduler_validate_cron "not a cron" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_cron rejects non-cron string"
}

test_scheduler_validate_cron_rejects_wrong_field_count() {
    _reset_plugin_state
    load_builtin_plugins

    local exit_code=0
    _scheduler_validate_cron "0 9 * *" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_cron rejects 4-field expression"

    exit_code=0
    _scheduler_validate_cron "0 9 * * 1 *" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_cron rejects 6-field expression"
}

test_scheduler_validate_cron_rejects_empty() {
    _reset_plugin_state
    load_builtin_plugins

    local exit_code=0
    _scheduler_validate_cron "" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "validate_cron rejects empty string"
}

# --- Scheduler plugin: schedule normalization helpers (Task 3) ---

test_scheduler_normalize_once_passes_through() {
    _reset_plugin_state
    load_builtin_plugins

    local result
    result=$(_scheduler_normalize_schedule "once" "2026-03-20 09:00")
    assert_eq "$result" "2026-03-20 09:00" "normalize once passes datetime through"
}

test_scheduler_normalize_recurring_preset_daily() {
    _reset_plugin_state
    load_builtin_plugins

    local result
    result=$(_scheduler_normalize_schedule "recurring" "daily")
    assert_eq "$result" "0 0 * * *" "normalize recurring daily -> cron"
}

test_scheduler_normalize_recurring_preset_hourly() {
    _reset_plugin_state
    load_builtin_plugins

    local result
    result=$(_scheduler_normalize_schedule "recurring" "hourly")
    assert_eq "$result" "0 * * * *" "normalize recurring hourly -> cron"
}

test_scheduler_normalize_recurring_preset_weekly() {
    _reset_plugin_state
    load_builtin_plugins

    local result
    result=$(_scheduler_normalize_schedule "recurring" "weekly")
    assert_eq "$result" "0 0 * * 0" "normalize recurring weekly -> cron"
}

test_scheduler_normalize_recurring_preset_monthly() {
    _reset_plugin_state
    load_builtin_plugins

    local result
    result=$(_scheduler_normalize_schedule "recurring" "monthly")
    assert_eq "$result" "0 0 1 * *" "normalize recurring monthly -> cron"
}

test_scheduler_normalize_recurring_raw_cron_passes_through() {
    _reset_plugin_state
    load_builtin_plugins

    local result
    result=$(_scheduler_normalize_schedule "recurring" "*/15 * * * *")
    assert_eq "$result" "*/15 * * * *" "normalize recurring raw cron passes through"
}

# --- Scheduler plugin: job metadata CRUD (Task 4) ---

# Helper: point SHELLIA_CONFIG_DIR at a temp dir and ensure scheduler dirs
_scheduler_ensure_dirs_for_test() {
    SHELLIA_CONFIG_DIR="${TEST_TMP}/scheduler_test_$$_${RANDOM}"
    _scheduler_ensure_dirs
}

test_scheduler_create_job_writes_metadata_file() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "say hello")
    assert_not_empty "$job_id" "scheduler create job returns id"

    local job_file="$(_scheduler_dir_jobs)/${job_id}.json"
    assert_file_exists "$job_file" "job metadata file exists"
}

test_scheduler_create_job_json_has_required_fields() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "say hello")

    local job_file="$(_scheduler_dir_jobs)/${job_id}.json"
    local json
    json=$(cat "$job_file")
    assert_valid_json "$json" "job metadata is valid JSON"

    # Required fields
    assert_eq "$(echo "$json" | jq -r '.id')" "$job_id" "json has correct id"
    assert_eq "$(echo "$json" | jq -r '.prompt')" "say hello" "json has correct prompt"
    assert_eq "$(echo "$json" | jq -r '.schedule_type')" "once" "json has schedule_type"
    assert_eq "$(echo "$json" | jq -r '.schedule_value')" "2026-03-20 09:00" "json has schedule_value"
    assert_eq "$(echo "$json" | jq -r '.backend')" "launchd" "json has backend"
    assert_not_empty "$(echo "$json" | jq -r '.created_at')" "json has created_at"
    assert_eq "$(echo "$json" | jq -r '.enabled')" "true" "json has enabled=true"

    # Derived path fields
    assert_not_empty "$(echo "$json" | jq -r '.log_file')" "json has log_file"
    assert_not_empty "$(echo "$json" | jq -r '.wrapper_file')" "json has wrapper_file"
    assert_not_empty "$(echo "$json" | jq -r '.backend_artifact')" "json has backend_artifact"

    # Status fields initialised to empty/zero
    assert_eq "$(echo "$json" | jq -r '.last_run_at')" "" "json has empty last_run_at"
    assert_eq "$(echo "$json" | jq -r '.last_exit_code')" "" "json has empty last_exit_code"
    assert_eq "$(echo "$json" | jq -r '.last_status')" "" "json has empty last_status"
    assert_eq "$(echo "$json" | jq -r '.run_count')" "0" "json has run_count=0"
}

test_scheduler_create_job_derives_paths_from_id() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "run report")

    local json
    json=$(cat "$(_scheduler_dir_jobs)/${job_id}.json")

    assert_contains "$(echo "$json" | jq -r '.log_file')" "$job_id" "log_file contains job id"
    assert_contains "$(echo "$json" | jq -r '.wrapper_file')" "$job_id" "wrapper_file contains job id"
    assert_contains "$(echo "$json" | jq -r '.backend_artifact')" "$job_id" "backend_artifact contains job id"
}

test_scheduler_read_job_returns_json() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "say hello")

    local json
    json=$(_scheduler_read_job "$job_id")
    assert_valid_json "$json" "read_job returns valid JSON"
    assert_eq "$(echo "$json" | jq -r '.id')" "$job_id" "read_job returns correct id"
}

test_scheduler_read_job_returns_1_for_missing() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local exit_code=0
    _scheduler_read_job "nonexistent-id" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "read_job returns 1 for missing job"
}

test_scheduler_update_job_modifies_field() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "say hello")

    _scheduler_update_job "$job_id" "last_status" "success"
    _scheduler_update_job "$job_id" "last_exit_code" "0"
    _scheduler_update_job "$job_id" "run_count" "1"
    _scheduler_update_job "$job_id" "last_run_at" "2026-03-20T09:00:05Z"

    local json
    json=$(_scheduler_read_job "$job_id")
    assert_eq "$(echo "$json" | jq -r '.last_status')" "success" "update_job sets last_status"
    assert_eq "$(echo "$json" | jq -r '.last_exit_code')" "0" "update_job sets last_exit_code"
    assert_eq "$(echo "$json" | jq -r '.run_count')" "1" "update_job sets run_count"
    assert_eq "$(echo "$json" | jq -r '.last_run_at')" "2026-03-20T09:00:05Z" "update_job sets last_run_at"
}

test_scheduler_update_job_preserves_other_fields() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "say hello")

    _scheduler_update_job "$job_id" "last_status" "success"

    local json
    json=$(_scheduler_read_job "$job_id")
    assert_eq "$(echo "$json" | jq -r '.prompt')" "say hello" "update preserves prompt"
    assert_eq "$(echo "$json" | jq -r '.schedule_type')" "once" "update preserves schedule_type"
    assert_eq "$(echo "$json" | jq -r '.enabled')" "true" "update preserves enabled"
}

test_scheduler_list_jobs_returns_all() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    _scheduler_create_job "once" "2026-03-20 09:00" "launchd" "job one" >/dev/null
    _scheduler_create_job "recurring" "daily" "cron" "job two" >/dev/null
    _scheduler_create_job "once" "2026-04-01 12:00" "launchd" "job three" >/dev/null

    local output
    output=$(_scheduler_list_jobs)
    local count
    count=$(echo "$output" | jq -s 'length')
    assert_eq "$count" "3" "list_jobs returns all 3 jobs"
}

test_scheduler_list_jobs_empty_returns_nothing() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local output
    output=$(_scheduler_list_jobs)
    assert_eq "$output" "" "list_jobs returns empty when no jobs"
}

test_scheduler_delete_job_file_removes_metadata() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "say hello")

    local job_file="$(_scheduler_dir_jobs)/${job_id}.json"
    assert_file_exists "$job_file" "job file exists before delete"

    _scheduler_delete_job_file "$job_id"

    assert_eq "$(test -f "$job_file" && echo yes || echo no)" "no" "job file removed after delete"
}

test_scheduler_delete_job_file_returns_1_for_missing() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local exit_code=0
    _scheduler_delete_job_file "nonexistent-id" 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "delete_job_file returns 1 for missing job"
}

# --- Scheduler plugin: wrapper generation and execution (Task 5) ---

# Helper: set up an isolated scheduler test environment with a mock shellia
_scheduler_setup_wrapper_test() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    # Create a mock shellia that echoes output and exits with a controlled code
    MOCK_SHELLIA_DIR="${TEST_TMP}/mock_shellia_$$_${RANDOM}"
    mkdir -p "$MOCK_SHELLIA_DIR"
    cat > "${MOCK_SHELLIA_DIR}/shellia" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock shellia: echoes prompt, exit code controlled by MOCK_EXIT_CODE file
EXIT_CODE_FILE="${MOCK_SHELLIA_DIR}/exit_code"
if [[ -f "$EXIT_CODE_FILE" ]]; then
    code=$(cat "$EXIT_CODE_FILE")
else
    code=0
fi
echo "mock output for: $*"
exit "$code"
MOCK_EOF
    chmod +x "${MOCK_SHELLIA_DIR}/shellia"
    # Replace MOCK_SHELLIA_DIR placeholder inside the mock script
    local escaped_dir
    escaped_dir=$(printf '%s\n' "$MOCK_SHELLIA_DIR" | sed 's/[&/\]/\\&/g')
    sed -i '' "s|\${MOCK_SHELLIA_DIR}|${escaped_dir}|g" "${MOCK_SHELLIA_DIR}/shellia" 2>/dev/null || \
    sed -i "s|\${MOCK_SHELLIA_DIR}|${escaped_dir}|g" "${MOCK_SHELLIA_DIR}/shellia"
}

# Helper: set mock shellia exit code
_scheduler_set_mock_exit_code() {
    echo "$1" > "${MOCK_SHELLIA_DIR}/exit_code"
}

test_scheduler_log_entry_appends_to_log() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "say hello")

    _scheduler_log_entry "$job_id" "test log message"

    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    assert_file_exists "$log_file" "log entry creates log file"

    local log_content
    log_content=$(cat "$log_file")
    assert_contains "$log_content" "test log message" "log contains message"
}

test_scheduler_log_entry_includes_timestamp() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "say hello")

    _scheduler_log_entry "$job_id" "timestamped entry"

    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    local log_content
    log_content=$(cat "$log_file")
    # Timestamp should be in ISO-ish format (at minimum YYYY-MM-DD)
    assert_contains "$log_content" "202" "log entry contains year prefix (timestamp)"
}

test_scheduler_log_entry_appends_multiple() {
    _reset_plugin_state
    load_builtin_plugins
    _scheduler_ensure_dirs_for_test

    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "say hello")

    _scheduler_log_entry "$job_id" "first entry"
    _scheduler_log_entry "$job_id" "second entry"

    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    local log_content
    log_content=$(cat "$log_file")
    assert_contains "$log_content" "first entry" "log has first entry"
    assert_contains "$log_content" "second entry" "log has second entry"
}

test_scheduler_render_wrapper_creates_executable_script() {
    _scheduler_setup_wrapper_test

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "run report")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    assert_file_exists "$wrapper_file" "wrapper script exists at bin/<job_id>.sh"

    [[ -x "$wrapper_file" ]]
    assert_eq "$?" "0" "wrapper script is executable"
}

test_scheduler_render_wrapper_is_valid_bash() {
    _scheduler_setup_wrapper_test

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "run report")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    bash -n "$wrapper_file" 2>/dev/null
    assert_eq "$?" "0" "wrapper script is valid bash syntax"
}

test_scheduler_wrapper_executes_shellia_and_logs_success() {
    _scheduler_setup_wrapper_test
    _scheduler_set_mock_exit_code 0

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "run report")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"

    # Execute the wrapper with the mock shellia
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null

    # Check the log file
    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    assert_file_exists "$log_file" "wrapper creates log file"

    local log_content
    log_content=$(cat "$log_file")
    assert_contains "$log_content" "run report" "log contains the prompt"
    assert_contains "$log_content" "Exit code: 0" "log contains exit code 0"
    assert_contains "$log_content" "Status: success" "log contains success status"
    assert_contains "$log_content" "mock output for:" "log contains output summary"
}

test_scheduler_wrapper_logs_failure_on_nonzero_exit() {
    _scheduler_setup_wrapper_test
    _scheduler_set_mock_exit_code 1

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "failing job")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null

    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    local log_content
    log_content=$(cat "$log_file")
    assert_contains "$log_content" "Exit code: 1" "log contains exit code 1"
    assert_contains "$log_content" "Status: failed" "log contains failed status"
}

test_scheduler_wrapper_updates_metadata_on_success() {
    _scheduler_setup_wrapper_test
    _scheduler_set_mock_exit_code 0

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "run report")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null

    local json
    json=$(_scheduler_read_job "$job_id")

    assert_not_empty "$(echo "$json" | jq -r '.last_run_at')" "last_run_at is set after run"
    assert_eq "$(echo "$json" | jq -r '.last_exit_code')" "0" "last_exit_code is 0"
    assert_eq "$(echo "$json" | jq -r '.last_status')" "success" "last_status is success"
    assert_eq "$(echo "$json" | jq -r '.run_count')" "1" "run_count incremented to 1"
}

test_scheduler_wrapper_updates_metadata_on_failure() {
    _scheduler_setup_wrapper_test
    _scheduler_set_mock_exit_code 2

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "broken job")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null

    local json
    json=$(_scheduler_read_job "$job_id")

    assert_eq "$(echo "$json" | jq -r '.last_exit_code')" "2" "last_exit_code is 2 on failure"
    assert_eq "$(echo "$json" | jq -r '.last_status')" "failed" "last_status is failed"
    assert_eq "$(echo "$json" | jq -r '.run_count')" "1" "run_count incremented to 1 even on failure"
}

test_scheduler_wrapper_increments_run_count() {
    _scheduler_setup_wrapper_test
    _scheduler_set_mock_exit_code 0

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "multi run")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null

    local json
    json=$(_scheduler_read_job "$job_id")
    assert_eq "$(echo "$json" | jq -r '.run_count')" "2" "run_count is 2 after two runs"
}

test_scheduler_wrapper_disables_once_job_on_success() {
    _scheduler_setup_wrapper_test
    _scheduler_set_mock_exit_code 0

    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "one-time task")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null

    local json
    json=$(_scheduler_read_job "$job_id")
    assert_eq "$(echo "$json" | jq -r '.enabled')" "false" "once job disabled after success"
}

test_scheduler_wrapper_keeps_once_job_enabled_on_failure() {
    _scheduler_setup_wrapper_test
    _scheduler_set_mock_exit_code 1

    local job_id
    job_id=$(_scheduler_create_job "once" "2026-03-20 09:00" "launchd" "one-time fail")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null

    local json
    json=$(_scheduler_read_job "$job_id")
    assert_eq "$(echo "$json" | jq -r '.enabled')" "true" "once job stays enabled after failure"
}

test_scheduler_wrapper_skips_disabled_job() {
    _scheduler_setup_wrapper_test

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "disabled job")

    # Disable the job
    _scheduler_update_job "$job_id" "enabled" "false"

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null
    local exit_code=$?

    assert_eq "$exit_code" "0" "wrapper exits cleanly for disabled job"

    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    assert_file_exists "$log_file" "wrapper logs skip entry for disabled job"

    local log_content
    log_content=$(cat "$log_file")
    assert_contains "$log_content" "skip" "log contains skip indication for disabled job"

    # Run count should NOT be incremented
    local json
    json=$(_scheduler_read_job "$job_id")
    assert_eq "$(echo "$json" | jq -r '.run_count')" "0" "run_count not incremented for disabled job"
}

test_scheduler_wrapper_skips_missing_metadata() {
    _scheduler_setup_wrapper_test

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "will be deleted")

    _scheduler_render_wrapper "$job_id"

    # Delete the job metadata file
    _scheduler_delete_job_file "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null
    local exit_code=$?

    assert_eq "$exit_code" "0" "wrapper exits cleanly when metadata is missing"

    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    assert_file_exists "$log_file" "wrapper logs skip entry for missing metadata"

    local log_content
    log_content=$(cat "$log_file")
    assert_contains "$log_content" "skip" "log contains skip indication for missing metadata"
}

test_scheduler_wrapper_log_has_run_separator() {
    _scheduler_setup_wrapper_test
    _scheduler_set_mock_exit_code 0

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "run report")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null

    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    local log_content
    log_content=$(cat "$log_file")
    assert_contains "$log_content" "--- Run:" "log has run separator with timestamp"
}

test_scheduler_wrapper_log_contains_job_id() {
    _scheduler_setup_wrapper_test
    _scheduler_set_mock_exit_code 0

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "run report")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null

    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    local log_content
    log_content=$(cat "$log_file")
    assert_contains "$log_content" "Job: ${job_id}" "log contains Job: <job_id>"
}

test_scheduler_wrapper_truncates_long_output() {
    _scheduler_setup_wrapper_test

    # Create a mock that outputs a lot of text
    cat > "${MOCK_SHELLIA_DIR}/shellia" <<'MOCK_EOF'
#!/usr/bin/env bash
# Generate output longer than 500 chars
python3 -c "print('x' * 1000)" 2>/dev/null || printf '%0.sx' $(seq 1 1000)
exit 0
MOCK_EOF
    chmod +x "${MOCK_SHELLIA_DIR}/shellia"

    local job_id
    job_id=$(_scheduler_create_job "recurring" "daily" "cron" "long output job")

    _scheduler_render_wrapper "$job_id"

    local wrapper_file="$(_scheduler_dir_bin)/${job_id}.sh"
    SHELLIA_DIR="$MOCK_SHELLIA_DIR" bash "$wrapper_file" 2>/dev/null

    local log_file="$(_scheduler_dir_logs)/${job_id}.log"
    local log_content
    log_content=$(cat "$log_file")

    # The output section should not contain all 1000 chars — it should be truncated
    local output_length
    output_length=$(echo "$log_content" | wc -c)
    # Total log (including metadata lines) should be under ~700 chars
    # (500 output + headers). A 1000-char output would push it well over.
    [[ $output_length -lt 900 ]]
    assert_eq "$?" "0" "log output is truncated (total log under 900 chars)"
}
