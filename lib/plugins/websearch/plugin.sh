#!/usr/bin/env bash
# Plugin: websearch — web search via Brave Search API

# --- Plugin interface ---

plugin_websearch_info() {
    echo "Web search via Brave Search API"
}

plugin_websearch_hooks() {
    echo "init"
}

plugin_websearch_on_init() {
    local api_key
    api_key=$(_websearch_get_api_key)

    if [[ -z "$api_key" ]]; then
        debug_log "plugin:websearch" "no API key configured — web_search tool will be unavailable"
    else
        debug_log "plugin:websearch" "API key configured"
    fi
}

# --- API key management ---

# Resolve API key: env var takes precedence over plugin config
_websearch_get_api_key() {
    if [[ -n "${BRAVE_SEARCH_API_KEY:-}" ]]; then
        echo "$BRAVE_SEARCH_API_KEY"
        return 0
    fi

    plugin_config_get "websearch" "api_key" ""
}

# Save API key to plugin config
_websearch_set_api_key() {
    local api_key="$1"
    local config_dir="${SHELLIA_CONFIG_DIR}/plugins/websearch"
    local config_file="${config_dir}/config"

    mkdir -p "$config_dir"
    # Write config (overwrite existing)
    echo "api_key=${api_key}" > "$config_file"
    chmod 600 "$config_file"
}

# --- web_search tool ---

tool_web_search_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "web_search",
        "description": "Search the web using Brave Search. Returns web results with titles, URLs, and content snippets. Use this when you need current information, facts, documentation, or anything that may be beyond your training data.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The search query"
                },
                "count": {
                    "type": "integer",
                    "description": "Number of results to return (1-20, default: 5)"
                }
            },
            "required": ["query"]
        }
    }
}
EOF
}

tool_web_search_execute() {
    local args_json="$1"
    local query count

    query=$(echo "$args_json" | jq -r '.query')
    count=$(echo "$args_json" | jq -r '.count // 5')

    # Validate query
    if [[ -z "$query" || "$query" == "null" ]]; then
        echo "Error: search query is required."
        return 1
    fi

    # Clamp count to valid range
    if [[ "$count" -lt 1 ]] 2>/dev/null; then
        count=1
    elif [[ "$count" -gt 20 ]] 2>/dev/null; then
        count=20
    fi

    # Get API key
    local api_key
    api_key=$(_websearch_get_api_key)

    if [[ -z "$api_key" ]]; then
        echo "Error: Brave Search API key not configured. Set BRAVE_SEARCH_API_KEY environment variable or run 'websearch config <key>' in the REPL."
        return 1
    fi

    echo -e "${THEME_MUTED}Searching: ${query}${NC}" >&2

    # URL-encode the query
    local encoded_query
    encoded_query=$(printf '%s' "$query" | jq -sRr '@uri')

    # Call Brave Web Search API
    local tmp_response
    tmp_response=$(mktemp)

    local http_code
    http_code=$(curl -s -w "%{http_code}" -o "$tmp_response" \
        "https://api.search.brave.com/res/v1/web/search?q=${encoded_query}&count=${count}" \
        -H "Accept: application/json" \
        -H "X-Subscription-Token: ${api_key}" \
        2>/dev/null)

    # Check for HTTP errors
    if [[ "$http_code" -ne 200 ]]; then
        local error_body
        error_body=$(cat "$tmp_response")
        rm -f "$tmp_response"

        debug_log "plugin:websearch" "API error: HTTP ${http_code}"
        echo "Error: Brave Search API returned HTTP ${http_code}."

        # Try to extract error message
        local error_msg
        error_msg=$(echo "$error_body" | jq -r '.message // .error // empty' 2>/dev/null)
        if [[ -n "$error_msg" ]]; then
            echo "Details: ${error_msg}"
        fi
        return 1
    fi

    local response
    response=$(cat "$tmp_response")
    rm -f "$tmp_response"

    # Extract web results
    local result_count
    result_count=$(echo "$response" | jq '.web.results | length' 2>/dev/null)

    if [[ -z "$result_count" || "$result_count" == "0" || "$result_count" == "null" ]]; then
        echo "No results found for: ${query}"
        return 0
    fi

    echo -e "${THEME_SUCCESS}Found ${result_count} result(s)${NC}" >&2

    # Format results for the LLM: title, URL, and description
    echo "$response" | jq -r '
        .web.results[:'"$count"'] | to_entries[] |
        "[\(.key + 1)] \(.value.title)\n    URL: \(.value.url)\n    \(.value.description // "No description")\n"
    ' 2>/dev/null
}

# --- REPL commands ---

repl_cmd_websearch_handler() {
    local args="${1:-}"
    local subcmd="${args%% *}"
    local rest="${args#* }"
    [[ "$subcmd" == "$args" ]] && rest=""

    case "$subcmd" in
        config)
            if [[ -z "$rest" ]]; then
                # Show current config status
                local api_key
                api_key=$(_websearch_get_api_key)
                if [[ -n "$api_key" ]]; then
                    local masked="${api_key:0:8}...${api_key: -4}"
                    echo -e "${THEME_SUCCESS}API key configured: ${masked}${NC}"
                    if [[ -n "${BRAVE_SEARCH_API_KEY:-}" ]]; then
                        echo -e "${THEME_MUTED}Source: BRAVE_SEARCH_API_KEY env var${NC}"
                    else
                        echo -e "${THEME_MUTED}Source: plugin config${NC}"
                    fi
                else
                    echo -e "${THEME_WARN}No API key configured.${NC}"
                    echo ""
                    echo "Set your Brave Search API key:"
                    echo "  websearch config <your-api-key>"
                    echo ""
                    echo "Or set the BRAVE_SEARCH_API_KEY environment variable."
                    echo "Get a key at: https://brave.com/search/api/"
                fi
            else
                # Set the API key
                _websearch_set_api_key "$rest"
                local masked="${rest:0:8}...${rest: -4}"
                echo -e "${THEME_SUCCESS}API key saved: ${masked}${NC}"
            fi
            ;;
        ""|help)
            echo -e "${THEME_ACCENT}websearch commands:${NC}"
            echo "  websearch config          Show API key status"
            echo "  websearch config <key>    Set Brave Search API key"
            ;;
        *)
            echo -e "${THEME_WARN}Unknown subcommand: ${subcmd}${NC}"
            echo "Run 'websearch' for usage."
            ;;
    esac
}

repl_cmd_websearch_help() {
    echo -e "  ${THEME_ACCENT}websearch${NC}         Brave Search configuration"
}
