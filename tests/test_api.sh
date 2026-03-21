#!/usr/bin/env bash
# Tests for lib/api.sh

_write_test_png_fixture() {
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

    local user_content_type
    user_content_type=$(echo "$result" | jq -r '.[1].content | type')
    assert_eq "$user_content_type" "array" "user message content is stored as an array of parts"

    local user_part_count
    user_part_count=$(echo "$result" | jq '.[1].content | length')
    assert_eq "$user_part_count" "1" "user message contains one text part"

    local user_part_type
    user_part_type=$(echo "$result" | jq -r '.[1].content[0].type')
    assert_eq "$user_part_type" "text" "user message part type is text"

    local user_text
    user_text=$(echo "$result" | jq -r '.[1].content[0].text')
    assert_eq "$user_text" "User message here" "user message text part has correct content"
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

    local last_content_type
    last_content_type=$(echo "$result" | jq -r '.[-1].content | type')
    assert_eq "$last_content_type" "array" "last message content is stored as content parts"

    local last_content
    last_content=$(echo "$result" | jq -r '.[-1].content[0].text')
    assert_eq "$last_content" "second message" "last message text part has correct content"

    rm -f "$conv_file"
}

test_build_conversation_messages_normalizes_legacy_string_history() {
    local conv_file="$TEST_TMP/test_conv_legacy.json"
    cat > "$conv_file" <<'EOF'
[
    {"role": "user", "content": "first message"},
    {"role": "assistant", "content": "first reply"}
]
EOF

    local result
    result=$(build_conversation_messages "sys prompt" "$conv_file" "second message")

    local first_history_type
    first_history_type=$(echo "$result" | jq -r '.[1].content | type')
    assert_eq "$first_history_type" "array" "legacy user history is normalized to content-part arrays"

    local first_history_text
    first_history_text=$(echo "$result" | jq -r '.[1].content[0].text')
    assert_eq "$first_history_text" "first message" "legacy user history text is preserved"

    local second_history_text
    second_history_text=$(echo "$result" | jq -r '.[2].content[0].text')
    assert_eq "$second_history_text" "first reply" "legacy assistant history text is preserved"

    rm -f "$conv_file"
}

test_build_conversation_messages_preserves_structured_history() {
    local conv_file="$TEST_TMP/test_conv_structured.json"
    cat > "$conv_file" <<'EOF'
[
    {
        "role": "user",
        "content": [
            {"type": "text", "text": "look at this"},
            {"type": "input_image", "mime_type": "image/png", "storage_ref": "uploads/example.png"}
        ]
    }
]
EOF

    local result
    result=$(build_conversation_messages "sys prompt" "$conv_file" "second message")

    local preserved
    preserved=$(echo "$result" | jq -c '.[1].content')
    assert_eq "$preserved" '[{"type":"text","text":"look at this"},{"type":"input_image","mime_type":"image/png","storage_ref":"uploads/example.png"}]' "structured history content is preserved"

    rm -f "$conv_file"
}

test_build_single_messages_expands_image_references() {
    local image_path="$TEST_TMP/cat.png"
    _write_test_png_fixture "$image_path"

    local result
    result=$(build_single_messages "System prompt here" "Describe @$image_path please")

    local part_count
    part_count=$(echo "$result" | jq '.[1].content | length')
    assert_eq "$part_count" "3" "image reference prompt expands into ordered parts"

    local image_type
    image_type=$(echo "$result" | jq -r '.[1].content[1].type')
    assert_eq "$image_type" "input_image" "image reference becomes image content part"

    local image_path_value
    image_path_value=$(echo "$result" | jq -r '.[1].content[1].path')
    assert_eq "$image_path_value" "$image_path" "image part preserves source path"
}

test_build_single_messages_inlines_text_file_references() {
    local text_path="$TEST_TMP/notes.txt"
    printf 'line one\nline two\n' > "$text_path"

    local result
    result=$(build_single_messages "System prompt here" "Summarize @$text_path")

    local inlined_text
    inlined_text=$(echo "$result" | jq -r '.[1].content[1].text')
    assert_contains "$inlined_text" "File: $text_path" "text reference includes file label"
    assert_contains "$inlined_text" "line one" "text reference includes file contents"
    assert_contains "$inlined_text" "line two" "text reference includes entire file contents"
}

