#!/usr/bin/env bash
# Tool: ask_user — ask the user a question and get their response

tool_ask_user_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "ask_user",
        "description": "Ask the user a question when you need clarification, a decision, or additional information before proceeding. The user's response is returned to you.",
        "parameters": {
            "type": "object",
            "properties": {
                "question": {
                    "type": "string",
                    "description": "The question to ask the user"
                }
            },
            "required": ["question"]
        }
    }
}
EOF
}

tool_ask_user_execute() {
    local args_json="$1"
    local question
    question=$(echo "$args_json" | jq -r '.question')

    echo -e "${THEME_ACCENT}${question}${NC}" >&2
    local answer
    read -rp "$(echo -e "${THEME_PROMPT}> ${NC}")" answer </dev/tty
    echo "$answer"
}
