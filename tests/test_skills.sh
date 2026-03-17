#!/usr/bin/env bash
# Tests for the skills plugin (lib/plugins/skills/plugin.sh)

# Source the skills plugin
source "${PROJECT_DIR}/lib/plugins/skills/plugin.sh"

# Helper: reset skill registry state
_reset_skill_state() {
    _SHELLIA_SKILL_NAMES=()
    _SHELLIA_SKILL_ENTRIES=()
    SHELLIA_LOADED_SKILL_CONTENT=""
    SHELLIA_LOADED_SKILL_NAME=""
}

# Helper: create a test SKILL.md file
# Args: dir, name, description, [body]
_create_test_skill() {
    local dir="$1"
    local name="$2"
    local description="$3"
    local body="${4:-# ${name}

This is the ${name} skill content.}"

    mkdir -p "${dir}/${name}"
    cat > "${dir}/${name}/SKILL.md" <<SKILL_EOF
---
name: ${name}
description: ${description}
---

${body}
SKILL_EOF
}

# Helper: create a skill with no frontmatter
_create_test_skill_no_frontmatter() {
    local dir="$1"
    local name="$2"
    local body="${3:-# No Frontmatter Skill

Just some content.}"

    mkdir -p "${dir}/${name}"
    cat > "${dir}/${name}/SKILL.md" <<SKILL_EOF
${body}
SKILL_EOF
}

# Helper: create a skill with partial frontmatter (name only, no description)
_create_test_skill_no_description() {
    local dir="$1"
    local name="$2"

    mkdir -p "${dir}/${name}"
    cat > "${dir}/${name}/SKILL.md" <<SKILL_EOF
---
name: ${name}
---

# ${name}

Missing description skill.
SKILL_EOF
}

# --- Frontmatter parsing tests ---

test_parse_frontmatter_valid() {
    _reset_skill_state

    local skill_dir="${TEST_TMP}/fm_valid"
    _create_test_skill "$skill_dir" "test-skill" "Use when testing"

    local result
    result=$(_skills_parse_frontmatter "${skill_dir}/test-skill/SKILL.md")

    assert_contains "$result" "name: test-skill" "frontmatter contains name"
    assert_contains "$result" "description: Use when testing" "frontmatter contains description"
}

test_parse_frontmatter_empty_file() {
    _reset_skill_state

    local skill_dir="${TEST_TMP}/fm_empty"
    mkdir -p "${skill_dir}/empty"
    echo "" > "${skill_dir}/empty/SKILL.md"

    local result
    result=$(_skills_parse_frontmatter "${skill_dir}/empty/SKILL.md")

    assert_eq "$result" "" "empty file returns empty frontmatter"
}

test_parse_frontmatter_no_delimiters() {
    _reset_skill_state

    local skill_dir="${TEST_TMP}/fm_nodelim"
    _create_test_skill_no_frontmatter "$skill_dir" "nofm"

    local result
    result=$(_skills_parse_frontmatter "${skill_dir}/nofm/SKILL.md")

    assert_eq "$result" "" "file without --- returns empty frontmatter"
}

test_parse_frontmatter_extra_fields_ignored() {
    _reset_skill_state

    local skill_dir="${TEST_TMP}/fm_extra"
    mkdir -p "${skill_dir}/extra"
    cat > "${skill_dir}/extra/SKILL.md" <<'EOF'
---
name: extra-skill
description: Use when testing extra fields
license: MIT
author: Test Author
---

# Extra Fields Skill
EOF

    local result
    result=$(_skills_parse_frontmatter "${skill_dir}/extra/SKILL.md")

    assert_contains "$result" "name: extra-skill" "name is present"
    assert_contains "$result" "description: Use when testing extra fields" "description is present"
    assert_contains "$result" "license: MIT" "extra field is preserved in raw output"
}

# --- Discovery tests ---

test_discover_no_skills_dir() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/no_skills_config"
    HOME="${TEST_TMP}/no_skills_home"
    SHELLIA_DIR="${TEST_TMP}/no_skills_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"

    _skills_discover

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "0" "no skills when directories don't exist"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}

test_discover_single_skill() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/single_config"
    HOME="${TEST_TMP}/single_home"
    SHELLIA_DIR="${TEST_TMP}/single_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"

    _create_test_skill "${SHELLIA_CONFIG_DIR}/skills" "my-skill" "Use when doing things"

    _skills_discover

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "1" "one skill discovered"
    assert_eq "${_SHELLIA_SKILL_NAMES[0]}" "my-skill" "correct skill name"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}

