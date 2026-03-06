#!/usr/bin/env bash
# API communication for bashia

# Send a chat completion request
# Args: $1 = JSON messages array (already formatted)
# Returns: raw content from the API response
api_chat() {
    local messages="$1"
    local response
    local http_code
    local body

    # Create temp file for response
    local tmp_response
    tmp_response=$(mktemp)
    trap "rm -f '$tmp_response'" RETURN

    # Make API call, capture HTTP status code
    http_code=$(curl -s -w "%{http_code}" -o "$tmp_response" \
        "${BASHIA_API_URL}/chat/completions" \
        -H "Authorization: Bearer ${BASHIA_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg model "$BASHIA_MODEL" \
            --argjson messages "$messages" \
            '{
                model: $model,
                messages: $messages,
                temperature: 0.2
            }'
        )" 2>/dev/null) || {
        log_error "Network error: could not connect to ${BASHIA_API_URL}"
        log_error "Check your internet connection and API URL."
        return 1
    }

    body=$(cat "$tmp_response")

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

    # Parse response content
    local content
    content=$(echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

    if [[ -z "$content" ]]; then
        log_error "Malformed API response (no content in choices)."
        log_error "Raw response: $body"
        return 1
    fi

    echo "$content"
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
