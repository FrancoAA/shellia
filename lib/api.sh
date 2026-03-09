#!/usr/bin/env bash
# API communication for shellia

# Maximum number of tool call loop iterations to prevent infinite loops
SHELLIA_MAX_TOOL_LOOPS=20
SHELLIA_TOOL_BLOCKED=false

# Send a chat completion request
# Args: $1 = JSON messages array, $2 = JSON tools array (optional)
# Returns: full assistant message JSON (with content and/or tool_calls)
api_chat() {
    local messages="$1"
    local tools="${2:-[]}"
    local response
    local http_code
    local body

    local msg_count
    msg_count=$(echo "$messages" | jq 'length')
    local char_count
    char_count=$(echo "$messages" | wc -c | tr -d ' ')
    debug_log "api" "model=${SHELLIA_MODEL} messages=${msg_count} chars=${char_count} temp=0.2"
    debug_log "api" "endpoint=${SHELLIA_API_URL}/chat/completions"

    # Create temp file for response
    local tmp_response
    tmp_response=$(mktemp)
    trap "rm -f '$tmp_response'" RETURN

    # Build request body — include tools only if non-empty
    local request_body
    local tools_count
    tools_count=$(echo "$tools" | jq 'length')

    if [[ "$tools_count" -gt 0 ]]; then
        request_body=$(jq -n \
            --arg model "$SHELLIA_MODEL" \
            --argjson messages "$messages" \
            --argjson tools "$tools" \
            '{
                model: $model,
                messages: $messages,
                tools: $tools,
                temperature: 0.2
            }')
        debug_log "api" "tools=${tools_count}"
    else
        request_body=$(jq -n \
            --arg model "$SHELLIA_MODEL" \
            --argjson messages "$messages" \
            '{
                model: $model,
                messages: $messages,
                temperature: 0.2
            }')
    fi

    fire_hook "before_api_call" "$messages"

    # Make API call, capture HTTP status code
    http_code=$(curl -s -w "%{http_code}" -o "$tmp_response" \
        "${SHELLIA_API_URL}/chat/completions" \
        -H "Authorization: Bearer ${SHELLIA_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$request_body" 2>/dev/null) || {
        log_error "Network error: could not connect to ${SHELLIA_API_URL}"
        log_error "Check your internet connection and API URL."
        return 1
    }

    body=$(cat "$tmp_response")

    debug_log "api" "http_status=${http_code}"

    # Check HTTP status
    case "$http_code" in
        200) ;;
        401)
            log_error "Authentication failed (HTTP 401). Check your API key."
            return 1
            ;;
        429)
            log_error "Rate limited (HTTP 429). Wait a moment and try again."
            return 1
            ;;
        4*)
            log_error "Client error (HTTP ${http_code})."
            log_error "Response: $(echo "$body" | jq -r '.error.message // .error // .' 2>/dev/null || echo "$body")"
            return 1
            ;;
        5*)
            log_error "Server error (HTTP ${http_code}). Try again later."
            return 1
            ;;
        *)
            log_error "Unexpected HTTP status: ${http_code}"
            return 1
            ;;
    esac

    # Extract the assistant message object
    local message
    message=$(echo "$body" | jq '.choices[0].message // empty' 2>/dev/null)

    if [[ -z "$message" ]]; then
        log_error "Malformed API response (no message in choices)."
        log_error "Raw response: $body"
        return 1
    fi

    # Debug: show token usage if available
    local usage
    usage=$(echo "$body" | jq -r '
        if .usage then
            "prompt=\(.usage.prompt_tokens // "?") completion=\(.usage.completion_tokens // "?") total=\(.usage.total_tokens // "?")"
        else "not reported"
        end' 2>/dev/null)
    debug_log "api" "tokens: ${usage}"

    local content
    content=$(echo "$message" | jq -r '.content // empty' 2>/dev/null)
    [[ -n "$content" ]] && debug_block "response" "$content" 5

    local tool_calls_count
    tool_calls_count=$(echo "$message" | jq '.tool_calls // [] | length' 2>/dev/null)
    debug_log "api" "tool_calls=${tool_calls_count}"

    fire_hook "after_api_call" "$message"

    echo "$message"
}

