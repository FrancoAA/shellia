#!/usr/bin/env bash
# Plugin: docker — opt-in Docker sandbox for command execution
# Usage: shellia docker <prompt>    (single-prompt mode in sandbox)
#        shellia docker             (REPL mode in sandbox)

SHELLIA_DOCKER_SANDBOX_ACTIVE=false
SHELLIA_DOCKER_CONTAINER=""
SHELLIA_DOCKER_IMAGE="ubuntu:latest"
SHELLIA_DOCKER_MOUNT_CWD=true
SHELLIA_DOCKER_EXTRA_ARGS=""
SHELLIA_DOCKER_WORKDIR="/workspace"

plugin_docker_info() {
    echo "Run commands inside a Docker sandbox (opt-in via 'shellia docker')"
}

plugin_docker_hooks() {
    # No hooks — sandbox is only activated via the docker subcommand
    echo ""
}

# === Docker sandbox lifecycle ===

_docker_sandbox_start() {
    SHELLIA_DOCKER_IMAGE=$(plugin_config_get "docker" "image" "ubuntu:latest")
    SHELLIA_DOCKER_MOUNT_CWD=$(plugin_config_get "docker" "mount_cwd" "true")
    SHELLIA_DOCKER_EXTRA_ARGS=$(plugin_config_get "docker" "extra_args" "")

    if ! command -v docker >/dev/null 2>&1; then
        die "Docker is required for 'shellia docker'. Install Docker and try again."
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
        die "Failed to start Docker sandbox container. Check Docker is running and image '${SHELLIA_DOCKER_IMAGE}' is available."
    fi
}

_docker_sandbox_stop() {
    [[ -n "$SHELLIA_DOCKER_CONTAINER" ]] || return 0
    docker rm -f "$SHELLIA_DOCKER_CONTAINER" >/dev/null 2>&1 || true
    SHELLIA_DOCKER_SANDBOX_ACTIVE=false
    SHELLIA_DOCKER_CONTAINER=""
}

# === Tool override (only active when sandbox is running) ===

_docker_override_run_command() {
    # Replace the built-in run_command tool with the sandboxed version
    eval 'tool_run_command_execute() {
        local args_json="$1"
        local cmd
        cmd=$(echo "$args_json" | jq -r '"'"'.command'"'"')

        debug_log "tool" "run_command (docker): ${cmd}"
        tool_trace "\$ ${cmd}"

        if [[ "${SHELLIA_DRY_RUN:-false}" == "true" ]]; then
            debug_log "tool" "skipped (dry-run)"
            echo "(dry-run: command not executed)"
            return 0
        fi

        _docker_run_in_container "$cmd"
    }'
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

# === CLI subcommand: shellia docker [prompt] ===

cli_cmd_docker_handler() {
    local prompt="${*:-}"

    _docker_sandbox_start
    _docker_override_run_command

    log_info "Docker sandbox active (${SHELLIA_DOCKER_IMAGE}, container: ${SHELLIA_DOCKER_CONTAINER})"

    if [[ -n "$prompt" ]]; then
        # Single prompt mode inside sandbox
        debug_log "mode" "docker:single-prompt"
        debug_log "prompt" "$prompt"

        local system_prompt
        system_prompt=$(build_system_prompt "single-prompt")
        SHELLIA_LOADED_SKILL_CONTENT=""
        SHELLIA_LOADED_SKILL_NAME=""
        local messages
        messages=$(build_single_messages "$system_prompt" "$prompt")
        local tools
        tools=$(build_tools_array)

        spinner_start "Thinking..."
        local response
        local api_exit=0
        response=$(api_chat_loop "$messages" "$tools") || api_exit=$?
        spinner_stop

        if [[ $api_exit -ne 0 ]]; then
            _docker_sandbox_stop
            fire_hook "shutdown"
            exit 1
        fi

        if [[ -n "$response" ]]; then
            echo "$response" | format_markdown
        fi
    else
        # REPL mode inside sandbox
        debug_log "mode" "docker:repl"
        repl_start
    fi

    _docker_sandbox_stop
    fire_hook "shutdown"
}

cli_cmd_docker_help() {
    echo "  docker [PROMPT]           Run inside a Docker sandbox"
}

cli_cmd_docker_setup() {
    echo "config validate theme tools plugins hooks_init"
}

# === REPL command: docker (toggle sandbox in existing REPL) ===

repl_cmd_docker_handler() {
    if [[ "$SHELLIA_DOCKER_SANDBOX_ACTIVE" == "true" ]]; then
        _docker_sandbox_stop
        # Restore original run_command by re-sourcing the tool file
        source "${SHELLIA_DIR}/lib/tools/run_command.sh"
        log_info "Docker sandbox stopped. Commands now run on host."
    else
        _docker_sandbox_start
        _docker_override_run_command
        log_info "Docker sandbox active (${SHELLIA_DOCKER_IMAGE}, container: ${SHELLIA_DOCKER_CONTAINER})"
    fi
}

repl_cmd_docker_help() {
    echo -e "  ${THEME_ACCENT}docker${NC}            Toggle Docker sandbox on/off"
}
