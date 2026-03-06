# Bashia Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a bash-based terminal AI agent that translates natural language into shell commands and automates multi-step tasks using OpenAI-compatible APIs.

**Architecture:** A single `bashia` entrypoint script sources modular library files from `lib/`. Config is loaded from `~/.bashia/` with env var overrides. API calls use `curl`, responses parsed with `jq`. The LLM returns structured responses with `[COMMAND]`, `[PLAN]`, or `[EXPLANATION]` tags.

**Tech Stack:** Bash, jq, curl, OpenAI-compatible chat completions API

---

### Task 1: Project scaffolding and utils

**Files:**
- Create: `bashia` (main entrypoint)
- Create: `lib/utils.sh` (colors, logging, error handling)
- Create: `defaults/dangerous_commands` (default dangerous command patterns)
- Create: `defaults/system_prompt.txt` (base system prompt)

**Step 1: Create the directory structure**

```bash
mkdir -p lib defaults
```

**Step 2: Create `lib/utils.sh`**

```bash
#!/usr/bin/env bash
# Shared utilities for bashia

BASHIA_VERSION="0.1.0"

# Colors (only if terminal supports them)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m' # No Color
else
    RED='' YELLOW='' GREEN='' BLUE='' BOLD='' DIM='' NC=''
fi

log_info() {
    echo -e "${BLUE}${1}${NC}" >&2
}

log_success() {
    echo -e "${GREEN}${1}${NC}" >&2
}

log_warn() {
    echo -e "${YELLOW}${1}${NC}" >&2
}

log_error() {
    echo -e "${RED}${1}${NC}" >&2
}

die() {
    log_error "Error: $1"
    exit 1
}

# Check if a required command exists
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}
```

**Step 3: Create `defaults/dangerous_commands`**

```
rm
sudo
mkfs
dd
fdisk
chmod 777
chown
kill -9
reboot
shutdown
mv /
```

**Step 4: Create `defaults/system_prompt.txt`**

This is the base system prompt that instructs the LLM how to respond. It must be carefully crafted so bashia can parse the output.

```
You are bashia, a terminal command assistant. You translate natural language into shell commands.

RESPONSE FORMAT - You MUST prefix every response with exactly one of these tags on its own line:

[COMMAND]
Use when the user's request can be fulfilled with a single shell command.
After the tag, output ONLY the command. No explanation, no markdown, no code fences.

[PLAN]
Use when the request requires multiple sequential commands.
After the tag, output a JSON array of objects with "description" and "command" keys.
Example:
[PLAN]
[{"description": "Create directory", "command": "mkdir -p src"}, {"description": "Initialize git", "command": "git init"}]

[EXPLANATION]
Use when the user asks a question, requests analysis, or when piped input is provided for analysis.
After the tag, output a clear, concise explanation in plain text.

RULES:
- Use the user's current shell syntax (bash or zsh as specified)
- Prefer portable commands that work on both macOS and Linux
- For destructive operations, prefer safer alternatives (e.g., use trash-cli over rm when available)
- Be precise: use exact flags and options, not approximate ones
- If the request is ambiguous, output [EXPLANATION] and ask for clarification
- NEVER wrap commands in markdown code fences or backticks
- NEVER add explanatory text after a [COMMAND] response
```

**Step 5: Create the `bashia` entrypoint (skeleton)**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Resolve script directory for sourcing lib files
BASHIA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library files
source "${BASHIA_DIR}/lib/utils.sh"

# Check dependencies
require_cmd jq
require_cmd curl

# Version
if [[ "${1:-}" == "--version" ]]; then
    echo "bashia v${BASHIA_VERSION}"
    exit 0
fi

