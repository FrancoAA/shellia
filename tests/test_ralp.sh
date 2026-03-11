#!/usr/bin/env bash
# Tests for the ralp plugin

# Stub plugin_config_get for tests
plugin_config_get() {
    local plugin="$1" key="$2" default="$3"
    echo "$default"
}

source "${PROJECT_DIR}/lib/plugins/ralp/plugin.sh"

test_ralp_parse_args_defaults() {
    local topic max_iter
    _ralp_parse_args topic max_iter
    assert_eq "$topic" "" "topic empty by default"
    assert_eq "$max_iter" "5" "max_iter defaults to 5"
}

test_ralp_parse_args_topic_only() {
    local topic max_iter
    _ralp_parse_args topic max_iter "add dark mode"
    assert_eq "$topic" "add dark mode" "topic captured"
    assert_eq "$max_iter" "5" "max_iter still defaults to 5"
}

test_ralp_parse_args_max_iter_flag() {
    local topic max_iter
    _ralp_parse_args topic max_iter "--max-iterations=3"
    assert_eq "$topic" "" "topic empty"
    assert_eq "$max_iter" "3" "max_iter from flag"
}

test_ralp_parse_args_topic_and_flag() {
    local topic max_iter
    _ralp_parse_args topic max_iter "add search" "--max-iterations=10"
    assert_eq "$topic" "add search" "topic captured"
    assert_eq "$max_iter" "10" "max_iter from flag"
}

test_ralp_parse_args_max_iter_space_syntax() {
    local topic max_iter
    _ralp_parse_args topic max_iter "--max-iterations" "7"
    assert_eq "$max_iter" "7" "max_iter from space-separated flag"
}

test_ralp_parse_args_max_iter_no_value() {
    # --max-iterations with no value should not hang and should keep default
    local topic max_iter
    _ralp_parse_args topic max_iter "--max-iterations"
    assert_eq "$max_iter" "5" "max_iter defaults when flag has no value"
}

test_ralp_parse_args_max_iter_empty_value() {
    # --max-iterations= (empty) should keep config default
    local topic max_iter
    _ralp_parse_args topic max_iter "--max-iterations="
    assert_eq "$max_iter" "5" "max_iter defaults when = value is empty"
}
