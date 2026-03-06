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

test_api_chat_success_with_mock() {
    # Mock curl to return a valid API response
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
{"choices": [{"message": {"content": "[COMMAND]\nls -la"}}], "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}
MOCK_EOF
        fi
        echo "200"  # HTTP status code (captured by -w)
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="mock-key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages=$(build_single_messages "test" "test")

    local result
    result=$(api_chat "$messages" 2>/dev/null)
    assert_contains "$result" "[COMMAND]" "api_chat returns content with [COMMAND] tag"
    assert_contains "$result" "ls -la" "api_chat returns the command"

    unset -f curl
}

test_api_chat_auth_error_with_mock() {
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
    api_chat "$messages" >/dev/null 2>&1 || exit_code=$?
    assert_eq "$exit_code" "1" "api_chat returns 1 on 401 error"

    unset -f curl
}

test_api_chat_rate_limit_with_mock() {
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
    stderr=$(api_chat "$messages" 2>&1 >/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "api_chat returns 1 on 429 rate limit"
    assert_contains "$stderr" "Rate limited" "api_chat shows rate limit message"

    unset -f curl
}

test_api_chat_server_error_with_mock() {
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
    stderr=$(api_chat "$messages" 2>&1 >/dev/null) || exit_code=$?
    assert_eq "$exit_code" "1" "api_chat returns 1 on 500 server error"
    assert_contains "$stderr" "Server error" "api_chat shows server error message"

    unset -f curl
}

test_api_chat_malformed_response_with_mock() {
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
    api_chat "$messages" >/dev/null 2>&1 || exit_code=$?
    assert_eq "$exit_code" "1" "api_chat returns 1 on malformed response (empty choices)"

    unset -f curl
}