# Help
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: bashia [OPTIONS] [PROMPT]"
    echo ""
    echo "A terminal AI agent that translates natural language to shell commands."
    echo ""
    echo "Options:"
    echo "  init          Run setup wizard"
    echo "  --dry-run     Show command without executing"
    echo "  --help, -h    Show this help message"
    echo "  --version     Print version"
    echo ""
    echo "Modes:"
    echo "  bashia \"prompt\"       Single command mode"
    echo "  bashia                 REPL mode (interactive)"
    echo "  cmd | bashia \"prompt\" Pipe mode (analyze input)"
    exit 0
fi

echo "bashia v${BASHIA_VERSION} - not yet fully implemented"
```

**Step 6: Make bashia executable and verify**

```bash
chmod +x bashia
./bashia --version   # Expected: bashia v0.1.0
./bashia --help      # Expected: usage text
```

**Step 7: Commit**

```bash
git add bashia lib/ defaults/
git commit -m "feat: project scaffolding with utils, defaults, and entrypoint skeleton"
```

---

### Task 2: Configuration loading and `bashia init`

**Files:**
- Create: `lib/config.sh` (config loading, env var merging)
- Modify: `bashia` (add init dispatch and config loading)

**Step 1: Create `lib/config.sh`**

```bash
#!/usr/bin/env bash
# Configuration loading for bashia

BASHIA_CONFIG_DIR="${HOME}/.bashia"
BASHIA_CONFIG_FILE="${BASHIA_CONFIG_DIR}/config"
BASHIA_DANGEROUS_FILE="${BASHIA_CONFIG_DIR}/dangerous_commands"
BASHIA_USER_PROMPT_FILE="${BASHIA_CONFIG_DIR}/system_prompt"

# Load config from file, then override with env vars
load_config() {
    # Defaults
    BASHIA_API_URL="${BASHIA_API_URL:-}"
    BASHIA_API_KEY="${BASHIA_API_KEY:-}"
    BASHIA_MODEL="${BASHIA_MODEL:-}"

    # Load config file if it exists (env vars already set take precedence)
    if [[ -f "$BASHIA_CONFIG_FILE" ]]; then
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            # Trim whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # Only set if not already set via env var
            if [[ -z "${!key:-}" ]]; then
                export "$key=$value"
            fi
        done < "$BASHIA_CONFIG_FILE"
    fi

    # Re-read (env vars win over config file)
    BASHIA_API_URL="${BASHIA_API_URL:-}"
    BASHIA_API_KEY="${BASHIA_API_KEY:-}"
    BASHIA_MODEL="${BASHIA_MODEL:-}"
}

# Validate that required config is present
validate_config() {
    if [[ -z "$BASHIA_API_URL" ]]; then
        die "BASHIA_API_URL is not set. Run 'bashia init' or set the environment variable."
    fi
    if [[ -z "$BASHIA_API_KEY" ]]; then
        die "BASHIA_API_KEY is not set. Run 'bashia init' or set the environment variable."
    fi
    if [[ -z "$BASHIA_MODEL" ]]; then
        die "BASHIA_MODEL is not set. Run 'bashia init' or set the environment variable."
    fi
}

