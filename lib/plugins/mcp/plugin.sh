#!/usr/bin/env bash
# Plugin: mcp — MCP server integration (Model Context Protocol)
# Connects to external MCP servers via a Python bridge process,
# discovers their tools, and registers them as shellia tools.

_MCP_BRIDGE_PORT=""
_MCP_BRIDGE_PID=""
_MCP_BRIDGE_URL=""
_MCP_DEFAULT_PORT="7898"
_MCP_PLUGIN_DIR=""
_MCP_SERVERS_FILE=""

# --- Plugin interface ---

plugin_mcp_info() {
    echo "MCP server integration (Model Context Protocol)"
}

plugin_mcp_hooks() {
    echo "init shutdown"
}

plugin_mcp_on_init() {
    _MCP_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _MCP_SERVERS_FILE="${SHELLIA_CONFIG_DIR}/plugins/mcp/servers.json"

    # Resolve bridge port from config (default: 7898)
    _MCP_BRIDGE_PORT=$(plugin_config_get "mcp" "port" "$_MCP_DEFAULT_PORT")
    _MCP_BRIDGE_URL="http://127.0.0.1:${_MCP_BRIDGE_PORT}"

    # Ensure python3 is available
    if ! command -v python3 >/dev/null 2>&1; then
        debug_log "plugin:mcp" "python3 not found — MCP plugin disabled"
        return 0
    fi

    # Ensure servers.json exists
    if [[ ! -f "$_MCP_SERVERS_FILE" ]]; then
        debug_log "plugin:mcp" "no servers.json — MCP plugin has no servers to connect"
        return 0
    fi

    # Check if any servers are configured
    local server_count
    server_count=$(jq '.mcpServers | length' "$_MCP_SERVERS_FILE" 2>/dev/null)
    if [[ -z "$server_count" || "$server_count" == "0" ]]; then
        debug_log "plugin:mcp" "no MCP servers configured in servers.json"
        return 0
    fi

    _mcp_start_bridge
}

plugin_mcp_on_shutdown() {
    _mcp_stop_bridge
}

# --- Bridge lifecycle ---

_mcp_start_bridge() {
    local bridge_script="${_MCP_PLUGIN_DIR}/mcp_bridge.py"

    if [[ ! -f "$bridge_script" ]]; then
        debug_log "plugin:mcp" "mcp_bridge.py not found at ${bridge_script}"
        return 1
    fi

    debug_log "plugin:mcp" "starting bridge on port ${_MCP_BRIDGE_PORT}"

    python3 "$bridge_script" \
        --port "$_MCP_BRIDGE_PORT" \
        --config "$_MCP_SERVERS_FILE" \
        >/dev/null 2>&1 &
    _MCP_BRIDGE_PID=$!

    # Wait for bridge to become ready (up to 10 seconds)
    local attempts=0
    local max_attempts=20
    while [[ $attempts -lt $max_attempts ]]; do
        if curl -sf "${_MCP_BRIDGE_URL}/health" >/dev/null 2>&1; then
            debug_log "plugin:mcp" "bridge ready (pid=${_MCP_BRIDGE_PID})"
            _mcp_register_tools
            return 0
        fi
        sleep 0.5
        ((attempts++))
    done

    debug_log "plugin:mcp" "bridge failed to start within timeout"
    _mcp_stop_bridge
    return 1
}

_mcp_stop_bridge() {
    if [[ -n "$_MCP_BRIDGE_PID" ]]; then
        # Try graceful shutdown first
        curl -sf -X POST "${_MCP_BRIDGE_URL}/shutdown" >/dev/null 2>&1 || true
        sleep 0.5

        # Force kill if still running
        if kill -0 "$_MCP_BRIDGE_PID" 2>/dev/null; then
            kill "$_MCP_BRIDGE_PID" 2>/dev/null
            wait "$_MCP_BRIDGE_PID" 2>/dev/null || true
        fi

        debug_log "plugin:mcp" "bridge stopped (pid=${_MCP_BRIDGE_PID})"
        _MCP_BRIDGE_PID=""
    fi
}

# --- Dynamic tool registration ---