# Run the tool call loop: send request, execute tools, loop until text-only response
# Args: $1 = JSON messages array, $2 = JSON tools array
# Outputs: text content to stdout, tool UX to stderr
# Side effect: appends to messages array (caller can pass a temp file for conversation tracking)
api_chat_loop() {
    local messages="$1"
    local tools="$2"
    local loop_count=0
    local final_content=""

    while true; do
        ((loop_count++))
        if [[ $loop_count -gt $SHELLIA_MAX_TOOL_LOOPS ]]; then
            log_error "Tool call loop exceeded maximum iterations (${SHELLIA_MAX_TOOL_LOOPS}). Stopping."
            return 1
        fi

        debug_log "loop" "iteration=${loop_count}"

        # Call the API
        local assistant_message
        assistant_message=$(api_chat "$messages" "$tools") || return $?

        # Check for text content
        local content
        content=$(echo "$assistant_message" | jq -r '.content // empty' 2>/dev/null)

        # Check for tool calls
        local tool_calls
        tool_calls=$(echo "$assistant_message" | jq '.tool_calls // []' 2>/dev/null)
        local tool_calls_count
        tool_calls_count=$(echo "$tool_calls" | jq 'length')

        if [[ $tool_calls_count -eq 0 ]]; then
            # No tool calls — we're done. Output text content.
            if [[ -n "$content" ]]; then
                echo "$content"
            fi
            # Return the final messages array via a global so callers can track conversation
            SHELLIA_LAST_MESSAGES="$messages"
            SHELLIA_LAST_ASSISTANT_MESSAGE="$assistant_message"
            return 0
        fi

        # There are tool calls — display any text content first
        if [[ -n "$content" ]]; then
            echo "$content" >&2
        fi

        # Append the assistant message (with tool_calls) to messages
        messages=$(echo "$messages" | jq --argjson msg "$assistant_message" '. + [$msg]')

        # Execute each tool call and collect results
        for ((i = 0; i < tool_calls_count; i++)); do
            local tool_call
            tool_call=$(echo "$tool_calls" | jq ".[$i]")

            local tool_id tool_name tool_args
            tool_id=$(echo "$tool_call" | jq -r '.id')
            tool_name=$(echo "$tool_call" | jq -r '.function.name')
            tool_args=$(echo "$tool_call" | jq -r '.function.arguments')

            debug_log "loop" "executing tool: ${tool_name} (id=${tool_id})"

            local spinner_was_active=false
            if [[ -n "${SPINNER_PID:-}" ]]; then
                spinner_stop
                spinner_was_active=true
                echo -e "${THEME_MUTED}Running tool: ${tool_name}${NC}" >&2
            fi

            # Emit web event for tool calls
            if [[ "${SHELLIA_WEB_MODE:-false}" == "true" ]]; then
                local web_event
                web_event=$(jq -nc --arg name "$tool_name" --arg args "$tool_args" \
                    '{"type":"tool_call","name":$name,"command":($args | fromjson? // {} | .command // $name)}')
                echo "__SHELLIA_EVENT__:${web_event}" >&2

                local web_start_event
                web_start_event=$(jq -nc --arg name "$tool_name" '{"type":"tool_start","name":$name}')
                echo "__SHELLIA_EVENT__:${web_start_event}" >&2
            fi

            # Execute the tool (with plugin guard)
            local tool_result
            local tool_exit=0
            local tool_started_at=$SECONDS
            fire_hook "before_tool_call" "$tool_name" "$tool_args"
            if [[ "${SHELLIA_TOOL_BLOCKED:-false}" == "true" ]]; then
                SHELLIA_TOOL_BLOCKED=false
                tool_result="Command blocked by plugin policy."
                tool_exit=0
            else
                tool_result=$(dispatch_tool_call "$tool_name" "$tool_args") || tool_exit=$?
                fire_hook "after_tool_call" "$tool_name" "${tool_result:-}" "$tool_exit"
            fi

            local tool_duration_seconds=$((SECONDS - tool_started_at))

            if [[ "${SHELLIA_WEB_MODE:-false}" == "true" ]]; then
                local web_end_event
                web_end_event=$(jq -nc \
                    --arg name "$tool_name" \
                    --argjson exit_code "$tool_exit" \
                    --argjson duration_seconds "$tool_duration_seconds" \
                    '{"type":"tool_end","name":$name,"exit_code":$exit_code,"duration_seconds":$duration_seconds}')
                echo "__SHELLIA_EVENT__:${web_end_event}" >&2
            fi

            if [[ "$spinner_was_active" == "true" ]]; then
                spinner_start "Thinking..."
            fi

            # Append the tool result message
            messages=$(echo "$messages" | jq \
                --arg id "$tool_id" \
                --arg result "$tool_result" \
                '. + [{"role": "tool", "tool_call_id": $id, "content": $result}]')
        done

        # Loop back to call the API again with the tool results
    done
}

# Build a messages JSON array for a single prompt (no history)
build_single_messages() {
    local system_prompt="$1"
    local user_prompt="$2"

    jq -n \
        --arg sys "$system_prompt" \
        --arg usr "$user_prompt" \
        '[
            {"role": "system", "content": $sys},
            {"role": "user", "content": $usr}
        ]'
}

# Build messages JSON array with conversation history
# Args: $1 = system prompt, $2 = conversation file path, $3 = new user message
build_conversation_messages() {
    local system_prompt="$1"
    local conv_file="$2"
    local user_message="$3"

    local history
    history=$(cat "$conv_file")

    jq -n \
        --arg sys "$system_prompt" \
        --argjson history "$history" \
        --arg usr "$user_message" \
        '[{"role": "system", "content": $sys}] + $history + [{"role": "user", "content": $usr}]'
}