# Interactive setup wizard
bashia_init() {
    echo -e "${BOLD}bashia init${NC}"
    echo ""

    if [[ -d "$BASHIA_CONFIG_DIR" ]]; then
        echo "Existing configuration found at ${BASHIA_CONFIG_DIR}"
        read -rp "Reconfigure? [y/N]: " reconfigure
        if [[ ! "$reconfigure" =~ ^[Yy]$ ]]; then
            echo "Keeping existing configuration."
            return 0
        fi
    fi

    mkdir -p "$BASHIA_CONFIG_DIR"

    # API URL
    read -rp "API provider URL [https://openrouter.ai/api/v1]: " api_url
    api_url="${api_url:-https://openrouter.ai/api/v1}"

    # API Key
    read -rsp "API key: " api_key
    echo ""
    if [[ -z "$api_key" ]]; then
        die "API key cannot be empty."
    fi

    # Model
    read -rp "Model ID (e.g. anthropic/claude-sonnet-4, openai/gpt-4o): " model
    if [[ -z "$model" ]]; then
        die "Model ID cannot be empty."
    fi

    # Write config file
    cat > "$BASHIA_CONFIG_FILE" <<EOF
# bashia configuration
BASHIA_API_URL=${api_url}
BASHIA_API_KEY=${api_key}
BASHIA_MODEL=${model}
EOF
    chmod 600 "$BASHIA_CONFIG_FILE"

    # Copy dangerous commands if not present
    if [[ ! -f "$BASHIA_DANGEROUS_FILE" ]]; then
        cp "${BASHIA_DIR}/defaults/dangerous_commands" "$BASHIA_DANGEROUS_FILE"
    fi

    # Create empty user system prompt if not present
    if [[ ! -f "$BASHIA_USER_PROMPT_FILE" ]]; then
        cat > "$BASHIA_USER_PROMPT_FILE" <<'EOF'
# Custom instructions for bashia (appended to base prompt)
# Uncomment and edit lines below, or add your own.
# Examples:
#   Prefer eza over ls
#   Use doas instead of sudo
#   Always use long flags for readability
EOF
    fi

    log_success "Configuration saved to ${BASHIA_CONFIG_FILE}"
    echo ""
    echo "You can now use bashia:"
    echo "  bashia \"list all running docker containers\""
    echo "  bashia   (enter REPL mode)"
}
```

**Step 2: Update `bashia` entrypoint to source config.sh and dispatch init**

Add `source "${BASHIA_DIR}/lib/config.sh"` after sourcing utils.sh. Add init command handling before help/version. After argument parsing, call `load_config` and `validate_config` for non-init commands.

**Step 3: Verify init works**

```bash
./bashia init
# Follow prompts, check ~/.bashia/ directory is created
ls -la ~/.bashia/
cat ~/.bashia/config
cat ~/.bashia/dangerous_commands
```

**Step 4: Verify env var override works**

```bash
BASHIA_MODEL=test/override ./bashia --version
# Should work without error (version doesn't need config)
```

**Step 5: Commit**

```bash
git add lib/config.sh bashia
git commit -m "feat: add configuration loading and bashia init wizard"
```

---

### Task 3: System prompt assembly

**Files:**
- Create: `lib/prompt.sh` (system prompt builder)

**Step 1: Create `lib/prompt.sh`**

```bash
#!/usr/bin/env bash
# System prompt assembly for bashia

# Build the full system prompt from base + user additions
build_system_prompt() {
    local shell_name
    shell_name=$(detect_shell)

    local base_prompt
    base_prompt=$(cat "${BASHIA_DIR}/defaults/system_prompt.txt")

    # Append shell context
    base_prompt="${base_prompt}

CONTEXT:
- User's shell: ${shell_name}
- Operating system: $(uname -s)
- Current directory: $(pwd)"

    # Append user's custom prompt additions (skip comments and empty lines)
    if [[ -f "$BASHIA_USER_PROMPT_FILE" ]]; then
        local user_additions
        user_additions=$(grep -v '^[[:space:]]*#' "$BASHIA_USER_PROMPT_FILE" | grep -v '^[[:space:]]*$' || true)
        if [[ -n "$user_additions" ]]; then
            base_prompt="${base_prompt}

USER PREFERENCES:
${user_additions}"
        fi
    fi

    echo "$base_prompt"
}

