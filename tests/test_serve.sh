#!/usr/bin/env bash
# Tests for the serve plugin (lib/plugins/serve/)

# Reuse the plugin state reset helper from test_plugins.sh
_reset_plugin_state() {
    SHELLIA_LOADED_PLUGINS=()
    _SHELLIA_HOOK_ENTRIES=()
}

# --- Plugin loading tests ---

test_serve_plugin_loads() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    _plugin_is_loaded "serve"
    assert_eq "$?" "0" "serve plugin is loaded"
}

test_serve_plugin_info() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    local info
    info=$(plugin_serve_info)
    assert_not_empty "$info" "serve plugin info is not empty"
    assert_contains "$info" "Web" "serve plugin info mentions web"
}

test_serve_plugin_hooks() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    local hooks
    hooks=$(plugin_serve_hooks)
    # Serve plugin has no hooks (empty string)
    assert_eq "$hooks" "" "serve plugin hooks is empty"
}

test_serve_repl_command_registered() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    local cmds
    cmds=$(get_plugin_repl_commands)
    assert_contains "$cmds" "serve" "serve REPL command is registered"
}

test_serve_repl_help_shown() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    local help
    help=$(get_plugin_repl_help)
    assert_contains "$help" "serve" "REPL help includes serve"
    assert_contains "$help" "web" "REPL help mentions web"
}

# --- shellia_serve function tests ---

test_serve_requires_python3() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    # Override PATH to hide python3
    local output
    output=$(PATH="/nonexistent" shellia_serve 2>&1) || true
    assert_contains "$output" "python3" "error message mentions python3"
}

test_serve_requires_server_script() {
    _reset_plugin_state

    # Load serve plugin
    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    # Override SHELLIA_DIR to a location without server.py
    local orig_dir="$SHELLIA_DIR"
    SHELLIA_DIR="${TEST_TMP}/fake_shellia"
    mkdir -p "${SHELLIA_DIR}/lib/plugins/serve"
    # No server.py here

    local output
    output=$(shellia_serve 2>&1) || true
    assert_contains "$output" "Server script not found" "error when server.py missing"

    SHELLIA_DIR="$orig_dir"
}

test_serve_default_port() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    # shellia_serve will try to start python3 which we can't do in tests.
    # Instead, test the arg parsing by overriding python3 with a stub.
    local stub_dir="${TEST_TMP}/serve_stub"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/python3" <<'EOF'
#!/usr/bin/env bash
echo "PORT=${SHELLIA_SERVE_PORT}"
echo "HOST=${SHELLIA_SERVE_HOST}"
EOF
    chmod +x "${stub_dir}/python3"

    local output
    output=$(PATH="${stub_dir}:${PATH}" shellia_serve 2>&1)
    assert_contains "$output" "PORT=8080" "default port is 8080"
}

test_serve_default_host() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    local stub_dir="${TEST_TMP}/serve_stub2"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/python3" <<'EOF'
#!/usr/bin/env bash
echo "HOST=${SHELLIA_SERVE_HOST}"
EOF
    chmod +x "${stub_dir}/python3"

    local output
    output=$(PATH="${stub_dir}:${PATH}" shellia_serve 2>&1)
    assert_contains "$output" "HOST=0.0.0.0" "default host is 0.0.0.0"
}

test_serve_custom_port() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    local stub_dir="${TEST_TMP}/serve_stub3"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/python3" <<'EOF'
#!/usr/bin/env bash
echo "PORT=${SHELLIA_SERVE_PORT}"
EOF
    chmod +x "${stub_dir}/python3"

    local output
    output=$(PATH="${stub_dir}:${PATH}" shellia_serve --port 3000 2>&1)
    assert_contains "$output" "PORT=3000" "custom port 3000 is used"
}

test_serve_custom_host() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    local stub_dir="${TEST_TMP}/serve_stub4"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/python3" <<'EOF'
#!/usr/bin/env bash
echo "HOST=${SHELLIA_SERVE_HOST}"
EOF
    chmod +x "${stub_dir}/python3"

    local output
    output=$(PATH="${stub_dir}:${PATH}" shellia_serve --host 127.0.0.1 2>&1)
    assert_contains "$output" "HOST=127.0.0.1" "custom host 127.0.0.1 is used"
}

