#!/usr/bin/env bash
# Tests for lib/themes.sh
#
# Note: apply_theme() has a TTY guard ([[ -t 1 ]]) so it no-ops in
# non-interactive contexts. We test the theme_* functions directly
# and test apply_theme's dispatch logic separately.

test_theme_default_sets_vars() {
    theme_default
    assert_not_empty "$THEME_PROMPT" "default theme sets THEME_PROMPT"
    assert_not_empty "$THEME_HEADER" "default theme sets THEME_HEADER"
    assert_not_empty "$THEME_ACCENT" "default theme sets THEME_ACCENT"
    assert_not_empty "$THEME_CMD" "default theme sets THEME_CMD"
    assert_not_empty "$THEME_SUCCESS" "default theme sets THEME_SUCCESS"
    assert_not_empty "$THEME_WARN" "default theme sets THEME_WARN"
    assert_not_empty "$THEME_ERROR" "default theme sets THEME_ERROR"
    assert_not_empty "$THEME_INFO" "default theme sets THEME_INFO"
    assert_not_empty "$THEME_THINKING" "default theme sets THEME_THINKING"
}

test_theme_ocean_sets_vars() {
    theme_ocean
    assert_not_empty "$THEME_PROMPT" "ocean theme sets THEME_PROMPT"
    assert_not_empty "$THEME_HEADER" "ocean theme sets THEME_HEADER"
}

test_theme_forest_sets_vars() {
    theme_forest
    assert_not_empty "$THEME_PROMPT" "forest theme sets THEME_PROMPT"
    assert_not_empty "$THEME_HEADER" "forest theme sets THEME_HEADER"
}

test_theme_sunset_sets_vars() {
    theme_sunset
    assert_not_empty "$THEME_PROMPT" "sunset theme sets THEME_PROMPT"
    assert_not_empty "$THEME_HEADER" "sunset theme sets THEME_HEADER"
}

test_theme_minimal_sets_vars() {
    theme_minimal
    assert_not_empty "$THEME_PROMPT" "minimal theme sets THEME_PROMPT"
    assert_not_empty "$THEME_HEADER" "minimal theme sets THEME_HEADER"
}

test_apply_theme_noop_without_tty() {
    # Reset all theme vars
    THEME_PROMPT="" THEME_HEADER=""
    # apply_theme should no-op since stdout is not a TTY
    apply_theme "default"
    assert_eq "$THEME_PROMPT" "" "apply_theme is a no-op without a TTY"
}

test_all_themes_in_available_list() {
    local expected=("default" "ocean" "forest" "sunset" "minimal")
    for theme in "${expected[@]}"; do
        local found=false
        for available in "${SHELLIA_AVAILABLE_THEMES[@]}"; do
            [[ "$available" == "$theme" ]] && found=true
        done
        if $found; then
            _pass "theme '${theme}' is in SHELLIA_AVAILABLE_THEMES"
        else
            _fail "theme '${theme}' is in SHELLIA_AVAILABLE_THEMES"
        fi
    done
}

test_themes_produce_different_colors() {
    theme_default
    local default_prompt="$THEME_PROMPT"

    theme_ocean
    local ocean_prompt="$THEME_PROMPT"

    theme_forest
    local forest_prompt="$THEME_PROMPT"

    if [[ "$default_prompt" != "$ocean_prompt" || "$default_prompt" != "$forest_prompt" ]]; then
        _pass "different themes produce different color values"
    else
        _fail "different themes produce different color values" "all themes had same THEME_PROMPT"
    fi
}