# Detect current shell
detect_shell() {
    local shell_path="${SHELL:-/bin/bash}"
    basename "$shell_path"
}
```

**Step 2: Source prompt.sh from bashia entrypoint**

Add `source "${BASHIA_DIR}/lib/prompt.sh"` to the entrypoint.

**Step 3: Verify prompt assembly**

Add a temporary test to bashia or run manually:

```bash
# Temporarily add to bashia for testing:
# echo "$(build_system_prompt)"
./bashia  # Should print assembled prompt
```

Remove the temporary test line after verification.

**Step 4: Commit**

```bash
git add lib/prompt.sh bashia
git commit -m "feat: add system prompt assembly with shell detection and user additions"
```

---

### Task 4: API communication

**Files:**
- Create: `lib/api.sh` (API call logic, response parsing)

**Step 1: Create `lib/api.sh`**

```bash
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
```

**Step 2: Source api.sh from bashia entrypoint**

Add `source "${BASHIA_DIR}/lib/api.sh"` to the entrypoint.

**Step 3: Verify API call works (manual test)**

Requires a valid config (`bashia init` must have been run):

```bash
# Quick manual test (add temporarily to bashia):
# messages=$(build_single_messages "You are a helpful assistant. Reply with just 'hello'." "say hello")
# api_chat "$messages"
```

**Step 4: Commit**

```bash
git add lib/api.sh bashia
git commit -m "feat: add API communication with error handling and message builders"
```

---

### Task 5: Command execution and safety checks

**Files:**
- Create: `lib/executor.sh` (execution logic, dangerous command checking)

**Step 1: Create `lib/executor.sh`**

```bash
#!/usr/bin/env bash
# Command execution and safety checks for bashia

# Load dangerous commands patterns into an array
load_dangerous_commands() {
    DANGEROUS_PATTERNS=()
    local danger_file="${BASHIA_DANGEROUS_FILE:-${BASHIA_DIR}/defaults/dangerous_commands}"

    if [[ -f "$danger_file" ]]; then
        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
            DANGEROUS_PATTERNS+=("$pattern")
        done < "$danger_file"
    fi
}

