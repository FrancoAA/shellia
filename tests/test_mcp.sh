#!/usr/bin/env bash
# Tests for the MCP plugin (lib/plugins/mcp/plugin.sh)

source "${PROJECT_DIR}/lib/plugins/mcp/plugin.sh"

# Helper: reset MCP plugin state
_reset_mcp_state() {
    _MCP_BRIDGE_PORT=""
    _MCP_BRIDGE_PID=""
    _MCP_BRIDGE_URL=""
    _MCP_SERVERS_FILE=""
    _MCP_PLUGIN_DIR="${PROJECT_DIR}/lib/plugins/mcp"
}

# --- Plugin interface tests ---

test_mcp_plugin_info() {
    local info
    info=$(plugin_mcp_info)
    assert_contains "$info" "MCP" "plugin info mentions MCP"
}

test_mcp_plugin_hooks() {
    local hooks
    hooks=$(plugin_mcp_hooks)
    assert_contains "$hooks" "init" "hooks include init"
    assert_contains "$hooks" "shutdown" "hooks include shutdown"
}

# --- Port config tests ---

test_mcp_default_port() {
    _reset_mcp_state
    assert_eq "$_MCP_DEFAULT_PORT" "7898" "default port is 7898"
}

test_mcp_port_from_config() {
    _reset_mcp_state
    local config_dir="${SHELLIA_CONFIG_DIR}/plugins/mcp"
    mkdir -p "$config_dir"
    echo "port=9999" > "${config_dir}/config"

    local port
    port=$(_mcp_get_port)
    assert_eq "$port" "9999" "port read from config"
}

test_mcp_port_default_when_no_config() {
    _reset_mcp_state
    # Ensure no config file exists
    rm -f "${SHELLIA_CONFIG_DIR}/plugins/mcp/config"

    local port
    port=$(_mcp_get_port)
    assert_eq "$port" "7898" "port defaults to 7898 when no config"
}

test_mcp_set_port_creates_config() {
    _reset_mcp_state
    rm -rf "${SHELLIA_CONFIG_DIR}/plugins/mcp"

    _mcp_set_port "8080"

    local config_file="${SHELLIA_CONFIG_DIR}/plugins/mcp/config"
    assert_eq "$(grep '^port=' "$config_file" | cut -d= -f2-)" "8080" "port saved to config"
}

test_mcp_set_port_updates_existing() {
    _reset_mcp_state
    local config_dir="${SHELLIA_CONFIG_DIR}/plugins/mcp"
    mkdir -p "$config_dir"
    echo "port=1234" > "${config_dir}/config"

    _mcp_set_port "5678"

    local port
    port=$(grep '^port=' "${config_dir}/config" | cut -d= -f2-)
    assert_eq "$port" "5678" "port updated in existing config"
}

test_mcp_set_port_preserves_other_config() {
    _reset_mcp_state
    local config_dir="${SHELLIA_CONFIG_DIR}/plugins/mcp"
    mkdir -p "$config_dir"
    printf 'enabled=true\nport=1234\nother=value\n' > "${config_dir}/config"

    _mcp_set_port "9876"

    local config_file="${config_dir}/config"
    assert_contains "$(cat "$config_file")" "enabled=true" "other config preserved (enabled)"
    assert_contains "$(cat "$config_file")" "other=value" "other config preserved (other)"
    assert_contains "$(cat "$config_file")" "port=9876" "port updated"
    assert_not_contains "$(cat "$config_file")" "port=1234" "old port removed"
}

# --- Port validation via REPL command ---

test_mcp_cmd_port_show() {
    _reset_mcp_state
    rm -f "${SHELLIA_CONFIG_DIR}/plugins/mcp/config"

    local output
    output=$(_mcp_cmd_port "")
    assert_contains "$output" "7898" "port show displays default"
}

test_mcp_cmd_port_invalid_low() {
    _reset_mcp_state
    local output
    output=$(_mcp_cmd_port "80" 2>&1)
    assert_contains "$output" "Invalid" "rejects port below 1024"
}

test_mcp_cmd_port_invalid_high() {
    _reset_mcp_state
    local output
    output=$(_mcp_cmd_port "99999" 2>&1)
    assert_contains "$output" "Invalid" "rejects port above 65535"
}

test_mcp_cmd_port_invalid_string() {
    _reset_mcp_state
    local output
    output=$(_mcp_cmd_port "abc" 2>&1)
    assert_contains "$output" "Invalid" "rejects non-numeric port"
}

test_mcp_cmd_port_valid() {
    _reset_mcp_state
    local output
    output=$(_mcp_cmd_port "8080" 2>&1)
    assert_contains "$output" "8080" "accepts valid port"
    assert_contains "$output" "restart" "mentions restart needed"
}

# --- Server config tests ---

