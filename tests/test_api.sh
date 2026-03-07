#!/usr/bin/env bash
# Tests for lib/api.sh

test_build_single_messages_produces_valid_json() {
    local result
    result=$(build_single_messages "You are helpful." "Hello")
    assert_valid_json "$result" "build_single_messages returns valid JSON"
}

test_build_single_messages_has_system_and_user() {
    local result
    result=$(build_single_messages "System prompt here" "User message here")

    local count
    count=$(echo "$result" | jq 'length')
    assert_eq "$count" "2" "build_single_messages creates 2 messages"

    local system_role
    system_role=$(echo "$result" | jq -r '.[0].role')
    assert_eq "$system_role" "system" "first message role is 'system'"

    local user_role
    user_role=$(echo "$result" | jq -r '.[1].role')
    assert_eq "$user_role" "user" "second message role is 'user'"

    local system_content
    system_content=$(echo "$result" | jq -r '.[0].content')
    assert_eq "$system_content" "System prompt here" "system message has correct content"

    local user_content
    user_content=$(echo "$result" | jq -r '.[1].content')
    assert_eq "$user_content" "User message here" "user message has correct content"
}

test_build_conversation_messages_includes_history() {
    # Create a conv file with one exchange
    local conv_file="$TEST_TMP/test_conv.json"
    cat > "$conv_file" <<'EOF'
[
    {"role": "user", "content": "first message"},
    {"role": "assistant", "content": "first reply"}
]
EOF

    local result
    result=$(build_conversation_messages "sys prompt" "$conv_file" "second message")
    assert_valid_json "$result" "build_conversation_messages returns valid JSON"

    local count
    count=$(echo "$result" | jq 'length')
    assert_eq "$count" "4" "conversation messages: system + 2 history + 1 new user = 4"

    local last_role
    last_role=$(echo "$result" | jq -r '.[-1].role')
    assert_eq "$last_role" "user" "last message is the new user message"

    local last_content
    last_content=$(echo "$result" | jq -r '.[-1].content')
    assert_eq "$last_content" "second message" "last message has correct content"

    rm -f "$conv_file"
}

test_build_conversation_messages_empty_history() {
    local conv_file="$TEST_TMP/test_conv_empty.json"
    echo '[]' > "$conv_file"

    local result
    result=$(build_conversation_messages "sys prompt" "$conv_file" "hello")

    local count
    count=$(echo "$result" | jq 'length')
    assert_eq "$count" "2" "empty history: system + user = 2 messages"

    rm -f "$conv_file"
}

# --- api_chat tests with mocks ---

test_api_chat_success_returns_message_json() {
    # Mock curl to return a valid API response with text content
    curl() {
        local output_file=""
        local args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "-o" ]]; then
                output_file="${args[$((i+1))]}"
            fi
        done

        if [[ -n "$output_file" ]]; then
            cat > "$output_file" <<'MOCK_EOF'
{"choices": [{"message": {"role": "assistant", "content": "This is a test response."}}], "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}
MOCK_EOF
        fi
        echo "200"
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="mock-key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages=$(build_single_messages "test" "test")

    local result
    result=$(api_chat "$messages" "[]" 2>/dev/null)
    assert_valid_json "$result" "api_chat returns valid JSON message"
    local content
    content=$(echo "$result" | jq -r '.content')
    assert_eq "$content" "This is a test response." "api_chat returns correct content"

    unset -f curl
}

test_api_chat_success_with_tool_calls() {
    # Mock curl to return a response with tool_calls
    curl() {
        local output_file=""
        local args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "-o" ]]; then
                output_file="${args[$((i+1))]}"
            fi
        done

        if [[ -n "$output_file" ]]; then
            cat > "$output_file" <<'MOCK_EOF'
{"choices": [{"message": {"role": "assistant", "content": null, "tool_calls": [{"id": "call_123", "type": "function", "function": {"name": "run_command", "arguments": "{\"command\":\"echo hello\"}"}}]}}]}
MOCK_EOF
        fi
        echo "200"
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="mock-key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages=$(build_single_messages "test" "test")

    local result
    result=$(api_chat "$messages" "[]" 2>/dev/null)
    assert_valid_json "$result" "api_chat returns valid JSON for tool call response"

    local tool_name
    tool_name=$(echo "$result" | jq -r '.tool_calls[0].function.name')
    assert_eq "$tool_name" "run_command" "api_chat returns tool call with correct name"

    unset -f curl
}

test_api_chat_includes_tools_in_request() {
    # Mock curl to capture the request body and verify it includes tools
    curl() {
        local output_file=""
        local request_data=""
        local args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "-o" ]]; then
                output_file="${args[$((i+1))]}"
            fi
            if [[ "${args[$i]}" == "-d" ]]; then
                request_data="${args[$((i+1))]}"
            fi
        done

        # Verify the request includes tools
        local has_tools
        has_tools=$(echo "$request_data" | jq 'has("tools")' 2>/dev/null)

        if [[ -n "$output_file" ]]; then
            # Return the has_tools check as part of the response content
            cat > "$output_file" <<MOCK_EOF
{"choices": [{"message": {"role": "assistant", "content": "has_tools=${has_tools}"}}]}
MOCK_EOF
        fi
        echo "200"
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="mock-key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages=$(build_single_messages "test" "test")
    local tools='[{"type":"function","function":{"name":"test","description":"test","parameters":{"type":"object","properties":{}}}}]'

    local result
    result=$(api_chat "$messages" "$tools" 2>/dev/null)
    local content
    content=$(echo "$result" | jq -r '.content')
    assert_eq "$content" "has_tools=true" "api_chat includes tools in request body"

    unset -f curl
}