# Check if a command matches any dangerous pattern
# Returns 0 if dangerous, 1 if safe
is_dangerous() {
    local cmd="$1"
    for pattern in "${DANGEROUS_PATTERNS[@]}"; do
        if [[ "$cmd" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

# Execute a single command with safety check
# Args: $1 = command string, $2 = dry_run (true/false, optional)
execute_command() {
    local cmd="$1"
    local dry_run="${2:-false}"

    echo -e "${DIM}\$ ${cmd}${NC}"

    if [[ "$dry_run" == "true" ]]; then
        return 0
    fi

    # Safety check
    if is_dangerous "$cmd"; then
        echo -e "${YELLOW}Warning: This command matches a dangerous pattern.${NC}"
        read -rp "Run this? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_warn "Skipped."
            return 0
        fi
    fi

    # Detect shell and execute
    local shell_cmd
    shell_cmd=$(detect_shell)

    local exit_code=0
    "$shell_cmd" -c "$cmd" || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error "Command exited with code ${exit_code}"
    fi

    return $exit_code
}

# Execute a multi-step plan
# Args: $1 = JSON plan array string, $2 = dry_run (true/false, optional)
execute_plan() {
    local plan_json="$1"
    local dry_run="${2:-false}"

    local step_count
    step_count=$(echo "$plan_json" | jq 'length')

    echo -e "${BOLD}Plan (${step_count} steps):${NC}"
    echo ""

    # Display all steps
    for ((i = 0; i < step_count; i++)); do
        local desc cmd
        desc=$(echo "$plan_json" | jq -r ".[$i].description")
        cmd=$(echo "$plan_json" | jq -r ".[$i].command")
        printf "  %d. %-35s -> %s\n" "$((i + 1))" "$desc" "$cmd"
    done

    echo ""

    if [[ "$dry_run" == "true" ]]; then
        log_info "(dry-run: not executing)"
        return 0
    fi

    read -rp "Run all? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_warn "Cancelled."
        return 0
    fi

    echo ""

    # Execute each step
    for ((i = 0; i < step_count; i++)); do
        local desc cmd
        desc=$(echo "$plan_json" | jq -r ".[$i].description")
        cmd=$(echo "$plan_json" | jq -r ".[$i].command")

        echo -e "${BOLD}Step $((i + 1))/${step_count}: ${desc}${NC}"

        local shell_cmd
        shell_cmd=$(detect_shell)

        local exit_code=0
        "$shell_cmd" -c "$cmd" || exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            echo -e "  ${RED}✗ Failed (exit code ${exit_code})${NC}"
            echo ""

            # Show remaining steps
            if [[ $((i + 1)) -lt $step_count ]]; then
                log_warn "Remaining steps not executed:"
                for ((j = i + 1; j < step_count; j++)); do
                    local rdesc rcmd
                    rdesc=$(echo "$plan_json" | jq -r ".[$j].description")
                    rcmd=$(echo "$plan_json" | jq -r ".[$j].command")
                    printf "  %d. %-35s -> %s\n" "$((j + 1))" "$rdesc" "$rcmd"
                done
            fi
            return $exit_code
        else
            echo -e "  ${GREEN}✓ Done${NC}"
        fi
    done

    echo ""
    log_success "All ${step_count} steps completed successfully."
}
```

**Step 2: Source executor.sh from bashia entrypoint**

Add `source "${BASHIA_DIR}/lib/executor.sh"` and call `load_dangerous_commands` during initialization.

**Step 3: Verify safety check (manual test)**

```bash
# Add temporarily to bashia:
# load_dangerous_commands
# is_dangerous "rm -rf /tmp/test" && echo "DANGEROUS" || echo "SAFE"
# is_dangerous "ls -la" && echo "DANGEROUS" || echo "SAFE"
```

**Step 4: Commit**

```bash
git add lib/executor.sh bashia
git commit -m "feat: add command execution with safety checks and plan runner"
```

---

### Task 6: Response parsing and single-prompt mode

**Files:**
- Modify: `bashia` (add response parsing, wire up single-prompt mode)

**Step 1: Add response parsing logic to bashia**

Add a function that parses the `[COMMAND]`, `[PLAN]`, or `[EXPLANATION]` tags and dispatches accordingly:

```bash
# Parse and handle API response
handle_response() {
    local content="$1"
    local dry_run="${2:-false}"

    # Extract the tag from the first line
    local first_line
    first_line=$(echo "$content" | head -n 1)
    local body
    body=$(echo "$content" | tail -n +2)

    case "$first_line" in
        "[COMMAND]")
            # Trim whitespace from command
            local cmd
            cmd=$(echo "$body" | sed '/^[[:space:]]*$/d' | head -n 1)
            execute_command "$cmd" "$dry_run"
            ;;
        "[PLAN]")
            execute_plan "$body" "$dry_run"
            ;;
        "[EXPLANATION]")
            echo "$body"
            ;;
        *)
            # No tag found — treat as explanation (graceful fallback)
            echo "$content"
            ;;
    esac
}
```

**Step 2: Wire up single-prompt mode in bashia**

After argument parsing and config loading:

```bash
# Detect pipe mode
PIPED_INPUT=""
if [[ ! -t 0 ]]; then
    PIPED_INPUT=$(cat)
fi

# Parse flags
DRY_RUN=false
PROMPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            PROMPT="$1"
            shift
            ;;
    esac
done

# Build user prompt (add piped content if present)
if [[ -n "$PIPED_INPUT" ]]; then
    if [[ -n "$PROMPT" ]]; then
        PROMPT="${PROMPT}

The following is the content piped as input for context:
${PIPED_INPUT}"
    else
        PROMPT="Analyze the following input:
${PIPED_INPUT}"
    fi
fi

# Dispatch to appropriate mode
if [[ -n "$PROMPT" ]]; then
    # Single prompt mode
    load_config
    validate_config
    load_dangerous_commands
    system_prompt=$(build_system_prompt)
    messages=$(build_single_messages "$system_prompt" "$PROMPT")
    response=$(api_chat "$messages") || exit 1
    handle_response "$response" "$DRY_RUN"
else
    # REPL mode (Task 7)
    load_config
    validate_config
    load_dangerous_commands
    echo "REPL mode not yet implemented."
    exit 1