_mcp_register_tools() {
    local tools_json
    tools_json=$(curl -sf "${_MCP_BRIDGE_URL}/tools" 2>/dev/null)

    if [[ -z "$tools_json" || "$tools_json" == "[]" ]]; then
        debug_log "plugin:mcp" "no tools discovered from MCP servers"
        return 0
    fi

    local tool_count
    tool_count=$(echo "$tools_json" | jq 'length')
    debug_log "plugin:mcp" "registering ${tool_count} MCP tools"

    local i=0
    while [[ $i -lt $tool_count ]]; do
        local tool_schema
        tool_schema=$(echo "$tools_json" | jq ".[$i]")
        local tool_name
        tool_name=$(echo "$tool_schema" | jq -r '.function.name')
        local server_name
        server_name=$(echo "$tool_schema" | jq -r '.function._mcp_server // ""')

        # Remove internal metadata before caching the schema
        local clean_schema
        clean_schema=$(echo "$tool_schema" | jq 'del(.function._mcp_server)')

        # Define tool_mcp_<name>_schema() — returns cached JSON
        eval "tool_mcp_${tool_name}_schema() { cat <<'SCHEMA_EOF'
${clean_schema}
SCHEMA_EOF
}"

        # Define tool_mcp_<name>_execute() — forwards call to bridge
        eval "tool_mcp_${tool_name}_execute() {
    local args_json=\"\$1\"
    local result
    result=\$(curl -sf -X POST \"${_MCP_BRIDGE_URL}/call\" \
        -H 'Content-Type: application/json' \
        -d \$(printf '{\"server\":\"%s\",\"tool\":\"%s\",\"arguments\":%s}' '${server_name}' '${tool_name}' \"\$args_json\") \
        2>/dev/null)
    if [[ -z \"\$result\" ]]; then
        echo \"Error: MCP bridge request failed for tool '${tool_name}'\"
        return 1
    fi
    echo \"\$result\" | jq -r '.result // .error // \"No result\"'
}"

        debug_log "plugin:mcp" "registered tool: mcp_${tool_name} (server: ${server_name})"
        ((i++))
    done
}

# --- Port config helpers ---

_mcp_get_port() {
    plugin_config_get "mcp" "port" "$_MCP_DEFAULT_PORT"
}

_mcp_set_port() {
    local new_port="$1"
    local config_dir="${SHELLIA_CONFIG_DIR}/plugins/mcp"
    local config_file="${config_dir}/config"

    mkdir -p "$config_dir"

    # Update or add port in config file
    if [[ -f "$config_file" ]] && grep -q "^port=" "$config_file" 2>/dev/null; then
        # Replace existing port line (portable sed)
        local tmp_file
        tmp_file=$(mktemp)
        while IFS= read -r line; do
            if [[ "$line" == port=* ]]; then
                echo "port=${new_port}"
            else
                echo "$line"
            fi
        done < "$config_file" > "$tmp_file"
        mv "$tmp_file" "$config_file"
    else
        echo "port=${new_port}" >> "$config_file"
    fi
}

# --- REPL commands ---

repl_cmd_mcp_handler() {
    local args="${1:-}"
    local subcmd="${args%% *}"
    local rest="${args#* }"
    [[ "$subcmd" == "$args" ]] && rest=""

    case "$subcmd" in
        status)
            _mcp_cmd_status
            ;;
        servers)
            _mcp_cmd_servers
            ;;
        tools)
            _mcp_cmd_tools
            ;;
        port)
            _mcp_cmd_port "$rest"
            ;;
        add)
            _mcp_cmd_add "$rest"
            ;;
        remove)
            _mcp_cmd_remove "$rest"
            ;;
        restart)
            _mcp_cmd_restart
            ;;
        ""|help)
            echo -e "${THEME_ACCENT}mcp commands:${NC}"
            echo "  mcp status              Show bridge status and connected servers"
            echo "  mcp servers             List configured MCP servers"
            echo "  mcp tools               List available MCP tools"
            echo "  mcp port                Show current bridge port"
            echo "  mcp port <number>       Set bridge port (takes effect on restart)"
            echo "  mcp add <name> <cmd>    Add an MCP server"
            echo "  mcp remove <name>       Remove an MCP server"
            echo "  mcp restart             Restart the MCP bridge"
            ;;
        *)
            echo -e "${THEME_WARN}Unknown subcommand: ${subcmd}${NC}"
            echo "Run 'mcp' for usage."
            ;;
    esac
}

repl_cmd_mcp_help() {
    echo -e "  ${THEME_ACCENT}mcp${NC}               MCP server integration"
}

# --- REPL subcommand implementations ---

_mcp_cmd_status() {
    local port
    port=$(_mcp_get_port)
    echo -e "${THEME_ACCENT}MCP Bridge:${NC}"
    echo "  Port: ${port}"

    if [[ -n "$_MCP_BRIDGE_PID" ]] && kill -0 "$_MCP_BRIDGE_PID" 2>/dev/null; then
        echo -e "  Status: ${THEME_SUCCESS}running${NC} (pid: ${_MCP_BRIDGE_PID})"

        local health
        health=$(curl -sf "${_MCP_BRIDGE_URL}/health" 2>/dev/null)
        if [[ -n "$health" ]]; then
            local server_count
            server_count=$(echo "$health" | jq -r '.servers // 0')
            local tool_count
            tool_count=$(echo "$health" | jq -r '.tools // 0')
            echo "  Servers: ${server_count}"
            echo "  Tools: ${tool_count}"
        fi
    else
        echo -e "  Status: ${THEME_WARN}not running${NC}"
    fi
}

_mcp_cmd_servers() {
    if [[ ! -f "$_MCP_SERVERS_FILE" ]]; then
        echo -e "${THEME_MUTED}No servers configured. Use 'mcp add <name> <command>' to add one.${NC}"
        return 0
    fi

    local servers
    servers=$(jq -r '.mcpServers | to_entries[] | "\(.key)\t\(.value.command // .value.url // "unknown")"' "$_MCP_SERVERS_FILE" 2>/dev/null)

    if [[ -z "$servers" ]]; then
        echo -e "${THEME_MUTED}No servers configured.${NC}"
        return 0
    fi

    echo -e "${THEME_ACCENT}Configured MCP servers:${NC}"
    while IFS=$'\t' read -r name cmd; do
        echo "  ${name}: ${cmd}"
    done <<< "$servers"
}