test_discover_from_hub() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    HOME="${TEST_TMP}/hub_home"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/hub_config"
    SHELLIA_DIR="${TEST_TMP}/hub_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"

    _create_test_skill "${HOME}/.agents/skills" "hub-skill" "Use when hub testing"

    _skills_discover

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "1" "hub skill discovered"
    assert_eq "${_SHELLIA_SKILL_NAMES[0]}" "hub-skill" "correct hub skill name"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}

test_discover_from_builtin_skills_dir() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    HOME="${TEST_TMP}/builtin_home"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/builtin_config"
    SHELLIA_DIR="${TEST_TMP}/builtin_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"

    _create_test_skill "${SHELLIA_DIR}/lib/skills" "builtin-skill" "Use from built-in skills"

    _skills_discover

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "1" "built-in skill discovered"
    assert_eq "${_SHELLIA_SKILL_NAMES[0]}" "builtin-skill" "correct built-in skill name"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}

test_discover_from_both_dirs() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    HOME="${TEST_TMP}/both_home"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/both_config"
    SHELLIA_DIR="${TEST_TMP}/both_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"

    _create_test_skill "${HOME}/.agents/skills" "hub-only" "Use from hub"
    _create_test_skill "${SHELLIA_CONFIG_DIR}/skills" "shellia-only" "Use from shellia"

    _skills_discover

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "2" "two skills from both dirs"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}

test_discover_shellia_overrides_hub() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    HOME="${TEST_TMP}/override_home"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/override_config"
    SHELLIA_DIR="${TEST_TMP}/override_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"

    _create_test_skill "${HOME}/.agents/skills" "shared-skill" "Hub version" "Hub body content"
    _create_test_skill "${SHELLIA_CONFIG_DIR}/skills" "shared-skill" "Shellia version" "Shellia body content"

    _skills_discover

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "1" "only one skill after override"
    assert_eq "${_SHELLIA_SKILL_NAMES[0]}" "shared-skill" "name is preserved"

    local desc
    desc=$(_skills_get_description "shared-skill")
    assert_eq "$desc" "Shellia version" "shellia version overrides hub"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}

test_discover_priority_hub_builtin_shellia() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    HOME="${TEST_TMP}/priority_home"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/priority_config"
    SHELLIA_DIR="${TEST_TMP}/priority_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"

    _create_test_skill "${HOME}/.agents/skills" "priority-skill" "Hub version"
    _create_test_skill "${SHELLIA_DIR}/lib/skills" "priority-skill" "Built-in version"
    _create_test_skill "${SHELLIA_CONFIG_DIR}/skills" "priority-skill" "Shellia config version"

    _skills_discover

    local desc
    desc=$(_skills_get_description "priority-skill")
    assert_eq "$desc" "Shellia config version" "shellia config overrides built-in and hub"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}

test_discover_skips_no_description() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    HOME="${TEST_TMP}/nodesc_home"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/nodesc_config"
    SHELLIA_DIR="${TEST_TMP}/nodesc_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"

    _create_test_skill_no_description "${SHELLIA_CONFIG_DIR}/skills" "nodesc-skill"

    _skills_discover

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "0" "skill without description is skipped"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}

test_discover_skips_no_frontmatter() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    HOME="${TEST_TMP}/nofm_home"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/nofm_config"
    SHELLIA_DIR="${TEST_TMP}/nofm_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"

    _create_test_skill_no_frontmatter "${SHELLIA_CONFIG_DIR}/skills" "nofm-skill"

    _skills_discover

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "0" "skill without frontmatter is skipped"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}

test_discover_skips_dir_without_skill_md() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    HOME="${TEST_TMP}/nomd_home"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/nomd_config"
    SHELLIA_DIR="${TEST_TMP}/nomd_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"

    # Create a directory without SKILL.md
    mkdir -p "${SHELLIA_CONFIG_DIR}/skills/empty-dir"
    echo "not a skill" > "${SHELLIA_CONFIG_DIR}/skills/empty-dir/README.md"

    _skills_discover

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "0" "directory without SKILL.md is skipped"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}