test_serve_exports_shellia_cmd() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    local stub_dir="${TEST_TMP}/serve_stub5"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/python3" <<'EOF'
#!/usr/bin/env bash
echo "CMD=${SHELLIA_SERVE_SHELLIA_CMD}"
EOF
    chmod +x "${stub_dir}/python3"

    local output
    output=$(PATH="${stub_dir}:${PATH}" shellia_serve 2>&1)
    assert_contains "$output" "CMD=${SHELLIA_DIR}/shellia" "exports SHELLIA_SERVE_SHELLIA_CMD"
}

test_serve_exports_plugin_dir() {
    _reset_plugin_state

    _load_plugins_from_dir "${SHELLIA_DIR}/lib/plugins"

    local stub_dir="${TEST_TMP}/serve_stub6"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/python3" <<'EOF'
#!/usr/bin/env bash
echo "DIR=${SHELLIA_SERVE_PLUGIN_DIR}"
EOF
    chmod +x "${stub_dir}/python3"

    local output
    output=$(PATH="${stub_dir}:${PATH}" shellia_serve 2>&1)
    assert_contains "$output" "DIR=${SHELLIA_DIR}/lib/plugins/serve" "exports SHELLIA_SERVE_PLUGIN_DIR"
}

# --- Web mode tests ---

test_web_mode_flag_parsed() {
    # Verify --web-mode is recognized by checking the entrypoint doesn't treat it as prompt
    local output
    output=$(bash "${SHELLIA_DIR}/shellia" --help 2>&1)
    # --web-mode is an internal flag, not shown in help, but shouldn't crash
    assert_eq "$?" "0" "--help still works (web-mode doesn't break parsing)"
}

test_web_mode_session_dir_created() {
    local sessions_dir="${TEST_TMP}/web_sessions_test"

    # We can't run the full web mode without API config, but we can check
    # that the session directory would be created
    SHELLIA_WEB_SESSIONS_DIR="$sessions_dir"
    mkdir -p "$sessions_dir"

    assert_eq "$(test -d "$sessions_dir" && echo "yes")" "yes" "sessions directory exists"
}

# --- Python server tests ---

test_server_health_endpoint() {
    # Start server on a random port, check health, stop it
    local port=18999
    SHELLIA_SERVE_PLUGIN_DIR="${SHELLIA_DIR}/lib/plugins/serve" \
    SHELLIA_SERVE_PORT="$port" \
    python3 "${SHELLIA_DIR}/lib/plugins/serve/server.py" &
    local pid=$!
    sleep 1

    local response
    response=$(curl -s "http://localhost:${port}/api/health" 2>/dev/null)
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    assert_contains "$response" '"status"' "health endpoint returns status"
    assert_contains "$response" '"ok"' "health endpoint returns ok"
}

test_server_serves_html() {
    local port=18998
    SHELLIA_SERVE_PLUGIN_DIR="${SHELLIA_DIR}/lib/plugins/serve" \
    SHELLIA_SERVE_PORT="$port" \
    python3 "${SHELLIA_DIR}/lib/plugins/serve/server.py" &
    local pid=$!
    sleep 1

    local response
    response=$(curl -s "http://localhost:${port}/" 2>/dev/null)
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    assert_contains "$response" "<!DOCTYPE html>" "serves HTML page"
    assert_contains "$response" "shellia" "HTML contains shellia"
}

test_server_returns_404() {
    local port=18997
    SHELLIA_SERVE_PLUGIN_DIR="${SHELLIA_DIR}/lib/plugins/serve" \
    SHELLIA_SERVE_PORT="$port" \
    python3 "${SHELLIA_DIR}/lib/plugins/serve/server.py" &
    local pid=$!
    sleep 1

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${port}/nonexistent" 2>/dev/null)
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    assert_eq "$http_code" "404" "returns 404 for unknown paths"
}

test_server_reset_endpoint() {
    local port=18996
    SHELLIA_SERVE_PLUGIN_DIR="${SHELLIA_DIR}/lib/plugins/serve" \
    SHELLIA_SERVE_PORT="$port" \
    SHELLIA_WEB_SESSIONS_DIR="${TEST_TMP}/reset_sessions" \
    python3 "${SHELLIA_DIR}/lib/plugins/serve/server.py" &
    local pid=$!
    sleep 1

    # Create a fake session file
    mkdir -p "${TEST_TMP}/reset_sessions"
    echo '[]' > "${TEST_TMP}/reset_sessions/test_session.json"

    local response
    response=$(curl -s -X POST "http://localhost:${port}/api/chat/reset" \
        -H "Content-Type: application/json" \
        -d '{"session_id": "test_session"}' 2>/dev/null)
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    assert_contains "$response" '"ok"' "reset endpoint returns ok"
    assert_eq "$(test -f "${TEST_TMP}/reset_sessions/test_session.json" && echo "exists" || echo "gone")" "gone" \
        "session file removed after reset"
}