fi
```

**Step 3: Test single prompt mode end-to-end**

Requires a valid config:

```bash
./bashia --dry-run "list all files in the current directory"
# Expected: shows the command but doesn't run it

./bashia "list all files in the current directory"
# Expected: shows and runs the command (e.g., ls -la)

echo "permission denied" | ./bashia "what does this error mean?"
# Expected: shows an explanation
```

**Step 4: Commit**

```bash
git add bashia
git commit -m "feat: wire up single-prompt mode with response parsing and pipe support"
```

---

### Task 7: REPL mode

**Files:**
- Create: `lib/repl.sh` (REPL loop, conversation management, built-in commands)
- Modify: `bashia` (dispatch to REPL)

**Step 1: Create `lib/repl.sh`**

```bash
#!/usr/bin/env bash
# REPL mode for bashia

# Start the REPL
repl_start() {
    local system_prompt
    system_prompt=$(build_system_prompt)

    # Create conversation temp file
    local conv_file
    conv_file="/tmp/bashia_conv_$(date +%s).json"
    echo '[]' > "$conv_file"

    # Cleanup on exit
    trap "rm -f '$conv_file'" EXIT INT TERM

    local dry_run_mode=false

    echo -e "${BOLD}bashia v${BASHIA_VERSION}${NC} | model: ${BASHIA_MODEL} | type 'help' for commands"
    echo ""

    # Command history tracking (commands executed this session)
    local -a executed_commands=()

    while true; do
        # Read user input
        local input
        if ! read -rep "bashia> " input; then
            # Ctrl+D
            echo ""
            log_info "Goodbye."
            break
        fi

        # Skip empty input
        [[ -z "$input" ]] && continue

        # Handle built-in commands
        case "$input" in
            help)
                repl_help
                continue
                ;;
            reset)
                echo '[]' > "$conv_file"
                log_info "Conversation cleared."
                continue
                ;;
            history)
                repl_show_history "${executed_commands[@]}"
                continue
                ;;
            exit|quit)
                log_info "Goodbye."
                break
                ;;
            model\ *)
                local new_model="${input#model }"
                BASHIA_MODEL="$new_model"
                log_info "Switched to model: ${BASHIA_MODEL}"
                continue
                ;;
            "dry-run on")
                dry_run_mode=true
                log_info "Dry-run mode enabled."
                continue
                ;;
            "dry-run off")
                dry_run_mode=false
                log_info "Dry-run mode disabled."
                continue
                ;;
        esac

        # Token estimate warning
        local conv_size
        conv_size=$(wc -c < "$conv_file")
        local token_estimate=$(( conv_size / 4 ))
        if [[ $token_estimate -gt 10000 ]]; then
            log_warn "Conversation is getting long (~${token_estimate} tokens). Consider 'reset' to start fresh."
        fi

        # Build messages with conversation history
        local messages
        messages=$(build_conversation_messages "$system_prompt" "$conv_file" "$input")

        # Call API
        local response
        if ! response=$(api_chat "$messages"); then
            continue
        fi

        # Append user message and assistant response to conversation
        local updated
        updated=$(jq \
            --arg usr "$input" \
            --arg asst "$response" \
            '. + [{"role": "user", "content": $usr}, {"role": "assistant", "content": $asst}]' \
            "$conv_file")
        echo "$updated" > "$conv_file"

        # Handle the response
        echo ""
        handle_response "$response" "$dry_run_mode"

        # Track executed commands
        local first_line
        first_line=$(echo "$response" | head -n 1)
        if [[ "$first_line" == "[COMMAND]" ]]; then
            local cmd
            cmd=$(echo "$response" | tail -n +2 | sed '/^[[:space:]]*$/d' | head -n 1)
            executed_commands+=("$cmd")
        fi

        echo ""
    done
}