test_discover_follows_symlinks() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    HOME="${TEST_TMP}/symlink_home"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/symlink_config"
    SHELLIA_DIR="${TEST_TMP}/symlink_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"
    mkdir -p "${HOME}/.agents/skills"

    # Create actual skill in a separate location
    local actual_dir="${TEST_TMP}/actual_skills"
    _create_test_skill "$actual_dir" "linked-skill" "Use when following links"

    # Symlink it into the hub
    ln -s "${actual_dir}/linked-skill" "${HOME}/.agents/skills/linked-skill"

    _skills_discover

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "1" "symlinked skill discovered"
    assert_eq "${_SHELLIA_SKILL_NAMES[0]}" "linked-skill" "correct symlinked skill name"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}

# --- Registry operation tests ---

test_register_and_lookup() {
    _reset_skill_state

    _skills_register "alpha" "Alpha description" "/path/to/alpha/SKILL.md"
    _skills_register "beta" "Beta description" "/path/to/beta/SKILL.md"

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "2" "two skills registered"

    local desc
    desc=$(_skills_get_description "alpha")
    assert_eq "$desc" "Alpha description" "alpha description correct"

    desc=$(_skills_get_description "beta")
    assert_eq "$desc" "Beta description" "beta description correct"
}

test_get_path() {
    _reset_skill_state

    _skills_register "gamma" "Gamma desc" "/tmp/gamma/SKILL.md"

    local path
    path=$(_skills_get_path "gamma")
    assert_eq "$path" "/tmp/gamma/SKILL.md" "path retrieval correct"
}

test_get_description_unknown() {
    _reset_skill_state

    local desc
    desc=$(_skills_get_description "nonexistent")
    assert_eq "$desc" "" "unknown skill returns empty description"
}

test_get_path_unknown() {
    _reset_skill_state

    local path
    path=$(_skills_get_path "nonexistent")
    assert_eq "$path" "" "unknown skill returns empty path"
}

test_list_all() {
    _reset_skill_state

    _skills_register "one" "One desc" "/one/SKILL.md"
    _skills_register "two" "Two desc" "/two/SKILL.md"
    _skills_register "three" "Three desc" "/three/SKILL.md"

    local names
    names=$(_skills_list_all)

    assert_contains "$names" "one" "list contains one"
    assert_contains "$names" "two" "list contains two"
    assert_contains "$names" "three" "list contains three"
}

test_register_override() {
    _reset_skill_state

    _skills_register "dup" "Original desc" "/original/SKILL.md"
    _skills_register "dup" "Override desc" "/override/SKILL.md"

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "1" "still one skill after override"

    local desc
    desc=$(_skills_get_description "dup")
    assert_eq "$desc" "Override desc" "description is overridden"

    local path
    path=$(_skills_get_path "dup")
    assert_eq "$path" "/override/SKILL.md" "path is overridden"
}

# --- Content loading tests ---

test_load_content_strips_frontmatter() {
    _reset_skill_state

    local skill_dir="${TEST_TMP}/content_test"
    _create_test_skill "$skill_dir" "content-skill" "Use for content testing" "# Content Skill

This is the body."

    _skills_register "content-skill" "Use for content testing" "${skill_dir}/content-skill/SKILL.md"

    local content
    content=$(_skills_load_content "content-skill")

    assert_contains "$content" "# Content Skill" "body contains heading"
    assert_contains "$content" "This is the body." "body contains text"
    assert_not_contains "$content" "---" "frontmatter delimiters stripped"
    assert_not_contains "$content" "name: content-skill" "name field stripped"
    assert_not_contains "$content" "description:" "description field stripped"
}

test_load_content_no_frontmatter() {
    _reset_skill_state

    local skill_dir="${TEST_TMP}/nofm_content"
    _create_test_skill_no_frontmatter "$skill_dir" "raw-skill" "# Raw Skill

Pure content, no frontmatter."

    _skills_register "raw-skill" "Manually registered" "${skill_dir}/raw-skill/SKILL.md"

    local content
    content=$(_skills_load_content "raw-skill")

    assert_contains "$content" "# Raw Skill" "raw content preserved"
    assert_contains "$content" "Pure content, no frontmatter." "full body returned"
}

test_load_content_unknown_skill() {
    _reset_skill_state

    local content
    local exit_code=0
    content=$(_skills_load_content "ghost-skill") || exit_code=$?

    assert_eq "$exit_code" "1" "unknown skill returns exit code 1"
    assert_contains "$content" "Error" "error message returned"
}

# --- Tool schema tests ---