_mcp_cmd_tools() {
    if [[ -z "$_MCP_BRIDGE_PID" ]] || ! kill -0 "$_MCP_BRIDGE_PID" 2>/dev/null; then
        echo -e "${THEME_WARN}Bridge is not running. Use 'mcp restart' to start it.${NC}"
        return 0
    fi

    local tools_json
    tools_json=$(curl -sf "${_MCP_BRIDGE_URL}/tools" 2>/dev/null)

    if [[ -z "$tools_json" || "$tools_json" == "[]" ]]; then
        echo -e "${THEME_MUTED}No tools available.${NC}"
        return 0
    fi

    echo -e "${THEME_ACCENT}Available MCP tools:${NC}"
    echo "$tools_json" | jq -r '.[] | "  mcp_\(.function.name) — \(.function.description // "no description")"'
}

_mcp_cmd_port() {
    local new_port="${1:-}"

    if [[ -z "$new_port" ]]; then
        local current
        current=$(_mcp_get_port)
        echo "Current bridge port: ${current}"
        return 0
    fi

    # Validate port is a number in valid range
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1024 || "$new_port" -gt 65535 ]]; then
        echo -e "${THEME_WARN}Invalid port: ${new_port}. Must be a number between 1024 and 65535.${NC}"
        return 1
    fi

    _mcp_set_port "$new_port"
    echo -e "${THEME_SUCCESS}Port set to ${new_port}.${NC} Run 'mcp restart' to apply."
}

_mcp_cmd_add() {
    local args="$1"
    local name="${args%% *}"
    local rest="${args#* }"
    [[ "$name" == "$args" ]] && rest=""

    if [[ -z "$name" || -z "$rest" ]]; then
        echo "Usage: mcp add <name> <command> [args...]"
        echo "  Example: mcp add filesystem npx -y @modelcontextprotocol/server-filesystem /home"
        return 1
    fi

    local config_dir="${SHELLIA_CONFIG_DIR}/plugins/mcp"
    mkdir -p "$config_dir"

    # Parse command and args
    local cmd="${rest%% *}"
    local cmd_args="${rest#* }"
    [[ "$cmd" == "$rest" ]] && cmd_args=""

    # Build args JSON array
    local args_json="[]"
    if [[ -n "$cmd_args" ]]; then
        args_json=$(printf '%s' "$cmd_args" | jq -R 'split(" ")')
    fi

    # Create or update servers.json
    if [[ ! -f "$_MCP_SERVERS_FILE" ]]; then
        echo '{"mcpServers":{}}' > "$_MCP_SERVERS_FILE"
    fi

    local updated
    updated=$(jq --arg name "$name" --arg cmd "$cmd" --argjson args "$args_json" \
        '.mcpServers[$name] = {"command": $cmd, "args": $args, "env": {}}' \
        "$_MCP_SERVERS_FILE")

    echo "$updated" > "$_MCP_SERVERS_FILE"
    echo -e "${THEME_SUCCESS}Added server '${name}'.${NC} Run 'mcp restart' to connect."
}

_mcp_cmd_remove() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        echo "Usage: mcp remove <name>"
        return 1
    fi

    if [[ ! -f "$_MCP_SERVERS_FILE" ]]; then
        echo -e "${THEME_WARN}No servers configured.${NC}"
        return 1
    fi

    # Check if server exists
    local exists
    exists=$(jq --arg name "$name" '.mcpServers | has($name)' "$_MCP_SERVERS_FILE")
    if [[ "$exists" != "true" ]]; then
        echo -e "${THEME_WARN}Server '${name}' not found.${NC}"
        return 1
    fi

    local updated
    updated=$(jq --arg name "$name" 'del(.mcpServers[$name])' "$_MCP_SERVERS_FILE")
    echo "$updated" > "$_MCP_SERVERS_FILE"
    echo -e "${THEME_SUCCESS}Removed server '${name}'.${NC} Run 'mcp restart' to apply."
}

_mcp_cmd_restart() {
    echo -e "${THEME_MUTED}Restarting MCP bridge...${NC}"
    _mcp_stop_bridge

    # Re-read port from config
    _MCP_BRIDGE_PORT=$(plugin_config_get "mcp" "port" "$_MCP_DEFAULT_PORT")
    _MCP_BRIDGE_URL="http://127.0.0.1:${_MCP_BRIDGE_PORT}"

    if [[ ! -f "$_MCP_SERVERS_FILE" ]]; then
        echo -e "${THEME_WARN}No servers.json found. Add a server first with 'mcp add'.${NC}"
        return 1
    fi

    if _mcp_start_bridge; then
        echo -e "${THEME_SUCCESS}Bridge restarted on port ${_MCP_BRIDGE_PORT}.${NC}"
    else
        echo -e "${THEME_ERROR}Failed to restart bridge.${NC}"
        return 1
    fi
}
