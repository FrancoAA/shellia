#!/usr/bin/env bash
# Tests for the shellia entrypoint (CLI flags, subcommands)

SHELLIA_BIN="${PROJECT_DIR}/shellia"

# --- CLI-level tests (call ./shellia as subprocess) ---

test_version_flag() {
    local output
    output=$("$SHELLIA_BIN" --version 2>/dev/null)
    assert_eq "$output" "shellia v0.1.0" "--version prints correct version"
}

test_help_flag() {
    local output
    output=$("$SHELLIA_BIN" --help 2>/dev/null)
    assert_contains "$output" "Usage: shellia" "--help shows usage line"
    assert_contains "$output" "--dry-run" "--help shows --dry-run option"
    assert_contains "$output" "--profile" "--help shows --profile option"
    assert_contains "$output" "profiles" "--help shows profiles subcommand"
    assert_contains "$output" "profile add" "--help shows profile add subcommand"
}

test_help_short_flag() {
    local output
    output=$("$SHELLIA_BIN" -h 2>/dev/null)
    assert_contains "$output" "Usage: shellia" "-h shows usage line"
}

# --- Subcommand error handling ---

test_profile_subcommand_no_profiles_file() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir"
    local output
    output=$(SHELLIA_CONFIG_DIR="$tmpdir" SHELLIA_PROFILES_FILE="$tmpdir/profiles" "$SHELLIA_BIN" profiles 2>/dev/null)
    assert_contains "$output" "No profiles configured" "profiles subcommand handles missing file"
    rm -rf "$tmpdir"
}

test_profile_add_missing_name() {
    local exit_code=0
    "$SHELLIA_BIN" profile add 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "profile add without name exits with error"
}

test_profile_remove_missing_name() {
    local exit_code=0
    "$SHELLIA_BIN" profile remove 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "profile remove without name exits with error"
}

test_profile_bad_subcommand() {
    local exit_code=0
    "$SHELLIA_BIN" profile badcmd 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "profile with unknown subcommand exits with error"
}

test_profile_flag_missing_name() {
    local exit_code=0
    "$SHELLIA_BIN" --profile 2>/dev/null || exit_code=$?
    assert_eq "$exit_code" "1" "--profile without name exits with error"
}
