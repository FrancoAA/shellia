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
