#!/usr/bin/env bash
# API communication for shellia

# Maximum number of tool call loop iterations to prevent infinite loops
SHELLIA_MAX_TOOL_LOOPS=100
SHELLIA_TOOL_BLOCKED=false
SHELLIA_LAST_USAGE_JSON='{}'
SHELLIA_LAST_TURN_USAGE_JSON='{}'

usage_summary_line() {
    local usage_json="${1:-$SHELLIA_LAST_TURN_USAGE_JSON}"
    [[ -z "$usage_json" ]] && usage_json='{}'

    if [[ -z "$usage_json" ]]; then
        echo "Usage: not reported"
        return
    fi

    local summary
    summary=$(echo "$usage_json" | jq -r '
        if (.reported // false) then
            "Usage: prompt=\(.prompt_tokens // "?") completion=\(.completion_tokens // "?") total=\(.total_tokens // "?") calls=\(.calls // 0)"
        else
            "Usage: not reported"
        end
    ' 2>/dev/null)

    if [[ -z "$summary" || "$summary" == "null" ]]; then
        echo "Usage: not reported"
        return
    fi

    echo "$summary"
}

# Send a chat completion request
# Args: $1 = JSON messages array, $2 = JSON tools array (optional)
# Returns: full assistant message JSON (with content and/or tool_calls)
api_chat() {
    local messages="$1"
    local tools="${2:-[]}"
    local response
    local http_code
    local body

    SHELLIA_LAST_USAGE_JSON='{}'

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
    SHELLIA_LAST_USAGE_JSON=$(echo "$body" | jq -c '.usage // {}' 2>/dev/null)
    if [[ -z "${SHELLIA_LAST_USAGE_JSON:-}" || "${SHELLIA_LAST_USAGE_JSON}" == "null" ]]; then
        SHELLIA_LAST_USAGE_JSON='{}'
    fi
    if [[ -n "${SHELLIA_USAGE_CALL_FILE:-}" ]]; then
        printf '%s' "$SHELLIA_LAST_USAGE_JSON" > "$SHELLIA_USAGE_CALL_FILE"
    fi
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
    local usage_calls='[]'
    local usage_prompt_tokens=0
    local usage_completion_tokens=0
    local usage_total_tokens=0
    local usage_reported=false
    local call_usage_file

    call_usage_file=$(mktemp)
    export SHELLIA_USAGE_CALL_FILE="$call_usage_file"

    SHELLIA_LAST_TURN_USAGE_JSON='{}'

    while true; do
        ((loop_count++))
        if [[ $loop_count -gt $SHELLIA_MAX_TOOL_LOOPS ]]; then
            log_error "Tool call loop exceeded maximum iterations (${SHELLIA_MAX_TOOL_LOOPS}). Stopping."
            unset SHELLIA_USAGE_CALL_FILE
            rm -f "$call_usage_file"
            return 1
        fi

        debug_log "loop" "iteration=${loop_count}"

        # Call the API
        local assistant_message
        printf '{}' > "$call_usage_file"
        local api_exit=0
        assistant_message=$(api_chat "$messages" "$tools") || api_exit=$?
        if [[ $api_exit -ne 0 ]]; then
            unset SHELLIA_USAGE_CALL_FILE
            rm -f "$call_usage_file"
            return $api_exit
        fi

        local call_usage_json
        call_usage_json=$(cat "$call_usage_file" 2>/dev/null)
        [[ -z "$call_usage_json" ]] && call_usage_json='{}'
        if [[ -n "$call_usage_json" ]] && echo "$call_usage_json" | jq -e 'type == "object" and length > 0' >/dev/null 2>&1; then
            usage_reported=true
            usage_calls=$(echo "$usage_calls" | jq -c --argjson usage "$call_usage_json" '. + [$usage]' 2>/dev/null)

            local call_prompt_tokens
            local call_completion_tokens
            local call_total_tokens
            call_prompt_tokens=$(echo "$call_usage_json" | jq -r 'if (.prompt_tokens | type) == "number" then .prompt_tokens else 0 end' 2>/dev/null)
            call_completion_tokens=$(echo "$call_usage_json" | jq -r 'if (.completion_tokens | type) == "number" then .completion_tokens else 0 end' 2>/dev/null)
            call_total_tokens=$(echo "$call_usage_json" | jq -r 'if (.total_tokens | type) == "number" then .total_tokens else 0 end' 2>/dev/null)

            usage_prompt_tokens=$((usage_prompt_tokens + call_prompt_tokens))
            usage_completion_tokens=$((usage_completion_tokens + call_completion_tokens))
            usage_total_tokens=$((usage_total_tokens + call_total_tokens))
        fi

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
            SHELLIA_LAST_TURN_USAGE_JSON=$(jq -nc \
                --argjson reported "$usage_reported" \
                --argjson calls "${loop_count}" \
                --argjson prompt_tokens "$usage_prompt_tokens" \
                --argjson completion_tokens "$usage_completion_tokens" \
                --argjson total_tokens "$usage_total_tokens" \
                --argjson per_call "$usage_calls" \
                '{
                    reported: $reported,
                    calls: $calls,
                    prompt_tokens: $prompt_tokens,
                    completion_tokens: $completion_tokens,
                    total_tokens: $total_tokens,
                    per_call: $per_call
                }')
            if [[ -n "${SHELLIA_USAGE_FILE:-}" ]]; then
                printf '%s' "$SHELLIA_LAST_TURN_USAGE_JSON" > "$SHELLIA_USAGE_FILE"
            fi
            # Return the final messages array via a global so callers can track conversation
            SHELLIA_LAST_MESSAGES="$messages"
            SHELLIA_LAST_ASSISTANT_MESSAGE="$assistant_message"
            if [[ "${SHELLIA_WEB_MODE:-false}" == "true" ]]; then
                local usage_summary
                local usage_event
                usage_summary=$(usage_summary_line "$SHELLIA_LAST_TURN_USAGE_JSON")
                usage_event=$(jq -nc --arg summary "$usage_summary" '{"type":"usage","summary":$summary}')
                echo "__SHELLIA_EVENT__:${usage_event}" >&2
            fi
            unset SHELLIA_USAGE_CALL_FILE
            rm -f "$call_usage_file"
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
                debug_log "tool" "Running tool: ${tool_name}"
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
