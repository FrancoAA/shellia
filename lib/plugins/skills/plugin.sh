#!/usr/bin/env bash
# Plugin: skills — Claude-compatible agent skill discovery and loading
# Skills are SKILL.md files with YAML frontmatter (name + description)
# discovered from ~/.agents/skills/ (shared hub) and ~/.config/shellia/skills/

# --- Registry state (Bash 3.2 compatible) ---

# Indexed array of skill names (in discovery order)
_SHELLIA_SKILL_NAMES=()

# Indexed array of "name|description|path" entries
_SHELLIA_SKILL_ENTRIES=()

# Loaded skill content for REPL injection into next message
SHELLIA_LOADED_SKILL_CONTENT=""
SHELLIA_LOADED_SKILL_NAME=""

# --- Plugin interface ---

plugin_skills_info() {
    echo "Claude-compatible agent skill discovery and loading"
}

plugin_skills_hooks() {
    echo "init prompt_build"
}

plugin_skills_on_init() {
    _skills_discover
    local count=${#_SHELLIA_SKILL_NAMES[@]}
    debug_log "plugin:skills" "discovered ${count} skill(s)"
}

plugin_skills_on_prompt_build() {
    local mode="${1:-}"
    local count=${#_SHELLIA_SKILL_NAMES[@]}

    # No skills discovered — output nothing
    [[ $count -eq 0 ]] && return 0

    echo ""
    echo "AVAILABLE SKILLS:"
    echo "You have access to specialized skills that provide domain-specific instructions."
    echo "Use the load_skill tool when a task matches one of these skills:"

    local name
    for name in ${_SHELLIA_SKILL_NAMES[@]+"${_SHELLIA_SKILL_NAMES[@]}"}; do
        local desc
        desc=$(_skills_get_description "$name")
        echo "- ${name}: ${desc}"
    done
}

# --- Skill discovery ---

# Scan skill directories and build the registry
_skills_discover() {
    _SHELLIA_SKILL_NAMES=()
    _SHELLIA_SKILL_ENTRIES=()

    # 1. Shared hub (lowest priority — can be overridden)
    _skills_scan_dir "${HOME}/.agents/skills"

    # 2. Shellia-exclusive (highest priority — overrides hub)
    _skills_scan_dir "${SHELLIA_CONFIG_DIR}/skills"
}

# Scan a directory for skill subdirectories containing SKILL.md
_skills_scan_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0

    local skill_dir
    for skill_dir in "${dir}"/*/; do
        [[ -d "$skill_dir" ]] || continue
        local skill_file="${skill_dir}SKILL.md"
        [[ -f "$skill_file" ]] || continue

        local name=""
        local description=""

        # Parse frontmatter
        local frontmatter
        frontmatter=$(_skills_parse_frontmatter "$skill_file")

        if [[ -n "$frontmatter" ]]; then
            name=$(echo "$frontmatter" | grep '^name:' | head -1 | sed 's/^name:[[:space:]]*//')
            description=$(echo "$frontmatter" | grep '^description:' | head -1 | sed 's/^description:[[:space:]]*//')
        fi

        # Fall back to directory name if no name in frontmatter
        if [[ -z "$name" ]]; then
            name=$(basename "$skill_dir")
        fi

        # Skip skills without a description
        if [[ -z "$description" ]]; then
            debug_log "plugin:skills" "skipping '${name}' — no description in frontmatter"
            continue
        fi

        _skills_register "$name" "$description" "$skill_file"
    done
}

# Extract YAML frontmatter (between --- delimiters) from a SKILL.md file
# Returns lines of "key: value" pairs on stdout
_skills_parse_frontmatter() {
    local file="$1"
    local in_frontmatter=false
    local found_start=false

    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if [[ "$found_start" == "false" ]]; then
                found_start=true
                in_frontmatter=true
                continue
            else
                # Second --- means end of frontmatter
                break
            fi
        fi

        if [[ "$in_frontmatter" == "true" ]]; then
            echo "$line"
        fi
    done < "$file"
}

# --- Registry operations ---

# Register a skill (overrides existing with same name)
_skills_register() {
    local name="$1"
    local description="$2"
    local path="$3"

    # Check if already registered (override case)
    local count=${#_SHELLIA_SKILL_NAMES[@]}
    if [[ $count -gt 0 ]]; then
        local i
        for i in $(seq 0 $(( count - 1 ))); do
            if [[ "${_SHELLIA_SKILL_NAMES[$i]}" == "$name" ]]; then
                _SHELLIA_SKILL_ENTRIES[$i]="${name}|${description}|${path}"
                debug_log "plugin:skills" "override '${name}' from ${path}"
                return 0
            fi
        done
    fi

    # New skill
    _SHELLIA_SKILL_NAMES+=("$name")
    _SHELLIA_SKILL_ENTRIES+=("${name}|${description}|${path}")
    debug_log "plugin:skills" "registered '${name}' from ${path}"
}

# Get the description for a skill
_skills_get_description() {
    local target="$1"
    local count=${#_SHELLIA_SKILL_ENTRIES[@]}
    [[ $count -eq 0 ]] && { echo ""; return 0; }
    local i
    for i in $(seq 0 $(( count - 1 ))); do
        local entry="${_SHELLIA_SKILL_ENTRIES[$i]}"
        local name="${entry%%|*}"
        if [[ "$name" == "$target" ]]; then
            # Extract description (between first and second |)
            local rest="${entry#*|}"
            echo "${rest%%|*}"
            return 0
        fi
    done
    echo ""
}

# Get the file path for a skill
_skills_get_path() {
    local target="$1"
    local count=${#_SHELLIA_SKILL_ENTRIES[@]}
    [[ $count -eq 0 ]] && { echo ""; return 0; }
    local i
    for i in $(seq 0 $(( count - 1 ))); do
        local entry="${_SHELLIA_SKILL_ENTRIES[$i]}"
        local name="${entry%%|*}"
        if [[ "$name" == "$target" ]]; then
            # Extract path (after second |)
            local rest="${entry#*|}"
            echo "${rest#*|}"
            return 0
        fi
    done
    echo ""
}

# List all registered skill names
_skills_list_all() {
    local name
    for name in ${_SHELLIA_SKILL_NAMES[@]+"${_SHELLIA_SKILL_NAMES[@]}"}; do
        echo "$name"
    done
}

# Load the full content of a skill (body without frontmatter)
_skills_load_content() {
    local name="$1"
    local path
    path=$(_skills_get_path "$name")

    if [[ -z "$path" || ! -f "$path" ]]; then
        echo "Error: skill '${name}' not found."
        return 1
    fi

    # Strip frontmatter and return body
    local found_start=false
    local past_frontmatter=false
    local body=""

    while IFS= read -r line; do
        if [[ "$past_frontmatter" == "true" ]]; then
            body="${body}${line}
"
            continue
        fi

        if [[ "$line" == "---" ]]; then
            if [[ "$found_start" == "false" ]]; then
                found_start=true
                continue
            else
                past_frontmatter=true
                continue
            fi
        fi

        # If first line is not ---, there's no frontmatter — include everything
        if [[ "$found_start" == "false" ]]; then
            past_frontmatter=true
            body="${line}
"
        fi
    done < "$path"

    # Trim leading blank lines
    echo "$body" | sed '/./,$!d'
}

# --- load_skill tool ---

tool_load_skill_schema() {
    # Build dynamic description with available skills
    local skill_list=""
    local name
    for name in ${_SHELLIA_SKILL_NAMES[@]+"${_SHELLIA_SKILL_NAMES[@]}"}; do
        local desc
        desc=$(_skills_get_description "$name")
        skill_list="${skill_list}\n- ${name}: ${desc}"
    done

    local description="Load a specialized skill that provides domain-specific instructions and workflows. When you recognize that a task matches one of the available skills, use this tool to load the full skill instructions. The skill content will be returned to you — follow it directly."

    if [[ -n "$skill_list" ]]; then
        description="${description}\n\nAvailable skills:${skill_list}"
    fi

    # Use printf to expand \n, then jq for safe JSON encoding
    local expanded_desc
    expanded_desc=$(printf '%b' "$description")

    jq -n --arg desc "$expanded_desc" '{
        type: "function",
        function: {
            name: "load_skill",
            description: $desc,
            parameters: {
                type: "object",
                properties: {
                    name: {
                        type: "string",
                        description: "The name of the skill to load"
                    }
                },
                required: ["name"]
            }
        }
    }'
}

tool_load_skill_execute() {
    local args_json="$1"
    local skill_name
    skill_name=$(echo "$args_json" | jq -r '.name')

    if [[ -z "$skill_name" ]]; then
        echo "Error: skill name is required."
        return 1
    fi

    local path
    path=$(_skills_get_path "$skill_name")

    if [[ -z "$path" || ! -f "$path" ]]; then
        echo "Error: skill '${skill_name}' not found. Available skills:"
        local name
        for name in ${_SHELLIA_SKILL_NAMES[@]+"${_SHELLIA_SKILL_NAMES[@]}"}; do
            local desc
            desc=$(_skills_get_description "$name")
            echo "  - ${name}: ${desc}"
        done
        return 1
    fi

    local skill_dir
    skill_dir=$(dirname "$path")

    echo -e "${THEME_MUTED}Loading skill: ${skill_name}${NC}" >&2

    # Load and return skill content
    local content
    content=$(_skills_load_content "$skill_name")

    # Include metadata header (matches Claude Code's format)
    printf '<skill_content name="%s">\n' "$skill_name"
    echo "$content"
    printf 'Base directory for this skill: %s\n' "$skill_dir"
    printf 'Relative paths in this skill are relative to this base directory.\n'
    printf '</skill_content>\n'
}

# --- REPL commands ---

# skills [list|load <name>|<name>] — list or load skills
# Note: REPL dispatch passes all args as a single string in $1
repl_cmd_skills_handler() {
    local args="${1:-}"
    local subcmd="${args%% *}"
    local rest="${args#* }"
    [[ "$subcmd" == "$args" ]] && rest=""

    case "$subcmd" in
        list|"")
            _skills_repl_list
            ;;
        load)
            if [[ -z "$rest" ]]; then
                log_warn "Usage: skills load <name>"
                return 1
            fi
            _skills_repl_load "$rest"
            ;;
        *)
            # Treat as skill name: skills <name> → load it
            _skills_repl_load "$subcmd"
            ;;
    esac
}