test_tool_schema_valid_json() {
    _reset_skill_state

    _skills_register "json-test" "Test JSON schema" "/test/SKILL.md"

    local schema
    schema=$(tool_load_skill_schema)

    assert_valid_json "$schema" "tool schema is valid JSON"
}

test_tool_schema_includes_skill_list() {
    _reset_skill_state

    _skills_register "alpha-skill" "Alpha things" "/alpha/SKILL.md"
    _skills_register "beta-skill" "Beta things" "/beta/SKILL.md"

    local schema
    schema=$(tool_load_skill_schema)

    local desc
    desc=$(echo "$schema" | jq -r '.function.description')

    assert_contains "$desc" "alpha-skill" "schema description lists alpha skill"
    assert_contains "$desc" "beta-skill" "schema description lists beta skill"
    assert_contains "$desc" "Alpha things" "schema includes alpha description"
}

test_tool_schema_name_is_load_skill() {
    _reset_skill_state

    local schema
    schema=$(tool_load_skill_schema)

    local name
    name=$(echo "$schema" | jq -r '.function.name')

    assert_eq "$name" "load_skill" "tool name is load_skill"
}

# --- Tool execute tests ---

test_tool_execute_returns_content() {
    _reset_skill_state

    local skill_dir="${TEST_TMP}/exec_test"
    _create_test_skill "$skill_dir" "exec-skill" "Use for execution" "# Execution Skill

Follow these instructions."

    _skills_register "exec-skill" "Use for execution" "${skill_dir}/exec-skill/SKILL.md"

    local result
    result=$(tool_load_skill_execute '{"name": "exec-skill"}' 2>/dev/null)

    assert_contains "$result" "skill_content" "result contains skill_content tag"
    assert_contains "$result" "exec-skill" "result contains skill name"
    assert_contains "$result" "Follow these instructions." "result contains skill body"
    assert_contains "$result" "Base directory" "result contains base directory info"
}

