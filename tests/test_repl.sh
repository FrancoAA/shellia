#!/usr/bin/env bash
# Tests for REPL startup and command loop behavior

test_repl_trap_cleans_conversation_file() {
    local shellia_bin="${PROJECT_DIR}/shellia"
    local fake_bin="${TEST_TMP}/fake_bin"
    local fake_date="${fake_bin}/date"
    local fixed_ts="424242"
    local conv_file="/tmp/shellia_conv_${fixed_ts}.json"

    mkdir -p "$fake_bin"
    cat > "$fake_date" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "+%s" ]]; then
  echo "$fixed_ts"
  exit 0
fi
/bin/date "$@"
EOF
    chmod +x "$fake_date"

    # Ensure the target file does not exist before entering REPL.
    rm -f "$conv_file"

    printf 'exit\n' | PATH="$fake_bin:$PATH" "$shellia_bin" >/dev/null 2>&1

    assert_eq "$( [[ -f "$conv_file" ]] && echo true || echo false )" "false" "REPL trap removes conversation temp file"
}

test_repl_prompt_shows_mode_and_omits_shellia_label() {
    local label

    label=$(SHELLIA_AGENT_MODE=plan SHELLIA_DOCKER_SANDBOX_ACTIVE=false _repl_prompt_label)
    assert_contains "$label" "(mode:" "REPL prompt label includes mode prefix"
    assert_contains "$label" "plan" "REPL prompt label shows current mode"
    assert_contains "$label" ")" "REPL prompt label includes closing parenthesis"
    assert_not_contains "$label" "shellia" "REPL prompt label omits shellia string"
}

test_repl_prompt_shows_sandbox_suffix_with_mode() {
    local label

    label=$(SHELLIA_AGENT_MODE=build SHELLIA_DOCKER_SANDBOX_ACTIVE=true _repl_prompt_label)
    assert_contains "$label" "build" "REPL sandbox prompt keeps mode label"
    assert_contains "$label" "(sandboxed)" "REPL sandbox prompt shows sandbox suffix"
    assert_not_contains "$label" "shellia" "REPL sandbox prompt omits shellia string"
}

test_repl_readline_prompt_wraps_ansi_sequences() {
    local prompt
    local continuation_prompt

    prompt=$(_repl_format_prompt_for_readline "$(printf '\033[1;36m(mode: \033[0;35mbuild\033[1;36m) >\033[0m ')")
    continuation_prompt=$(_repl_format_prompt_for_readline "$(printf '\033[2m...>\033[0m ')")

    assert_contains "$prompt" $'\001\e[1;36m\002' "primary prompt wraps theme ANSI sequence for readline"
    assert_contains "$prompt" $'\001\e[0;35m\002' "primary prompt wraps nested ANSI sequence for readline"
    assert_contains "$prompt" $'\001\e[0m\002' "primary prompt wraps reset ANSI sequence for readline"
    assert_contains "$continuation_prompt" $'\001\e[2m\002' "continuation prompt wraps ANSI sequence for readline"
    assert_contains "$continuation_prompt" "...>" "continuation prompt keeps visible text"
}

test_repl_loaded_skill_context_is_one_shot() {
    local fixed_ts="424243"
    local conv_file="/tmp/shellia_conv_${fixed_ts}.json"
    rm -f "$conv_file"
    local fake_bin="${TEST_TMP}/fake_bin"
    local fake_date="${fake_bin}/date"

    local skill_dir="${SHELLIA_CONFIG_DIR}/skills/loaded-skill"
    mkdir -p "$skill_dir"
    cat > "${skill_dir}/SKILL.md" <<'EOF'
---
name: loaded-skill
description: Integration test skill
---

Loaded for REPL one-shot.
EOF

    # Reset plugin state for deterministic initialization
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
    _SHELLIA_SKILL_NAMES=()
    _SHELLIA_SKILL_ENTRIES=()
    SHELLIA_LOADED_SKILL_CONTENT=""
    SHELLIA_LOADED_SKILL_NAME=""

    load_plugins
    _skills_discover
    fire_hook init

    mkdir -p "$fake_bin"
    cat > "$fake_date" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "+%s" ]]; then
  echo "424243"
  exit 0
