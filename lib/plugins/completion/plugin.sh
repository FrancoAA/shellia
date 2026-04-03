#!/usr/bin/env bash
# Plugin: completion — tab autocomplete for REPL commands and file paths

plugin_completion_info() {
    echo "Tab completion for REPL commands and file paths"
}

plugin_completion_hooks() {
    echo "init"
}

# Returns all available REPL commands (built-in + plugin-provided).
# Called on each Tab press so it picks up newly loaded plugins after 'reload'.
_completion_get_commands() {
    # Built-in REPL commands (lib/repl.sh)
    printf '%s\n' help reset reload exit quit
    # Plugin-provided commands
    get_plugin_repl_commands
}

# Core tab handler bound to readline via bind -x.
# Uses READLINE_LINE and READLINE_POINT (bash 4.0+) to read/modify
# the current input line and cursor position.
_completion_tab_handler() {
    local line="$READLINE_LINE"
    local point="$READLINE_POINT"

    # Split into text before/after cursor
    local before="${line:0:$point}"
    local after="${line:$point}"

    # Extract the word currently being typed
    local current_word="${before##* }"

    # Are we completing the first word? (no space before cursor text)
    local is_first_word=false
    [[ "$before" == "$current_word" ]] && is_first_word=true

    local -a completions=()

    if [[ "$is_first_word" == true ]]; then
        # First word: complete REPL commands
        local cmd
        while IFS= read -r cmd; do
            [[ -n "$cmd" && "$cmd" == "$current_word"* ]] && completions+=("$cmd")
        done < <(_completion_get_commands)
    else
        # Subsequent words: complete file paths
        local IFS=$'\n'
        completions=($(compgen -f -- "$current_word" 2>/dev/null))
        # Append / to directories for easier navigation
        local i
        for i in "${!completions[@]}"; do
            [[ -d "${completions[$i]}" ]] && completions[$i]="${completions[$i]}/"
        done
    fi

    local count=${#completions[@]}

    if [[ $count -eq 0 ]]; then
        return
    fi

    if [[ $count -eq 1 ]]; then
        # Single match: insert the completion + trailing space (unless directory)
        local match="${completions[0]}"
        local suffix="${match:${#current_word}}"
        [[ "$match" != */ ]] && suffix+=" "
        READLINE_LINE="${before}${suffix}${after}"
        READLINE_POINT=$(( point + ${#suffix} ))
        return
    fi

    # Multiple matches: find longest common prefix
    local common="${completions[0]}"
    local c
    for c in "${completions[@]:1}"; do
        while [[ ${#common} -gt ${#current_word} && "$c" != "$common"* ]]; do
            common="${common%?}"
        done
    done

    # Insert common prefix if it extends beyond current_word
    local prefix_suffix="${common:${#current_word}}"
    if [[ -n "$prefix_suffix" ]]; then
        READLINE_LINE="${before}${prefix_suffix}${after}"
        READLINE_POINT=$(( point + ${#prefix_suffix} ))
    fi

    # Display all matches below the current line
    echo "" >&2
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    _completion_display_matches "$cols" "${completions[@]}" >&2
}

# Display completion matches in columns, adapting to terminal width.
# Args: $1=terminal_width, $2..=items
_completion_display_matches() {
    local cols="$1"
    shift
    local -a items=("$@")
    local max_len=0 item

    for item in "${items[@]}"; do
        (( ${#item} > max_len )) && max_len=${#item}
    done

    local col_width=$(( max_len + 2 ))
    (( col_width < 1 )) && col_width=1
    local num_cols=$(( cols / col_width ))
    (( num_cols < 1 )) && num_cols=1

    local i=0
    for item in "${items[@]}"; do
        printf "%-${col_width}s" "$item"
        (( ++i % num_cols == 0 )) && echo ""
    done
    (( i % num_cols != 0 )) && echo ""
}

plugin_completion_on_init() {
    # Only set up completion in interactive terminal (REPL mode)
    [[ -t 0 ]] || return 0
    # bind -x requires bash 4.0+; fail silently on older versions
    bind -x '"\t": _completion_tab_handler' 2>/dev/null || true
}
