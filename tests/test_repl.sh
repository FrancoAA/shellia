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