test_build_single_messages_preserves_order_for_mixed_references() {
    local image_path="$TEST_TMP/mockup.png"
    local text_path="$TEST_TMP/spec.txt"
    _write_test_png_fixture "$image_path"
    printf 'acceptance criteria' > "$text_path"

    local result
    result=$(build_single_messages "System prompt here" "Compare @$image_path with @$text_path now")

    local first_text
    first_text=$(echo "$result" | jq -r '.[1].content[0].text')
    local second_type
    second_type=$(echo "$result" | jq -r '.[1].content[1].type')
    local third_text
    third_text=$(echo "$result" | jq -r '.[1].content[2].text')
    local fourth_text
    fourth_text=$(echo "$result" | jq -r '.[1].content[3].text')
    local fifth_text
    fifth_text=$(echo "$result" | jq -r '.[1].content[4].text')

    assert_eq "$first_text" "Compare " "mixed reference keeps leading text"
    assert_eq "$second_type" "input_image" "mixed reference keeps image in order"
    assert_eq "$third_text" " with " "mixed reference keeps middle text"
    assert_contains "$fourth_text" "acceptance criteria" "mixed reference inlines text file in order"
    assert_eq "$fifth_text" " now" "mixed reference keeps trailing text"
}

test_build_single_messages_keeps_escaped_at_literal() {
    local result
    result=$(build_single_messages "System prompt here" 'Show \@literal and continue')

    local part_count
    part_count=$(echo "$result" | jq '.[1].content | length')
    assert_eq "$part_count" "1" "escaped at-sign does not create file reference"

    local text
    text=$(echo "$result" | jq -r '.[1].content[0].text')
    assert_eq "$text" 'Show @literal and continue' "escaped at-sign stays literal in prompt text"
}

test_build_single_messages_supports_quoted_paths_with_spaces() {
    local image_dir="$TEST_TMP/my images"
    local image_path="$image_dir/login screen.png"
    mkdir -p "$image_dir"
    _write_test_png_fixture "$image_path"

    local result
    result=$(build_single_messages "System prompt here" "Inspect @\"$image_path\"")

    local image_type
    image_type=$(echo "$result" | jq -r '.[1].content[1].type')
    local image_path_value
    image_path_value=$(echo "$result" | jq -r '.[1].content[1].path')
    assert_eq "$image_type" "input_image" "quoted path with spaces resolves as image reference"
    assert_eq "$image_path_value" "$image_path" "quoted path with spaces preserves full path"
}

test_build_single_messages_fails_for_missing_file_reference() {
    local missing_path="$TEST_TMP/missing.png"

    local exit_code=0
    local stderr
    stderr=$(build_single_messages "System prompt here" "Describe @$missing_path" 2>&1 >/dev/null) || exit_code=$?

    assert_eq "$exit_code" "1" "missing file reference returns error"
    assert_contains "$stderr" "Referenced file not found" "missing file reference shows clear error"
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

test_api_chat_normalizes_outgoing_messages_before_request() {
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

        if [[ -n "$output_file" ]]; then
            local request_user_type
            request_user_type=$(echo "$request_data" | jq -r '.messages[1].content | type')
            local request_user_text
            request_user_text=$(echo "$request_data" | jq -r '.messages[1].content[0].text')

            cat > "$output_file" <<MOCK_EOF
{"choices": [{"message": {"role": "assistant", "content": "${request_user_type}:${request_user_text}"}}]}
MOCK_EOF
        fi
        echo "200"
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="mock-key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages='[
        {"role":"system","content":"sys"},
        {"role":"user","content":"legacy text"}
    ]'

    local result
    result=$(api_chat "$messages" "[]" 2>/dev/null)

    local content
    content=$(echo "$result" | jq -r '.content')
    assert_eq "$content" "array:legacy text" "api_chat normalizes legacy string user content before sending request"

    unset -f curl
}

test_api_chat_serializes_image_parts_for_request() {
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

        if [[ -n "$output_file" ]]; then
            local image_type
            image_type=$(echo "$request_data" | jq -r '.messages[1].content[1].type')
            local image_url_prefix
            image_url_prefix=$(echo "$request_data" | jq -r '.messages[1].content[1].image_url.url' | python3 -c 'import sys; print(sys.stdin.read().strip()[:22])')
            cat > "$output_file" <<MOCK_EOF
{"choices": [{"message": {"role": "assistant", "content": "${image_type}:${image_url_prefix}"}}]}
MOCK_EOF
        fi
        echo "200"
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="mock-key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages='[
        {"role":"system","content":"sys"},
        {"role":"user","content":[{"type":"text","text":"Describe "},{"type":"input_image","mime_type":"image/png","data_url":"data:image/png;base64,abc","path":"/tmp/cat.png"}]}
    ]'

    local result
    result=$(api_chat "$messages" "[]" 2>/dev/null)

    local content
    content=$(echo "$result" | jq -r '.content')
    assert_eq "$content" "image_url:data:image/png;base64," "api_chat serializes image parts into provider image_url blocks"

    unset -f curl
}