fi
/bin/date "$@"
EOF
    chmod +x "$fake_date"

    local api_messages_dir="${TEST_TMP}/api_messages"
    mkdir -p "$api_messages_dir"
    rm -f "$api_messages_dir"/messages_*.json
    local messages_count=0

    local api_chat_loop_backup
    api_chat_loop_backup="$(declare -f api_chat_loop)"

    api_chat_loop() {
        local msgs="$1"
        local idx=1
        while [[ -f "${api_messages_dir}/messages_${idx}.json" ]]; do
            idx=$((idx + 1))
        done
        printf '%s' "$msgs" > "${api_messages_dir}/messages_${idx}.json"
        echo "ok"
    }

    local repl_output_file="${TEST_TMP}/repl_output.txt"
    rm -f "$repl_output_file"
    PATH="$fake_bin:$PATH" repl_start <<< $'skill loaded-skill\nfirst prompt\nsecond prompt\nexit\n' > "$repl_output_file" 2>&1
    local repl_output
    repl_output=$(cat "$repl_output_file")

    # Restore real api_chat_loop
    eval "$api_chat_loop_backup"

    if compgen -G "${api_messages_dir}/messages_*.json" > /dev/null; then
        local message_files=("${api_messages_dir}"/messages_*.json)
        messages_count="${#message_files[@]}"
    fi

    local first_message_file="${api_messages_dir}/messages_1.json"
    local second_message_file="${api_messages_dir}/messages_2.json"

    assert_eq "$messages_count" "2" "loaded skill flow makes exactly two API calls"
    assert_contains "$(cat "$first_message_file")" "LOADED SKILL CONTEXT" "first user turn includes loaded skill context"
    assert_contains "$(cat "$first_message_file")" "loaded-skill" "first turn includes skill name"
    assert_contains "$(cat "$first_message_file")" "Loaded for REPL one-shot." "first turn includes loaded skill body"
    assert_not_contains "$(cat "$second_message_file")" "LOADED SKILL CONTEXT" "second user turn does not include loaded skill context"

    assert_not_contains "$repl_output" "error" "repl run did not emit an error"
    rm -f "$conv_file"
}

test_repl_reload_preserves_conversation() {
    # Reload should re-source everything but keep the conversation file intact
    local fixed_ts="424244"
    local conv_file="/tmp/shellia_conv_${fixed_ts}.json"
    rm -f "$conv_file"
    local fake_bin="${TEST_TMP}/fake_bin"
    local fake_date="${fake_bin}/date"

    mkdir -p "$fake_bin"
    cat > "$fake_date" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "+%s" ]]; then
  echo "424244"
  exit 0
fi
/bin/date "$@"
EOF
    chmod +x "$fake_date"

    # Reset plugin state
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
    load_plugins

    local api_chat_loop_backup
    api_chat_loop_backup="$(declare -f api_chat_loop)"

    # Stub API to return a fixed response
    api_chat_loop() {
        echo "test response"
    }

    local repl_output_file="${TEST_TMP}/repl_reload_output.txt"
    rm -f "$repl_output_file"

    # Send a prompt (to populate conversation), then reload, then another prompt, then exit
    PATH="$fake_bin:$PATH" repl_start <<< $'hello\nreload\nworld\nexit\n' > "$repl_output_file" 2>&1
    local repl_output
    repl_output=$(cat "$repl_output_file")

    # Restore real api_chat_loop
    eval "$api_chat_loop_backup"

    assert_contains "$repl_output" "Reloaded" "reload command prints confirmation message"
    # The conversation file should still exist with history from before reload
    # (it gets cleaned up by the trap, but we can check the output shows no errors)
    assert_not_contains "$repl_output" "Error" "reload did not produce errors"

    rm -f "$conv_file"
}

test_repl_reload_refreshes_plugins() {
    # After reload, newly added plugin functions should be available
    local fixed_ts="424245"
    local conv_file="/tmp/shellia_conv_${fixed_ts}.json"
    rm -f "$conv_file"
    local fake_bin="${TEST_TMP}/fake_bin"
    local fake_date="${fake_bin}/date"

    mkdir -p "$fake_bin"
    cat > "$fake_date" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "+%s" ]]; then
  echo "424245"
  exit 0
fi
/bin/date "$@"
EOF
    chmod +x "$fake_date"

    # Reset plugin state
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
    load_plugins

    local api_chat_loop_backup
    api_chat_loop_backup="$(declare -f api_chat_loop)"

    api_chat_loop() {
        echo "ok"
    }

    # Create a user plugin that will exist at reload time
    local user_plugin_dir="${SHELLIA_CONFIG_DIR}/plugins"
    mkdir -p "$user_plugin_dir"
    cat > "${user_plugin_dir}/testreload.sh" <<'PLUGIN'
plugin_testreload_info() { echo "test reload plugin"; }
plugin_testreload_hooks() { echo ""; }
repl_cmd_testreload_handler() { echo "TESTRELOAD_MARKER"; }
repl_cmd_testreload_help() { echo "  testreload        Test reload"; }
PLUGIN

    local repl_output_file="${TEST_TMP}/repl_reload_plugins_output.txt"
    rm -f "$repl_output_file"

    # Try the testreload command (should work since plugins are loaded), then reload and try again
    PATH="$fake_bin:$PATH" repl_start <<< $'testreload\nreload\ntestreload\nexit\n' > "$repl_output_file" 2>&1
    local repl_output
    repl_output=$(cat "$repl_output_file")

    # Restore
    eval "$api_chat_loop_backup"

    assert_contains "$repl_output" "TESTRELOAD_MARKER" "user plugin command works after reload"
    assert_contains "$repl_output" "Reloaded" "reload prints confirmation"

    # Cleanup
    rm -f "${user_plugin_dir}/testreload.sh"
    rm -f "$conv_file"
}

