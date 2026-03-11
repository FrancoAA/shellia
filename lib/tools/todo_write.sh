#!/usr/bin/env bash
# Tool: todo_write — persist current task list as markdown

tool_todo_write_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "todo_write",
        "description": "Persist the session task list as a markdown file. Use this to create or update a structured TODO checklist while you work.",
        "parameters": {
            "type": "object",
            "properties": {
                "todos": {
                    "type": "array",
                    "description": "Complete replacement list of todos for the current session.",
                    "items": {
                        "type": "object",
                        "properties": {
                            "content": {
                                "type": "string",
                                "description": "Brief task description"
                            },
                            "status": {
                                "type": "string",
                                "description": "Task state",
                                "enum": ["pending", "in_progress", "completed", "cancelled"]
                            },
                            "priority": {
                                "type": "string",
                                "description": "Task priority",
                                "enum": ["high", "medium", "low"]
                            }
                        },
                        "required": ["content", "status", "priority"]
                    }
                }
            },
            "required": ["todos"]
        }
    }
}
EOF
}

_todo_status_token() {
    case "$1" in
        pending) echo " " ;;
        in_progress) echo "~" ;;
        completed) echo "x" ;;
        cancelled) echo "-" ;;
        *) echo "?" ;;
    esac
}

tool_todo_write_execute() {
    local args_json="$1"
    local todos_json

    if ! todos_json=$(echo "$args_json" | jq -c '.todos'); then
        echo "Error: invalid JSON input for todo_write"
        return 1
    fi

    if [[ "$(echo "$todos_json" | jq -r 'type')" != "array" ]]; then
        echo "Error: todo_write requires 'todos' to be an array"
        return 1
    fi

    local count
    count=$(echo "$todos_json" | jq 'length')

    local in_progress_count=0
    local i
    for ((i = 0; i < count; i++)); do
        local content status priority
        content=$(echo "$todos_json" | jq -r ".[$i].content // empty")
        status=$(echo "$todos_json" | jq -r ".[$i].status // empty")
        priority=$(echo "$todos_json" | jq -r ".[$i].priority // empty")

        if [[ -z "$content" ]]; then
            echo "Error: todo item $((i + 1)) has empty content"
            return 1
        fi

        if [[ "$content" == *$'\n'* ]]; then
            echo "Error: todo item $((i + 1)) content must be a single line"
            return 1
        fi

        case "$status" in
            pending|in_progress|completed|cancelled) ;;
            *)
                echo "Error: todo item $((i + 1)) has invalid status '$status'"
                return 1
                ;;
        esac

        case "$priority" in
            high|medium|low) ;;
            *)
                echo "Error: todo item $((i + 1)) has invalid priority '$priority'"
                return 1
                ;;
        esac

        if [[ "$status" == "in_progress" ]]; then
            in_progress_count=$((in_progress_count + 1))
        fi
    done

    if [[ $in_progress_count -gt 1 ]]; then
        echo "Error: todo list can have at most one in_progress item"
        return 1
    fi

    local todos_file="${SHELLIA_TODOS_FILE:-${SHELLIA_CONFIG_DIR}/todos.md}"
    local todos_dir
    todos_dir=$(dirname "$todos_file")
    mkdir -p "$todos_dir"

    local tmp_file="${todos_file}.tmp.$$"

    {
        printf '# Todos\n\n'
        for ((i = 0; i < count; i++)); do
            local content status priority token
            content=$(echo "$todos_json" | jq -r ".[$i].content")
            status=$(echo "$todos_json" | jq -r ".[$i].status")
            priority=$(echo "$todos_json" | jq -r ".[$i].priority")
            token=$(_todo_status_token "$status")
            printf -- '- [%s] [%s] %s\n' "$token" "$priority" "$content"
        done
    } > "$tmp_file"

    mv "$tmp_file" "$todos_file"
    debug_log "tool" "todo_write: saved ${count} todos to ${todos_file}"

    local pending_count in_progress_total completed_count cancelled_count
    pending_count=$(echo "$todos_json" | jq '[.[] | select(.status == "pending")] | length')
    in_progress_total=$(echo "$todos_json" | jq '[.[] | select(.status == "in_progress")] | length')
    completed_count=$(echo "$todos_json" | jq '[.[] | select(.status == "completed")] | length')
    cancelled_count=$(echo "$todos_json" | jq '[.[] | select(.status == "cancelled")] | length')

    echo "Saved ${count} todos to ${todos_file} (pending: ${pending_count}, in_progress: ${in_progress_total}, completed: ${completed_count}, cancelled: ${cancelled_count})"
}

repl_cmd_todos_handler() {
    local todos_file="${SHELLIA_TODOS_FILE:-${SHELLIA_CONFIG_DIR}/todos.md}"
    if [[ ! -f "$todos_file" ]]; then
        echo "No todos found."
        return 0
    fi

    format_markdown < "$todos_file"
}

repl_cmd_todos_help() {
    echo -e "  ${THEME_ACCENT}todos${NC}            Show persisted todo list"
}