test_api_chat_preserves_mixed_content_order_in_request() {
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

        if [[ -n "$output_file" ]]; then
            local order
            order=$(echo "$request_data" | jq -r '[.messages[1].content[].type] | join(",")')
            cat > "$output_file" <<MOCK_EOF
{"choices": [{"message": {"role": "assistant", "content": "${order}"}}]}
MOCK_EOF
        fi
        echo "200"
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="mock-key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages='[
        {"role":"system","content":"sys"},
        {"role":"user","content":[{"type":"text","text":"Compare "},{"type":"input_image","mime_type":"image/png","data_url":"data:image/png;base64,abc","path":"/tmp/cat.png"},{"type":"text","text":" with notes "},{"type":"text","text":"File: spec.txt\n---\nacceptance criteria"}]}
    ]'

    local result
    result=$(api_chat "$messages" "[]" 2>/dev/null)

    local content
    content=$(echo "$result" | jq -r '.content')
    assert_eq "$content" "text,image_url,text,text" "api_chat preserves mixed content ordering in request"

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

test_api_chat_multimodal_client_error_shows_clear_message() {
    curl() {
        local output_file=""
        local args=("$@")
        for ((i=0; i<${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "-o" ]]; then
                output_file="${args[$((i+1))]}"
            fi
        done
        if [[ -n "$output_file" ]]; then
            echo '{"error": {"message": "This model does not support image input"}}' > "$output_file"
        fi
        echo "400"
    }

    SHELLIA_API_URL="https://mock.api"
    SHELLIA_API_KEY="key"
    SHELLIA_MODEL="mock/model"

    local messages
    messages='[
        {"role":"system","content":"sys"},
        {"role":"user","content":[{"type":"text","text":"describe"},{"type":"input_image","mime_type":"image/png","storage_ref":"uploads/example.png"}]}
    ]'

    local exit_code=0
    local stderr
    stderr=$(api_chat "$messages" "[]" 2>&1 >/dev/null) || exit_code=$?

    assert_eq "$exit_code" "1" "api_chat returns 1 on multimodal client error"
    assert_contains "$stderr" "rejected multimodal input" "api_chat explains multimodal rejection clearly"

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

test_api_chat_loop_pauses_spinner_during_tool_execution() {
    local _counter_file="$TEST_TMP/api_spinner_count"
    echo "0" > "$_counter_file"

    api_chat() {
        local count
        count=$(cat "$_counter_file")
        count=$((count + 1))
        echo "$count" > "$_counter_file"

        if [[ $count -eq 1 ]]; then
            echo '{"role": "assistant", "content": null, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "run_command", "arguments": "{\"command\":\"echo loop_test\"}"}}]}'
        else
            echo '{"role": "assistant", "content": "Done"}'
        fi
    }

    dispatch_tool_call() {
        echo "tool ok"
    }

    local spinner_stops=0
    local spinner_starts=0
    spinner_stop() {
        spinner_stops=$((spinner_stops + 1))
        SPINNER_PID=""
    }
    spinner_start() {
        spinner_starts=$((spinner_starts + 1))
        SPINNER_PID="1234"
    }

    SPINNER_PID="1234"

    local messages
    messages=$(build_single_messages "test" "test")

    api_chat_loop "$messages" "[]" >/dev/null 2>&1

    assert_eq "$spinner_stops" "1" "api_chat_loop stops spinner before tool execution"
    assert_eq "$spinner_starts" "0" "api_chat_loop does not restart spinner after tool execution"

    rm -f "$_counter_file"
    unset -f api_chat dispatch_tool_call spinner_stop spinner_start
    source "${PROJECT_DIR}/lib/api.sh"
    source "${PROJECT_DIR}/lib/tools.sh"
    source "${PROJECT_DIR}/lib/utils.sh"
}

test_api_chat_loop_emits_web_tool_start_and_end_events() {
    local _counter_file="$TEST_TMP/api_web_event_count"
    echo "0" > "$_counter_file"

    api_chat() {
        local count
        count=$(cat "$_counter_file")
        count=$((count + 1))
        echo "$count" > "$_counter_file"

        if [[ $count -eq 1 ]]; then
            echo '{"role": "assistant", "content": null, "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "run_command", "arguments": "{\"command\":\"echo loop_test\"}"}}]}'
        else
            echo '{"role": "assistant", "content": "Done"}'
        fi
    }

    dispatch_tool_call() {
        echo "tool ok"
    }

    SHELLIA_WEB_MODE=true

    local messages
    messages=$(build_single_messages "test" "test")

    local stderr
    stderr=$(api_chat_loop "$messages" "[]" 2>&1 >/dev/null)

    assert_contains "$stderr" '"type":"tool_start"' "api_chat_loop emits tool_start web event"
    assert_contains "$stderr" '"type":"tool_end"' "api_chat_loop emits tool_end web event"

    rm -f "$_counter_file"
    SHELLIA_WEB_MODE=false
    unset -f api_chat dispatch_tool_call
    source "${PROJECT_DIR}/lib/api.sh"
    source "${PROJECT_DIR}/lib/tools.sh"
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
