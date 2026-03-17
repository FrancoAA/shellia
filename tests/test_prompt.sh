#!/usr/bin/env bash
# Tests for lib/prompt.sh

test_detect_shell_returns_basename() {
    local original_shell="$SHELL"

    SHELL="/bin/bash"
    local result
    result=$(detect_shell)
    assert_eq "$result" "bash" "detect_shell returns 'bash' for /bin/bash"

    SHELL="/bin/zsh"
    result=$(detect_shell)
    assert_eq "$result" "zsh" "detect_shell returns 'zsh' for /bin/zsh"

    SHELL="/usr/local/bin/fish"
    result=$(detect_shell)
    assert_eq "$result" "fish" "detect_shell returns 'fish' for /usr/local/bin/fish"

    SHELL="$original_shell"
}

test_detect_shell_defaults_to_bash() {
    local original_shell="${SHELL:-}"
    unset SHELL
    local result
    result=$(detect_shell)
    assert_eq "$result" "bash" "detect_shell defaults to 'bash' when SHELL is unset"
    SHELL="$original_shell"
}

test_build_system_prompt_includes_base_prompt() {
    local prompt
    prompt=$(build_system_prompt)
    assert_contains "$prompt" "shellia" "system prompt includes 'shellia'"
    assert_contains "$prompt" "run_command" "system prompt mentions run_command tool"
    assert_contains "$prompt" "run_plan" "system prompt mentions run_plan tool"
    assert_contains "$prompt" "ask_user" "system prompt mentions ask_user tool"
}

test_build_system_prompt_includes_context() {
    local prompt
    prompt=$(build_system_prompt)
    assert_contains "$prompt" "CONTEXT:" "system prompt includes CONTEXT section"
    assert_contains "$prompt" "shell:" "system prompt includes shell info"
    assert_contains "$prompt" "Operating system:" "system prompt includes OS info"
    assert_contains "$prompt" "Current directory:" "system prompt includes CWD"
}

test_build_system_prompt_includes_mode() {
    local prompt
    prompt=$(build_system_prompt "interactive")
    assert_contains "$prompt" "Mode: interactive" "system prompt includes interactive mode"

    prompt=$(build_system_prompt "single-prompt")
    assert_contains "$prompt" "Mode: single-prompt" "system prompt includes single-prompt mode"

    prompt=$(build_system_prompt "pipe")
    assert_contains "$prompt" "Mode: pipe" "system prompt includes pipe mode"
}

test_build_system_prompt_includes_agent_mode() {
    local prompt
    prompt=$(SHELLIA_AGENT_MODE=plan build_system_prompt "interactive")
    assert_contains "$prompt" "Agent mode: plan" "system prompt includes agent mode"
}

test_build_system_prompt_defaults_to_single_prompt_mode() {
    local prompt
    prompt=$(build_system_prompt)
    assert_contains "$prompt" "Mode: single-prompt" "system prompt defaults to single-prompt mode"
}

test_build_system_prompt_includes_user_additions() {
    # Create a user system prompt with actual content
    cat > "$SHELLIA_USER_PROMPT_FILE" <<'EOF'
# This is a comment
Prefer eza over ls
# Another comment
Use long flags always
EOF

    local prompt
    prompt=$(build_system_prompt)
    assert_contains "$prompt" "USER PREFERENCES:" "system prompt includes USER PREFERENCES section"
    assert_contains "$prompt" "Prefer eza over ls" "system prompt includes user addition"
    assert_contains "$prompt" "Use long flags always" "system prompt includes second user addition"
}

test_build_system_prompt_skips_comments_in_user_additions() {
    cat > "$SHELLIA_USER_PROMPT_FILE" <<'EOF'
# This should not appear
Actual instruction
EOF

    local prompt
    prompt=$(build_system_prompt)
    assert_not_contains "$prompt" "This should not appear" "system prompt skips comments from user file"
    assert_contains "$prompt" "Actual instruction" "system prompt keeps non-comment lines"
}

test_build_system_prompt_no_user_preferences_when_empty() {
    # Create a user prompt that is only comments
    cat > "$SHELLIA_USER_PROMPT_FILE" <<'EOF'
# Only comments here
# Nothing else
EOF

    local prompt
    prompt=$(build_system_prompt)
    assert_not_contains "$prompt" "USER PREFERENCES:" "no USER PREFERENCES when user file has only comments"
}

test_build_system_prompt_no_user_preferences_when_no_file() {
    rm -f "$SHELLIA_USER_PROMPT_FILE"
    local prompt
    prompt=$(build_system_prompt)
    assert_not_contains "$prompt" "USER PREFERENCES:" "no USER PREFERENCES when user file doesn't exist"
}