repl_help() {
    echo "Built-in commands:"
    echo "  help            Show this help"
    echo "  reset           Clear conversation history"
    echo "  history         Show commands executed this session"
    echo "  model <id>      Switch model"
    echo "  dry-run on/off  Toggle dry-run mode"
    echo "  exit / quit     Exit bashia"
}

repl_show_history() {
    if [[ $# -eq 0 ]]; then
        echo "No commands executed this session."
        return
    fi
    echo "Commands executed this session:"
    local i=1
    for cmd in "$@"; do
        printf "  %d. %s\n" "$i" "$cmd"
        ((i++))
    done
}
```

**Step 2: Source repl.sh in bashia and wire up REPL dispatch**

Replace the "REPL mode not yet implemented" placeholder with:

```bash
source "${BASHIA_DIR}/lib/repl.sh"
# In the else branch (no prompt given):
repl_start
```

**Step 3: Handle piped input into REPL**

In the REPL dispatch, if `PIPED_INPUT` is non-empty, set it as initial context:

```bash
if [[ -n "$PIPED_INPUT" ]]; then
    # Pre-seed conversation with piped context
    echo "Piped input received. It will be included as context for your first prompt."
fi
```

**Step 4: Test REPL mode**

```bash
./bashia
# bashia> list files in current directory
# (should show and run command)
# bashia> help
# (should show built-in commands)
# bashia> model openai/gpt-4o
# (should switch model)
# bashia> dry-run on
# (should enable dry-run)
# bashia> exit
```

**Step 5: Commit**

```bash
git add lib/repl.sh bashia
git commit -m "feat: add REPL mode with conversation history and built-in commands"
```

---

### Task 8: Final integration, polish, and install script

**Files:**
- Modify: `bashia` (final cleanup, ensure all modes work together)
- Create: `install.sh` (simple installer)

**Step 1: Clean up the bashia entrypoint**

Ensure the full argument parsing flow is clean:
1. `--version` / `--help` exit early (no config needed)
2. `init` runs wizard and exits
3. Pipe detection happens before flag parsing
4. Flag parsing extracts `--dry-run` and prompt
5. Config is loaded and validated
6. Dangerous commands are loaded
7. Dispatch to single-prompt or REPL mode

**Step 2: Create `install.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Simple installer for bashia
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing bashia to ${INSTALL_DIR}..."

# Check dependencies
for cmd in jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' is required. Please install it first."
        exit 1
    fi
done

# Create bashia wrapper that points to the repo
cat > "${INSTALL_DIR}/bashia" <<EOF
#!/usr/bin/env bash
exec "${SCRIPT_DIR}/bashia" "\$@"
EOF

chmod +x "${INSTALL_DIR}/bashia"

echo "bashia installed successfully!"
echo ""
echo "Run 'bashia init' to configure your API provider."
```

**Step 3: End-to-end test all modes**

```bash
# Single prompt
./bashia --dry-run "show disk usage"

# Single prompt with execution
./bashia "show current date"

# Pipe mode
echo "EACCES" | ./bashia "what does this error mean?"

# REPL mode
./bashia
# Test: help, reset, model, dry-run on/off, exit

# Init (if not already done)
./bashia init
```

**Step 4: Commit**

```bash
git add bashia install.sh
git commit -m "feat: final integration, install script, and polish"
```

---

## Summary of Tasks

| Task | Description | Key Files |
|------|-------------|-----------|
| 1 | Project scaffolding and utils | `bashia`, `lib/utils.sh`, `defaults/*` |
| 2 | Configuration and `bashia init` | `lib/config.sh`, `bashia` |
| 3 | System prompt assembly | `lib/prompt.sh` |
| 4 | API communication | `lib/api.sh` |
| 5 | Command execution and safety | `lib/executor.sh` |
| 6 | Response parsing and single-prompt mode | `bashia` |
| 7 | REPL mode | `lib/repl.sh`, `bashia` |
| 8 | Final integration and install script | `bashia`, `install.sh` |
