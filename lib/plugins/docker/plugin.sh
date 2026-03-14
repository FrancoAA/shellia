#!/usr/bin/env bash
# Plugin: docker — run commands inside a persistent Docker sandbox

SHELLIA_DOCKER_SANDBOX_ACTIVE=false
SHELLIA_DOCKER_CONTAINER=""
SHELLIA_DOCKER_IMAGE="ubuntu:latest"
SHELLIA_DOCKER_MOUNT_CWD=true
SHELLIA_DOCKER_EXTRA_ARGS=""
SHELLIA_DOCKER_WORKDIR="/workspace"

plugin_docker_info() {
    echo "Run run_command tool inside a Docker sandbox"
}

plugin_docker_hooks() {
    echo "init shutdown"
}

plugin_docker_on_init() {
    SHELLIA_DOCKER_IMAGE=$(plugin_config_get "docker" "image" "ubuntu:latest")
    SHELLIA_DOCKER_MOUNT_CWD=$(plugin_config_get "docker" "mount_cwd" "true")
    SHELLIA_DOCKER_EXTRA_ARGS=$(plugin_config_get "docker" "extra_args" "")

    if ! command -v docker >/dev/null 2>&1; then
        log_warn "plugin:docker: docker not found; running commands on host"
        SHELLIA_DOCKER_SANDBOX_ACTIVE=false
        return 0
    fi

    SHELLIA_DOCKER_CONTAINER="shellia_sandbox_$$"

    local host_cwd
    host_cwd=$(pwd)

    docker rm -f "$SHELLIA_DOCKER_CONTAINER" >/dev/null 2>&1 || true

    local -a run_args
    run_args=(-d --name "$SHELLIA_DOCKER_CONTAINER" -w "$SHELLIA_DOCKER_WORKDIR")

    if [[ "$SHELLIA_DOCKER_MOUNT_CWD" == "true" ]]; then
        run_args+=(-v "${host_cwd}:${SHELLIA_DOCKER_WORKDIR}")
    fi

    if [[ -n "$SHELLIA_DOCKER_EXTRA_ARGS" ]]; then
        # shellcheck disable=SC2206
        local extra_args=( $SHELLIA_DOCKER_EXTRA_ARGS )
        run_args+=("${extra_args[@]}")
    fi

    if docker run "${run_args[@]}" "$SHELLIA_DOCKER_IMAGE" sleep infinity >/dev/null 2>&1; then
        SHELLIA_DOCKER_SANDBOX_ACTIVE=true
        debug_log "plugin:docker" "container started: ${SHELLIA_DOCKER_CONTAINER} (${SHELLIA_DOCKER_IMAGE})"
    else
        log_warn "plugin:docker: failed to start sandbox; running commands on host"
        SHELLIA_DOCKER_SANDBOX_ACTIVE=false
        SHELLIA_DOCKER_CONTAINER=""
    fi
}

plugin_docker_on_shutdown() {
    [[ -n "$SHELLIA_DOCKER_CONTAINER" ]] || return 0
    docker rm -f "$SHELLIA_DOCKER_CONTAINER" >/dev/null 2>&1 || true
    SHELLIA_DOCKER_SANDBOX_ACTIVE=false
    SHELLIA_DOCKER_CONTAINER=""
}

tool_run_command_schema() {
    cat <<'EOF'
{
    "type": "function",
    "function": {
        "name": "run_command",
        "description": "Execute a shell command in the user's terminal. Use this for any single command, pipeline, loop, heredoc, or script. The command runs in the user's current shell and working directory. Output (stdout and stderr) is captured and returned. IMPORTANT: Commands run non-interactively with no stdin — interactive prompts will receive EOF immediately. Always use non-interactive flags (e.g. npx --yes, apt-get -y, pip install --no-input, git commit -m 'msg') to avoid failures.",
        "parameters": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The shell command to execute"
                }
            },
            "required": ["command"]
        }
    }
}
EOF
}

_docker_run_host_command() {
    local cmd="$1"
    local shell_cmd
    shell_cmd=$(detect_shell)
    _docker_run_with_timeout "$shell_cmd" -c "$cmd"
}

_docker_run_in_container() {
    local cmd="$1"
    _docker_run_with_timeout docker exec "$SHELLIA_DOCKER_CONTAINER" sh -c "$cmd"
}

_docker_run_with_timeout() {
    local timeout_secs="${SHELLIA_CMD_TIMEOUT:-120}"
    local tmpfile
    tmpfile=$(mktemp)

    "$@" </dev/null >"$tmpfile" 2>&1 &
    local cmd_pid=$!

    local elapsed=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
        if [[ $elapsed -ge $timeout_secs ]]; then
            kill -TERM "$cmd_pid" 2>/dev/null
            sleep 1
            kill -9 "$cmd_pid" 2>/dev/null
            wait "$cmd_pid" 2>/dev/null

            local timeout_output
            timeout_output=$(cat "$tmpfile")
            rm -f "$tmpfile"

            echo -e "${THEME_ERROR}Command timed out after ${timeout_secs}s${NC}" >&2
            if [[ -n "$timeout_output" ]]; then
                echo "$timeout_output" >&2
                printf '%s\n[timed out after %ds — command killed]' "$timeout_output" "$timeout_secs"
            else
                printf '[timed out after %ds — command killed]' "$timeout_secs"
            fi
            return 1
        fi
        sleep 1
        ((elapsed++))
    done

    local exit_code=0
    wait "$cmd_pid" || exit_code=$?

    local output
    output=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if [[ $exit_code -ne 0 ]]; then
        echo -e "${THEME_ERROR}Command exited with code ${exit_code}${NC}" >&2
    fi

    if [[ -n "$output" ]]; then
        echo "$output" >&2
        printf '%s\n[exit code: %d]' "$output" "$exit_code"
    else
        printf '[exit code: %d]' "$exit_code"
    fi

    return $exit_code
}

tool_run_command_execute() {
    local args_json="$1"
    local cmd
    cmd=$(echo "$args_json" | jq -r '.command')

    debug_log "tool" "run_command (docker): ${cmd}"
    echo -e "${THEME_CMD}\$ ${cmd}${NC}" >&2

    if [[ "${SHELLIA_DRY_RUN:-false}" == "true" ]]; then
        debug_log "tool" "skipped (dry-run)"
        echo "(dry-run: command not executed)"
        return 0
    fi

    if [[ "$SHELLIA_DOCKER_SANDBOX_ACTIVE" == "true" && -n "$SHELLIA_DOCKER_CONTAINER" ]]; then
        _docker_run_in_container "$cmd"
    else
        _docker_run_host_command "$cmd"
    fi
}
