#!/usr/bin/env bash
# Tests for the shellia entrypoint (CLI flags, subcommands)

SHELLIA_BIN="${PROJECT_DIR}/shellia"

_entrypoint_write_test_png_fixture() {
    local path="$1"
    python3 - <<'PY' "$path"
import base64
import pathlib
import sys

png = base64.b64decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF9sAAAAASUVORK5CYII='
)
pathlib.Path(sys.argv[1]).write_bytes(png)
PY
}

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

test_help_ignores_user_plugins() {
    local tmpdir
    tmpdir=$(mktemp -d)

    local user_plugin_dir="${tmpdir}/plugins"
    mkdir -p "$user_plugin_dir"

    local side_effect_file="${tmpdir}/user_plugin_loaded"

    cat > "${user_plugin_dir}/sneaky.sh" <<'EOF'
plugin_sneaky_info() { echo "Sneaky plugin loaded"; }
plugin_sneaky_hooks() { echo ""; }
touch "$SHELLIA_TEST_SIDE_EFFECT_FILE"
EOF

    local output
    local status=0
    output=$(SHELLIA_TEST_SIDE_EFFECT_FILE="$side_effect_file" SHELLIA_CONFIG_DIR="$tmpdir" "$SHELLIA_BIN" --help 2>/dev/null) || status=$?

    assert_eq "$status" "0" "--help exits cleanly with user plugin directory present"
    assert_contains "$output" "Usage: shellia" "--help still renders usage"
    assert_eq "$( [[ -f "$side_effect_file" ]] && echo true || echo false )" "false" "user plugin is not sourced during --help"

    rm -rf "$tmpdir"
}

test_version_ignores_user_plugins() {
    local tmpdir
    tmpdir=$(mktemp -d)

    local user_plugin_dir="${tmpdir}/plugins"
    mkdir -p "$user_plugin_dir"

    local side_effect_file="${tmpdir}/user_plugin_loaded"

    cat > "${user_plugin_dir}/sneaky.sh" <<'EOF'
plugin_sneaky_info() { echo "Sneaky plugin loaded"; }
plugin_sneaky_hooks() { echo ""; }
touch "$SHELLIA_TEST_SIDE_EFFECT_FILE"
EOF

    local output
    local status=0
    output=$(SHELLIA_TEST_SIDE_EFFECT_FILE="$side_effect_file" SHELLIA_CONFIG_DIR="$tmpdir" "$SHELLIA_BIN" --version 2>/dev/null) || status=$?

    assert_eq "$status" "0" "--version exits cleanly with user plugin directory present"
    assert_eq "$output" "shellia v${SHELLIA_VERSION}" "--version output stays exact"
    assert_eq "$( [[ -f "$side_effect_file" ]] && echo true || echo false )" "false" "user plugin is not sourced during --version"

    rm -rf "$tmpdir"
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

test_web_mode_persists_canonical_content_parts() {
    local stub_dir="${TEST_TMP}/entrypoint_web_stub"
    mkdir -p "$stub_dir"

    cat > "${stub_dir}/curl" <<'EOF'
#!/usr/bin/env bash
output_file=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "-o" ]]; then
        output_file="${args[$((i+1))]}"
    fi
done
cat > "$output_file" <<'JSON'
{"choices": [{"message": {"role": "assistant", "content": "web reply"}}]}
JSON
printf '200'
EOF
    chmod +x "${stub_dir}/curl"

    local sessions_dir="${TEST_TMP}/web_mode_sessions"
    local session_file="${sessions_dir}/web-mode-test.json"
    local output
    local status=0
    output=$(PATH="${stub_dir}:${PATH}" \
        SHELLIA_WEB_SESSIONS_DIR="$sessions_dir" \
        SHELLIA_WEB_SESSION_ID="web-mode-test" \
        SHELLIA_API_URL="https://mock.api" \
        SHELLIA_API_KEY="mock-key" \
        SHELLIA_MODEL="mock/model" \
        "$SHELLIA_BIN" --web-mode "hello" 2>/dev/null) || status=$?

    assert_eq "$status" "0" "web mode exits successfully with mocked API"
    assert_contains "$output" "web reply" "web mode prints assistant reply"
    assert_eq "$(jq -r 'length' "$session_file")" "2" "web mode stores user and assistant messages"
    assert_eq "$(jq -r '.[0].content | type' "$session_file")" "array" "web mode stores user content as parts"
    assert_eq "$(jq -r '.[0].content[0].text' "$session_file")" "hello" "web mode preserves user text in canonical format"
    assert_eq "$(jq -r '.[1].content | type' "$session_file")" "array" "web mode stores assistant content as parts"
    assert_eq "$(jq -r '.[1].content[0].text' "$session_file")" "web reply" "web mode preserves assistant text in canonical format"
}

test_single_prompt_expands_file_references_into_api_request() {
    local stub_dir="${TEST_TMP}/entrypoint_single_prompt_stub"
    mkdir -p "$stub_dir"

    cat > "${stub_dir}/curl" <<'EOF'
#!/usr/bin/env bash
output_file=""
request_data=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "-o" ]]; then
        output_file="${args[$((i+1))]}"
    fi
    if [[ "${args[$i]}" == "-d" ]]; then
        request_data="${args[$((i+1))]}"
    fi
done
printf '%s' "$request_data" > "$SHELLIA_CAPTURE_REQUEST_FILE"
cat > "$output_file" <<'JSON'
{"choices": [{"message": {"role": "assistant", "content": "ok"}}]}
JSON
printf '200'
EOF
    chmod +x "${stub_dir}/curl"

    local image_path="$TEST_TMP/sample.png"
    local text_path="$TEST_TMP/notes.txt"
    local request_file="$TEST_TMP/request.json"
    _entrypoint_write_test_png_fixture "$image_path"
    printf 'line one\nline two\n' > "$text_path"

    local output
    local status=0
    output=$(PATH="${stub_dir}:${PATH}" \
        SHELLIA_CAPTURE_REQUEST_FILE="$request_file" \
        SHELLIA_API_URL="https://mock.api" \
        SHELLIA_API_KEY="mock-key" \
        SHELLIA_MODEL="mock/model" \
        "$SHELLIA_BIN" "Compare @$image_path with @$text_path" 2>/dev/null) || status=$?

    assert_eq "$status" "0" "single-prompt mode exits successfully with referenced files"
    assert_contains "$output" "ok" "single-prompt mode prints assistant reply"
    assert_eq "$(jq -r '.messages[1].content[1].type' "$request_file")" "image_url" "single-prompt request serializes image reference"
    assert_contains "$(jq -r '.messages[1].content[3].text' "$request_file")" "line one" "single-prompt request inlines text file contents"
}