test_tool_execute_unknown_skill() {
    _reset_skill_state

    local result
    local exit_code=0
    result=$(tool_load_skill_execute '{"name": "nonexistent"}' 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "1" "unknown skill returns error exit code"
    assert_contains "$result" "Error" "error message for unknown skill"
    assert_contains "$result" "not found" "message says not found"
}

test_tool_execute_empty_name() {
    _reset_skill_state

    local result
    local exit_code=0
    result=$(tool_load_skill_execute '{"name": ""}' 2>/dev/null) || exit_code=$?

    assert_eq "$exit_code" "1" "empty name returns error"
    assert_contains "$result" "Error" "error message for empty name"
}

# --- Prompt build hook tests ---

test_prompt_build_with_skills() {
    _reset_skill_state

    _skills_register "prompt-skill" "Use when building prompts" "/test/SKILL.md"

    local output
    output=$(plugin_skills_on_prompt_build "interactive")

    assert_contains "$output" "AVAILABLE SKILLS" "output has header"
    assert_contains "$output" "load_skill" "output mentions load_skill tool"
    assert_contains "$output" "prompt-skill" "output lists the skill name"
    assert_contains "$output" "Use when building prompts" "output includes description"
}

test_prompt_build_no_skills() {
    _reset_skill_state

    local output
    output=$(plugin_skills_on_prompt_build "interactive")

    assert_eq "$output" "" "no output when no skills"
}

test_prompt_build_multiple_skills() {
    _reset_skill_state

    _skills_register "skill-a" "Use for A" "/a/SKILL.md"
    _skills_register "skill-b" "Use for B" "/b/SKILL.md"
    _skills_register "skill-c" "Use for C" "/c/SKILL.md"

    local output
    output=$(plugin_skills_on_prompt_build "interactive")

    assert_contains "$output" "skill-a" "lists skill A"
    assert_contains "$output" "skill-b" "lists skill B"
    assert_contains "$output" "skill-c" "lists skill C"
}

test_prompt_build_once_after_repl_skill_load() {
    _reset_skill_state

    local skill_dir="${TEST_TMP}/prompt_loaded_skill"
    _create_test_skill "$skill_dir" "loaded-skill" "Use when injecting" "# Loaded Skill

Apply these steps first."

    _skills_register "loaded-skill" "Use when injecting" "${skill_dir}/loaded-skill/SKILL.md"

    _skills_repl_load "loaded-skill" >/dev/null 2>&1

    SHELLIA_LOADED_PLUGINS=(skills)
    _SHELLIA_HOOK_ENTRIES=(prompt_build:skills)

    local output
    output=$(build_system_prompt "interactive")

    assert_contains "$output" "LOADED SKILL CONTEXT" "prompt hook includes loaded skill context"
    assert_contains "$output" "loaded-skill" "prompt hook includes loaded skill name"
    assert_contains "$output" "Apply these steps first" "prompt hook includes loaded skill content"

    # Simulate normal caller behavior (build prompt once per request and clear
    # skill context immediately after use).
    SHELLIA_LOADED_SKILL_CONTENT=""
    SHELLIA_LOADED_SKILL_NAME=""

    local second_output
    second_output=$(build_system_prompt "interactive")

    assert_not_contains "$second_output" "LOADED SKILL CONTEXT" "loaded skill context is one-shot"
}

# --- REPL command tests ---

test_repl_skills_list() {
    _reset_skill_state

    _skills_register "repl-skill" "Use in REPL" "/repl/SKILL.md"

    local output
    output=$(_skills_repl_list 2>/dev/null)

    assert_contains "$output" "repl-skill" "skills list shows skill name"
}

test_repl_skills_list_empty() {
    _reset_skill_state

    local output
    output=$(_skills_repl_list 2>/dev/null)

    assert_contains "$output" "No skills discovered" "shows no skills message"
    assert_contains "$output" "~/.agents/skills/" "shows hub path hint"
}

test_repl_skill_load() {
    _reset_skill_state

    local skill_dir="${TEST_TMP}/repl_load"
    _create_test_skill "$skill_dir" "loadable" "Use when loading" "# Loadable Skill

Load me!"

    _skills_register "loadable" "Use when loading" "${skill_dir}/loadable/SKILL.md"

    _skills_repl_load "loadable" >/dev/null 2>&1

    assert_not_empty "$SHELLIA_LOADED_SKILL_CONTENT" "skill content is stored"
    assert_eq "$SHELLIA_LOADED_SKILL_NAME" "loadable" "skill name is stored"
    assert_contains "$SHELLIA_LOADED_SKILL_CONTENT" "Load me!" "content has body text"
}

test_repl_skill_load_unknown() {
    _reset_skill_state

    local exit_code=0
    _skills_repl_load "ghost" >/dev/null 2>&1 || exit_code=$?

    assert_eq "$exit_code" "1" "loading unknown skill returns error"
    assert_eq "$SHELLIA_LOADED_SKILL_CONTENT" "" "no content stored for unknown"
}

# --- Plugin interface tests ---

test_plugin_info() {
    local info
    info=$(plugin_skills_info)

    assert_not_empty "$info" "plugin info returns a string"
    assert_contains "$info" "skill" "info mentions skills"
}

test_plugin_hooks() {
    local hooks
    hooks=$(plugin_skills_hooks)

    assert_contains "$hooks" "init" "hooks include init"
    assert_contains "$hooks" "prompt_build" "hooks include prompt_build"
}

# --- Frontmatter edge case: directory name as fallback ---

test_discover_uses_dirname_when_no_name_in_frontmatter() {
    _reset_skill_state

    local orig_config="$SHELLIA_CONFIG_DIR"
    local orig_home="$HOME"
    local orig_shellia_dir="$SHELLIA_DIR"
    HOME="${TEST_TMP}/dirname_home"
    SHELLIA_CONFIG_DIR="${TEST_TMP}/dirname_config"
    SHELLIA_DIR="${TEST_TMP}/dirname_shellia"
    mkdir -p "$SHELLIA_CONFIG_DIR"

    # Create skill with frontmatter that has description but no name
    local skill_dir="${SHELLIA_CONFIG_DIR}/skills/my-dirname-skill"
    mkdir -p "$skill_dir"
    cat > "${skill_dir}/SKILL.md" <<'EOF'
---
description: Use when testing dirname fallback
---

# Dirname Skill
EOF

    _skills_discover

    assert_eq "${#_SHELLIA_SKILL_NAMES[@]}" "1" "skill discovered with dirname fallback"
    assert_eq "${_SHELLIA_SKILL_NAMES[0]}" "my-dirname-skill" "name falls back to dirname"

    HOME="$orig_home"
    SHELLIA_CONFIG_DIR="$orig_config"
    SHELLIA_DIR="$orig_shellia_dir"
}
