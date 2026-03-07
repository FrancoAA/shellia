#!/usr/bin/env bash
# Tests for lib/executor.sh

test_load_dangerous_commands_from_defaults() {
    # Copy defaults to the test config dir
    cp "${SHELLIA_DIR}/defaults/dangerous_commands" "$SHELLIA_DANGEROUS_FILE"
    load_dangerous_commands

    local count=${#DANGEROUS_PATTERNS[@]}
    assert_not_empty "$count" "DANGEROUS_PATTERNS array is populated"
    # Default file has at least rm, sudo, mkfs
    local found_rm=false
    for p in "${DANGEROUS_PATTERNS[@]}"; do
        [[ "$p" == "rm" ]] && found_rm=true
    done
    if $found_rm; then
        _pass "DANGEROUS_PATTERNS includes 'rm'"
    else
        _fail "DANGEROUS_PATTERNS includes 'rm'" "pattern 'rm' not found"
    fi
}

test_load_dangerous_commands_skips_comments() {
    cat > "$SHELLIA_DANGEROUS_FILE" <<'EOF'
# comment
rm
# another comment
sudo
EOF
    load_dangerous_commands

    assert_eq "${#DANGEROUS_PATTERNS[@]}" "2" "load skips comments, keeps 2 patterns"
}

test_load_dangerous_commands_skips_empty_lines() {
    cat > "$SHELLIA_DANGEROUS_FILE" <<'EOF'
rm

sudo

EOF
    load_dangerous_commands

    assert_eq "${#DANGEROUS_PATTERNS[@]}" "2" "load skips blank lines, keeps 2 patterns"
}

test_is_dangerous_matches_dangerous_command() {
    DANGEROUS_PATTERNS=("rm" "sudo" "mkfs")

    is_dangerous "rm -rf /tmp/test"
    local result=$?
    assert_eq "$result" "0" "is_dangerous returns 0 for 'rm -rf /tmp/test'"

    is_dangerous "sudo apt update"
    result=$?
    assert_eq "$result" "0" "is_dangerous returns 0 for 'sudo apt update'"
}

test_is_dangerous_passes_safe_command() {
    DANGEROUS_PATTERNS=("rm" "sudo" "mkfs")

    is_dangerous "ls -la"
    local result=$?
    assert_eq "$result" "1" "is_dangerous returns 1 for 'ls -la'"

    is_dangerous "echo hello"
    result=$?
    assert_eq "$result" "1" "is_dangerous returns 1 for 'echo hello'"
}

test_is_dangerous_empty_patterns() {
    DANGEROUS_PATTERNS=()

    is_dangerous "rm -rf /"
    local result=$?
    assert_eq "$result" "1" "is_dangerous returns 1 when no patterns loaded"
}


