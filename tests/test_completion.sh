#!/usr/bin/env bash
# Tests for the completion plugin (lib/plugins/completion/plugin.sh)

source "${PROJECT_DIR}/lib/plugins/completion/plugin.sh"

# --- _completion_get_commands tests ---

test_get_commands_includes_builtins() {
    local cmds
    cmds=$(_completion_get_commands)
    assert_contains "$cmds" "help" "includes help"
    assert_contains "$cmds" "reset" "includes reset"
    assert_contains "$cmds" "reload" "includes reload"
    assert_contains "$cmds" "exit" "includes exit"
    assert_contains "$cmds" "quit" "includes quit"
}

test_get_commands_includes_plugin_commands() {
    # Define a mock plugin REPL command
    repl_cmd_testfoo_handler() { :; }

    local cmds
    cmds=$(_completion_get_commands)
    assert_contains "$cmds" "testfoo" "includes plugin command testfoo"

    unset -f repl_cmd_testfoo_handler
}

test_get_commands_dynamic_after_adding_handler() {
    local cmds_before cmds_after

    cmds_before=$(_completion_get_commands)
    assert_not_contains "$cmds_before" "dynacmd" "dynacmd not present before"

    repl_cmd_dynacmd_handler() { :; }
    cmds_after=$(_completion_get_commands)
    assert_contains "$cmds_after" "dynacmd" "dynacmd present after defining handler"

    unset -f repl_cmd_dynacmd_handler
}

# --- _completion_display_matches tests ---

test_display_matches_single_column() {
    local output
    output=$(_completion_display_matches 20 "help" "history" "hostname")
    # With 20 cols and max_len ~8 => col_width 10 => 2 cols
    assert_contains "$output" "help" "output contains help"
    assert_contains "$output" "history" "output contains history"
    assert_contains "$output" "hostname" "output contains hostname"
}

test_display_matches_narrow_terminal() {
    # Very narrow terminal forces 1 column
    local output
    output=$(_completion_display_matches 5 "alpha" "bravo")
    assert_contains "$output" "alpha" "narrow: contains alpha"
    assert_contains "$output" "bravo" "narrow: contains bravo"
}

test_display_matches_empty() {
    local output
    output=$(_completion_display_matches 80)
    assert_eq "$output" "" "empty items produce no output"
}

# --- Tab handler logic tests (simulated via READLINE_LINE/READLINE_POINT) ---

test_tab_single_command_match() {
    READLINE_LINE="hel"
    READLINE_POINT=3
    _completion_tab_handler 2>/dev/null

    assert_eq "$READLINE_LINE" "help " "hel + tab completes to 'help '"
    assert_eq "$READLINE_POINT" "5" "cursor at end of 'help '"
}

test_tab_exact_match_appends_space() {
    READLINE_LINE="help"
    READLINE_POINT=4
    _completion_tab_handler 2>/dev/null

    assert_eq "$READLINE_LINE" "help " "exact match adds trailing space"
}

test_tab_common_prefix_for_multiple_matches() {
    READLINE_LINE="re"
    READLINE_POINT=2
    _completion_tab_handler 2>/dev/null

    # "reset" and "reload" share prefix "re" — common prefix is still "re"
    # so READLINE_LINE stays "re" (no further common prefix beyond "re")
    assert_eq "$READLINE_LINE" "re" "re stays as common prefix"
    assert_eq "$READLINE_POINT" "2" "cursor stays at 2"
}

test_tab_no_match_does_nothing() {
    READLINE_LINE="zzzzz"
    READLINE_POINT=5
    _completion_tab_handler 2>/dev/null

    assert_eq "$READLINE_LINE" "zzzzz" "no match leaves line unchanged"
    assert_eq "$READLINE_POINT" "5" "cursor unchanged on no match"
}

test_tab_empty_line_shows_all() {
    READLINE_LINE=""
    READLINE_POINT=0
    # Should not crash; completions will be all commands (shown to stderr)
    _completion_tab_handler 2>/dev/null

    # With multiple matches and empty prefix, common prefix is "" — line stays empty
    assert_eq "$READLINE_LINE" "" "empty line stays empty with multiple matches"
}

test_tab_file_path_completion() {
    # Second word triggers file path completion
    local test_dir
    test_dir=$(mktemp -d "${TEST_TMP}/comp_XXXXXX")
    touch "${test_dir}/unique_testfile.txt"

    READLINE_LINE="theme ${test_dir}/unique_test"
    READLINE_POINT=${#READLINE_LINE}
    _completion_tab_handler 2>/dev/null

    assert_contains "$READLINE_LINE" "unique_testfile.txt" "file path completed"

    rm -rf "$test_dir"
}

test_tab_directory_gets_trailing_slash() {
    local test_dir
    test_dir=$(mktemp -d "${TEST_TMP}/comp_XXXXXX")
    mkdir "${test_dir}/unique_subdir"

    READLINE_LINE="theme ${test_dir}/unique_sub"
    READLINE_POINT=${#READLINE_LINE}
    _completion_tab_handler 2>/dev/null

    assert_contains "$READLINE_LINE" "unique_subdir/" "directory gets trailing slash"

    rm -rf "$test_dir"
}

test_tab_preserves_text_after_cursor() {
    READLINE_LINE="hel world"
    READLINE_POINT=3
    _completion_tab_handler 2>/dev/null

    assert_eq "$READLINE_LINE" "help  world" "text after cursor preserved"
}

# --- Plugin interface tests ---

test_plugin_info() {
    local info
    info=$(plugin_completion_info)
    assert_not_empty "$info" "plugin_completion_info returns non-empty"
}

test_plugin_hooks() {
    local hooks
    hooks=$(plugin_completion_hooks)
    assert_eq "$hooks" "init" "plugin hooks returns init"
}

test_plugin_on_init_non_tty_is_noop() {
    # When stdin is not a TTY, on_init should return 0 without error
    local exit_code=0
    plugin_completion_on_init < /dev/null 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "0" "on_init succeeds for non-TTY"
}