test_api_chat_auth_error() {
    curl() {
        local output_file=""
        local args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "-o" ]]; then
                output_file="${args[$((i+1))]}"
            fi
        done
        if [[ -n "$output_file" ]]; then
            echo '{"error": {"message": "Invalid API key"}}' > "$output_file"
        fi
        echo "401"
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="bad-key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages=$(build_single_messages "test" "test")

    local exit_code=0
    api_chat "$messages" "[]" >/dev/null 2>&1 || exit_code=$?
    assert_eq "$exit_code" "1" "api_chat returns 1 on 401 error"

    unset -f curl
}

test_api_chat_rate_limit() {
    curl() {
        local output_file=""
        local args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "-o" ]]; then
                output_file="${args[$((i+1))]}"
            fi
        done
        if [[ -n "$output_file" ]]; then
            echo '{"error": {"message": "Rate limited"}}' > "$output_file"
        fi
        echo "429"
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages=$(build_single_messages "test" "test")

    local exit_code=0
    local stderr
    stderr=$(api_chat "$messages" "[]" 2>&1 >/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "api_chat returns 1 on 429 rate limit"
    assert_contains "$stderr" "Rate limited" "api_chat shows rate limit message"

    unset -f curl
}

test_api_chat_server_error() {
    curl() {
        local output_file=""
        local args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "-o" ]]; then
                output_file="${args[$((i+1))]}"
            fi
        done
        if [[ -n "$output_file" ]]; then
            echo '{"error": "internal"}' > "$output_file"
        fi
        echo "500"
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages=$(build_single_messages "test" "test")

    local exit_code=0
    local stderr
    stderr=$(api_chat "$messages" "[]" 2>&1 >/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "api_chat returns 1 on 500 server error"
    assert_contains "$stderr" "Server error" "api_chat shows server error message"

    unset -f curl
}

test_api_chat_malformed_response() {
    curl() {
        local output_file=""
        local args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "-o" ]]; then
                output_file="${args[$((i+1))]}"
            fi
        done
        if [[ -n "$output_file" ]]; then
            echo '{"choices": []}' > "$output_file"
        fi
        echo "200"
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages=$(build_single_messages "test" "test")

    local exit_code=0
    api_chat "$messages" "[]" >/dev/null 2>&1 || exit_code=$?
    assert_eq "$exit_code" "1" "api_chat returns 1 on malformed response (empty choices)"

    unset -f curl
}

# --- api_chat_loop tests ---

test_api_chat_loop_text_only_response() {
    # Mock api_chat to return a text-only response (no tool calls)
    api_chat() {
        echo '{"role": "assistant", "content": "Just a text response."}'
    }

    local messages
    messages=$(build_single_messages "test" "test")

    local result
    result=$(api_chat_loop "$messages" "[]" 2>/dev/null)
    assert_eq "$result" "Just a text response." "api_chat_loop returns text content for non-tool response"

    unset -f api_chat
    # Re-source to restore real api_chat
    source "${PROJECT_DIR}/lib/api.sh"
}

test_api_chat_loop_tool_call_then_text() {
    # Mock api_chat to first return a tool call, then a text response
    # Use a file-based counter since api_chat_loop calls api_chat in the same shell
    local _counter_file="$TEST_TMP/api_call_count"
    echo "0" > "$_counter_file"

    api_chat() {
        local count
        count=$(cat "$_counter_file")
        count=$((count + 1))
        echo "$count" > "$_counter_file"

        if [[ $count -eq 1 ]]; then
            # First call: return a tool call for run_command
            echo '{"role": "assistant", "content": null, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "run_command", "arguments": "{\"command\":\"echo loop_test\"}"}}]}'
        else
            # Second call: return text response
            echo '{"role": "assistant", "content": "Done running the command."}'
        fi
    }

    DANGEROUS_PATTERNS=()
    SHELLIA_DRY_RUN=false

    local messages
    messages=$(build_single_messages "test" "test")

    local result
    result=$(api_chat_loop "$messages" "[]" 2>/dev/null)
    assert_eq "$result" "Done running the command." "api_chat_loop returns final text after tool execution"

    rm -f "$_counter_file"
    unset -f api_chat
    source "${PROJECT_DIR}/lib/api.sh"
}

test_api_chat_loop_max_iterations() {
    # Mock api_chat to always return tool calls (infinite loop scenario)
    api_chat() {
        echo '{"role": "assistant", "content": null, "tool_calls": [{"id": "call_inf", "type": "function", "function": {"name": "run_command", "arguments": "{\"command\":\"echo infinite\"}"}}]}'
    }

    DANGEROUS_PATTERNS=()
    SHELLIA_DRY_RUN=false
    SHELLIA_MAX_TOOL_LOOPS=3  # Low limit for testing

    local messages
    messages=$(build_single_messages "test" "test")

    local exit_code=0
    api_chat_loop "$messages" "[]" >/dev/null 2>&1 || exit_code=$?
    assert_eq "$exit_code" "1" "api_chat_loop exits with error when max iterations exceeded"

    SHELLIA_MAX_TOOL_LOOPS=20  # Restore default
    unset -f api_chat
    source "${PROJECT_DIR}/lib/api.sh"
}