test_mcp_cmd_add_creates_servers_json() {
    _reset_mcp_state
    _MCP_SERVERS_FILE="${SHELLIA_CONFIG_DIR}/plugins/mcp/servers.json"
    mkdir -p "${SHELLIA_CONFIG_DIR}/plugins/mcp"
    rm -f "$_MCP_SERVERS_FILE"

    local output
    output=$(_mcp_cmd_add "myserver npx -y @modelcontextprotocol/server-test" 2>&1)

    assert_contains "$output" "Added" "add reports success"
    local server_cmd
    server_cmd=$(jq -r '.mcpServers.myserver.command' "$_MCP_SERVERS_FILE")
    assert_eq "$server_cmd" "npx" "server command saved"
}

test_mcp_cmd_remove_existing() {
    _reset_mcp_state
    _MCP_SERVERS_FILE="${SHELLIA_CONFIG_DIR}/plugins/mcp/servers.json"
    mkdir -p "${SHELLIA_CONFIG_DIR}/plugins/mcp"
    echo '{"mcpServers":{"testsvr":{"command":"echo","args":[],"env":{}}}}' > "$_MCP_SERVERS_FILE"

    local output
    output=$(_mcp_cmd_remove "testsvr" 2>&1)
    assert_contains "$output" "Removed" "remove reports success"

    local count
    count=$(jq '.mcpServers | length' "$_MCP_SERVERS_FILE")
    assert_eq "$count" "0" "server removed from config"
}

test_mcp_cmd_remove_nonexistent() {
    _reset_mcp_state
    _MCP_SERVERS_FILE="${SHELLIA_CONFIG_DIR}/plugins/mcp/servers.json"
    mkdir -p "${SHELLIA_CONFIG_DIR}/plugins/mcp"
    echo '{"mcpServers":{}}' > "$_MCP_SERVERS_FILE"

    local output
    output=$(_mcp_cmd_remove "nope" 2>&1)
    assert_contains "$output" "not found" "remove reports not found"
}

# --- REPL command dispatch ---

test_mcp_repl_handler_help() {
    _reset_mcp_state
    local output
    output=$(repl_cmd_mcp_handler "" 2>&1)
    assert_contains "$output" "mcp commands" "help shows command list"
    assert_contains "$output" "status" "help mentions status"
    assert_contains "$output" "port" "help mentions port"
    assert_contains "$output" "servers" "help mentions servers"
    assert_contains "$output" "tools" "help mentions tools"
}

test_mcp_repl_handler_unknown() {
    _reset_mcp_state
    local output
    output=$(repl_cmd_mcp_handler "foobar" 2>&1)
    assert_contains "$output" "Unknown" "unknown subcommand reported"
}

test_mcp_repl_help_line() {
    local output
    output=$(repl_cmd_mcp_help)
    assert_contains "$output" "mcp" "help line mentions mcp"
    assert_contains "$output" "MCP" "help line mentions MCP"
}

# --- Init behavior tests ---

test_mcp_init_no_python3() {
    _reset_mcp_state

    # Override command -v to pretend python3 doesn't exist
    command() {
        if [[ "$2" == "python3" ]]; then
            return 1
        fi
        builtin command "$@"
    }

    # Should return silently without error
    plugin_mcp_on_init
    assert_eq "$?" "0" "init succeeds when python3 not found"

    unset -f command
}

test_mcp_init_no_servers_file() {
    _reset_mcp_state
    _MCP_SERVERS_FILE="${SHELLIA_CONFIG_DIR}/plugins/mcp/nonexistent.json"

    plugin_mcp_on_init
    assert_eq "$?" "0" "init succeeds when servers.json missing"
}

test_mcp_init_empty_servers() {
    _reset_mcp_state
    local config_dir="${SHELLIA_CONFIG_DIR}/plugins/mcp"
    mkdir -p "$config_dir"
    echo '{"mcpServers":{}}' > "${config_dir}/servers.json"
    _MCP_SERVERS_FILE="${config_dir}/servers.json"

    plugin_mcp_on_init
    assert_eq "$?" "0" "init succeeds with empty servers"
}

# --- Bridge status when not running ---

test_mcp_cmd_status_not_running() {
    _reset_mcp_state
    _MCP_BRIDGE_PID=""

    local output
    output=$(_mcp_cmd_status 2>&1)
    assert_contains "$output" "not running" "status shows not running"
}

test_mcp_cmd_tools_not_running() {
    _reset_mcp_state
    _MCP_BRIDGE_PID=""

    local output
    output=$(_mcp_cmd_tools 2>&1)
    assert_contains "$output" "not running" "tools shows not running"
}

test_mcp_cmd_servers_no_config() {
    _reset_mcp_state
    _MCP_SERVERS_FILE="${SHELLIA_CONFIG_DIR}/plugins/mcp/nonexistent.json"

    local output
    output=$(_mcp_cmd_servers 2>&1)
    assert_contains "$output" "No servers" "servers shows no config"
}