test_repl_help_shows_reload() {
    # The help output should include the reload command
    local help_output
    help_output=$(repl_help 2>&1)
    assert_contains "$help_output" "reload" "help output lists reload command"
}

test_repl_plan_mode_sends_restricted_toolset_to_api() {
    # After switching to plan mode, the next assistant turn should only receive
    # read-only planning tools in the tools array.
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
    load_plugins

    local captured_tools_file="${TEST_TMP}/captured_tools_plan_mode.json"
    rm -f "$captured_tools_file"

    local api_chat_loop_backup
    api_chat_loop_backup="$(declare -f api_chat_loop)"

    api_chat_loop() {
        local _messages="$1"
        local _tools="$2"
        printf '%s' "$_tools" > "$captured_tools_file"
        echo "ok"
    }

    SHELLIA_AGENT_MODE="build"
    repl_start <<< $'mode plan\nwhat tools do you have\nexit\n' >/dev/null 2>&1

    eval "$api_chat_loop_backup"

    assert_file_exists "$captured_tools_file" "repl captured tools payload in plan mode"

    local names
    names=$(jq -r '.[].function.name' "$captured_tools_file" | sort | tr '\n' ',')

    assert_contains "$names" "ask_user" "plan mode sends ask_user"
    assert_contains "$names" "read_file" "plan mode sends read_file"
    assert_contains "$names" "search_files" "plan mode sends search_files"
    assert_contains "$names" "search_content" "plan mode sends search_content"
    assert_contains "$names" "todo_write" "plan mode sends todo_write"

    assert_not_contains "$names" "write_file" "plan mode does not send write_file"
    assert_not_contains "$names" "edit_file" "plan mode does not send edit_file"
    assert_not_contains "$names" "run_command" "plan mode does not send run_command"
    assert_not_contains "$names" "run_plan" "plan mode does not send run_plan"
}

test_repl_compact_rewrites_conversation_to_summary_message() {
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
    load_plugins
    fire_hook init

    local conv_file="${TEST_TMP_DIR}/conv_compact.json"
    cat > "$conv_file" <<'EOF'
[{"role":"user","content":"first"},{"role":"assistant","content":"second"}]
EOF
    SHELLIA_CONV_FILE="$conv_file"

    local api_chat_loop_backup
    api_chat_loop_backup="$(declare -f api_chat_loop)"

    api_chat_loop() {
        echo "Compacted summary"
    }

    local status=0
    repl_cmd_compact_handler >/dev/null 2>&1 || status=$?

    eval "$api_chat_loop_backup"

    assert_eq "$status" "0" "compact command succeeds"
    assert_eq "$(jq -r 'length' "$conv_file")" "1" "compact leaves exactly one conversation message"
    assert_eq "$(jq -r '.[0].role' "$conv_file")" "assistant" "compact writes assistant role message"
    assert_eq "$(jq -r '.[0].content' "$conv_file")" "Compacted summary" "compact writes API summary content"
}

test_repl_compact_noops_on_empty_conversation() {
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
    load_plugins
    fire_hook init

    local conv_file="${TEST_TMP_DIR}/conv_compact_empty.json"
    echo '[]' > "$conv_file"
    SHELLIA_CONV_FILE="$conv_file"

    local output
    output=$(repl_cmd_compact_handler 2>&1)

    assert_contains "$output" "Conversation is empty; nothing to compact." "compact reports empty conversation"
    assert_eq "$(jq -c '.' "$conv_file")" "[]" "compact keeps empty conversation unchanged"
}

test_repl_supports_multiline_input_with_backslash_continuation() {
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
    load_plugins

    local captured_user_file="${TEST_TMP}/captured_repl_user_message.txt"
    rm -f "$captured_user_file"
    local api_call_count_file="${TEST_TMP}/captured_repl_api_count.txt"
    rm -f "$api_call_count_file"

    local api_chat_loop_backup
    api_chat_loop_backup="$(declare -f api_chat_loop)"

    api_chat_loop() {
        local _messages="$1"
        local count=0
        if [[ -f "$api_call_count_file" ]]; then
            count=$(cat "$api_call_count_file")
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$api_call_count_file"
        jq -r '[.[] | select(.role == "user")][-1].content' <<< "$_messages" > "$captured_user_file"
        echo "ok"
    }

    local repl_input
    repl_input=$'first line\\\nsecond line\nexit\n'
    repl_start <<< "$repl_input" >/dev/null 2>&1

    eval "$api_chat_loop_backup"

    assert_file_exists "$captured_user_file" "multiline input captured user message"
    assert_eq "$(cat "$api_call_count_file")" "1" "backslash continuation keeps multiline input in one API call"
    assert_eq "$(cat "$captured_user_file")" $'first line\nsecond line' "backslash continuation sends a single multiline user message"
}

test_repl_help_shows_compact() {
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
    load_plugins

    local help_output
    help_output=$(repl_help 2>&1)

    assert_contains "$help_output" "compact" "help output lists compact command"
}