repl_cmd_skills_help() {
    echo -e "  ${THEME_ACCENT}skills${NC}            List/load agent skills"
}

# skill <name> — shorthand for loading a skill
repl_cmd_skill_handler() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        # No name given, list skills
        _skills_repl_list
        return 0
    fi
    _skills_repl_load "$name"
}

repl_cmd_skill_help() {
    echo -e "  ${THEME_ACCENT}skill <name>${NC}      Load a skill by name"
}

# Internal: list skills in REPL
_skills_repl_list() {
    local count=${#_SHELLIA_SKILL_NAMES[@]}

    if [[ $count -eq 0 ]]; then
        echo -e "${THEME_MUTED}No skills discovered.${NC}"
        echo ""
        echo "Skills are discovered from:"
        echo "  - ~/.agents/skills/        (shared, install with: npx skills add <pkg>)"
        echo "  - ~/.config/shellia/skills/ (shellia-exclusive)"
        return 0
    fi

    echo -e "${THEME_ACCENT}Available skills (${count}):${NC}"
    echo ""

    local name
    for name in "${_SHELLIA_SKILL_NAMES[@]}"; do
        local desc
        desc=$(_skills_get_description "$name")
        echo -e "  ${THEME_ACCENT}${name}${NC}"
        echo -e "    ${THEME_MUTED}${desc}${NC}"
    done

    echo ""
    echo -e "${THEME_MUTED}Load with: skill <name>${NC}"
}

# Internal: load a skill in REPL (prints content for user, sets context for next message)
_skills_repl_load() {
    local name="$1"
    local path
    path=$(_skills_get_path "$name")

    if [[ -z "$path" || ! -f "$path" ]]; then
        log_warn "Skill '${name}' not found."
        echo ""
        echo "Available skills:"
        local s
        for s in ${_SHELLIA_SKILL_NAMES[@]+"${_SHELLIA_SKILL_NAMES[@]}"}; do
            echo "  - ${s}"
        done
        return 1
    fi

    local content
    content=$(_skills_load_content "$name")

    echo -e "${THEME_SUCCESS}Loaded skill: ${name}${NC}"
    echo -e "${THEME_MUTED}Skill instructions will be included in your next message.${NC}"

    # Store loaded skill content for injection into next message
    SHELLIA_LOADED_SKILL_CONTENT="$content"
    SHELLIA_LOADED_SKILL_NAME="$name"
}