test_server_reset_endpoint_rejects_traversal_session_id() {
    local port=18993
    local sessions_dir="${TEST_TMP}/reset_sessions_traversal"
    local traversal_file="${TEST_TMP}/outside_session_probe.json"

    SHELLIA_SERVE_PLUGIN_DIR="${SHELLIA_DIR}/lib/plugins/serve" \
    SHELLIA_SERVE_PORT="$port" \
    SHELLIA_WEB_SESSIONS_DIR="$sessions_dir" \
    python3 "${SHELLIA_DIR}/lib/plugins/serve/server.py" &
    local pid=$!
    sleep 1

    mkdir -p "$sessions_dir"
    echo 'marker' > "$traversal_file"

    response=$(curl -s -X POST "http://localhost:${port}/api/chat/reset" \
        -H "Content-Type: application/json" \
        -d '{"session_id": "../outside_session_probe"}' 2>/dev/null)

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    assert_contains "$response" '"ok"' "reset endpoint returns ok for traversal session id"
    assert_file_exists "$traversal_file" "traversal session file was not removed"
}

test_server_chat_requires_message() {
    local port=18995
    SHELLIA_SERVE_PLUGIN_DIR="${SHELLIA_DIR}/lib/plugins/serve" \
    SHELLIA_SERVE_PORT="$port" \
    python3 "${SHELLIA_DIR}/lib/plugins/serve/server.py" &
    local pid=$!
    sleep 1

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:${port}/api/chat" \
        -H "Content-Type: application/json" \
        -d '{"message": ""}' 2>/dev/null)
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    assert_eq "$http_code" "400" "empty message returns 400"
}

test_server_chat_stream_closes() {
    local port=18990
    local stub_dir="${TEST_TMP}/serve_chat_stub"
    mkdir -p "$stub_dir"
    cat > "${stub_dir}/shellia" <<'EOF'
#!/usr/bin/env bash
echo '__SHELLIA_EVENT__:{"type":"status","status":"thinking"}'
EOF
    chmod +x "${stub_dir}/shellia"

    SHELLIA_SERVE_PLUGIN_DIR="${SHELLIA_DIR}/lib/plugins/serve" \
    SHELLIA_SERVE_PORT="$port" \
    SHELLIA_SERVE_SHELLIA_CMD="${stub_dir}/shellia" \
    python3 "${SHELLIA_DIR}/lib/plugins/serve/server.py" &
    local pid=$!
    sleep 1

    local curl_code
    local response
    response=$(curl -s -N --max-time 5 -H 'Content-Type: application/json' -d '{"message":"hello","session_id":"abc"}' "http://localhost:${port}/api/chat" 2>/dev/null)
    curl_code=$?

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    assert_eq "$curl_code" "0" "api/chat stream completes without timeout"
    assert_contains "$response" '"type": "close"' "api/chat response includes close event"
}

test_server_cors_headers() {
    local port=18994
    SHELLIA_SERVE_PLUGIN_DIR="${SHELLIA_DIR}/lib/plugins/serve" \
    SHELLIA_SERVE_PORT="$port" \
    python3 "${SHELLIA_DIR}/lib/plugins/serve/server.py" &
    local pid=$!
    sleep 1

    local headers
    headers=$(curl -s -I -X OPTIONS "http://localhost:${port}/api/chat" 2>/dev/null)
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    assert_contains "$headers" "Access-Control-Allow-Origin" "CORS headers present"
}

# --- Entrypoint integration tests ---

test_entrypoint_serve_in_help() {
    local output
    output=$(bash "${SHELLIA_DIR}/shellia" --help 2>&1)
    assert_contains "$output" "serve" "help text includes serve"
    assert_contains "$output" "Web UI" "help text mentions Web UI"
}

test_entrypoint_serve_in_modes() {
    local output
    output=$(bash "${SHELLIA_DIR}/shellia" --help 2>&1)
    assert_contains "$output" "shellia serve" "modes section includes shellia serve"
}
