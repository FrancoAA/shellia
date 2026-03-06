#!/usr/bin/env bash
# Theme system for shellia

# Theme color roles:
#   THEME_PROMPT    - the "shellia>" prompt text
#   THEME_HEADER    - startup banner
#   THEME_ACCENT    - model name, highlights
#   THEME_CMD       - command display ($ command)
#   THEME_SUCCESS   - success indicators
#   THEME_WARN      - warnings, dangerous command alerts
#   THEME_ERROR     - errors
#   THEME_INFO      - informational messages
#   THEME_MUTED     - dim/secondary text
#   THEME_SEPARATOR - visual separators

# Available themes
SHELLIA_AVAILABLE_THEMES=("default" "ocean" "forest" "sunset" "minimal")

# Apply a theme by name
apply_theme() {
    local theme="${1:-default}"

    # Skip if no terminal
    [[ -t 1 ]] || return 0

    case "$theme" in
        default)
            theme_default
            ;;
        ocean)
            theme_ocean
            ;;
        forest)
            theme_forest
            ;;
        sunset)
            theme_sunset
            ;;
        minimal)
            theme_minimal
            ;;
        *)
            log_warn "Unknown theme '${theme}', using default."
            theme_default
            ;;
    esac
}

# --- Theme definitions ---

theme_default() {
    THEME_PROMPT='\033[1;36m'       # Bold cyan
    THEME_HEADER='\033[1;35m'       # Bold magenta
    THEME_ACCENT='\033[0;36m'       # Cyan
    THEME_CMD='\033[0;33m'          # Yellow
    THEME_SUCCESS='\033[0;32m'      # Green
    THEME_WARN='\033[0;33m'         # Yellow
    THEME_ERROR='\033[0;31m'        # Red
    THEME_INFO='\033[0;34m'         # Blue
    THEME_MUTED='\033[2m'           # Dim
    THEME_SEPARATOR='\033[2;36m'    # Dim cyan
}

theme_ocean() {
    THEME_PROMPT='\033[1;34m'       # Bold blue
    THEME_HEADER='\033[1;36m'       # Bold cyan
    THEME_ACCENT='\033[0;96m'       # Light cyan
    THEME_CMD='\033[0;94m'          # Light blue
    THEME_SUCCESS='\033[0;32m'      # Green
    THEME_WARN='\033[0;33m'         # Yellow
    THEME_ERROR='\033[0;31m'        # Red
    THEME_INFO='\033[0;96m'         # Light cyan
    THEME_MUTED='\033[2;34m'        # Dim blue
    THEME_SEPARATOR='\033[2;36m'    # Dim cyan
}

theme_forest() {
    THEME_PROMPT='\033[1;32m'       # Bold green
    THEME_HEADER='\033[1;33m'       # Bold yellow
    THEME_ACCENT='\033[0;92m'       # Light green
    THEME_CMD='\033[0;93m'          # Light yellow
    THEME_SUCCESS='\033[0;92m'      # Light green
    THEME_WARN='\033[0;33m'         # Yellow
    THEME_ERROR='\033[0;31m'        # Red
    THEME_INFO='\033[0;32m'         # Green
    THEME_MUTED='\033[2;32m'        # Dim green
    THEME_SEPARATOR='\033[2;33m'    # Dim yellow
}

theme_sunset() {
    THEME_PROMPT='\033[1;91m'       # Bold light red
    THEME_HEADER='\033[1;33m'       # Bold yellow
    THEME_ACCENT='\033[0;35m'       # Magenta
    THEME_CMD='\033[0;91m'          # Light red
    THEME_SUCCESS='\033[0;33m'      # Yellow
    THEME_WARN='\033[0;91m'         # Light red
    THEME_ERROR='\033[0;31m'        # Red
    THEME_INFO='\033[0;35m'         # Magenta
    THEME_MUTED='\033[2;33m'        # Dim yellow
    THEME_SEPARATOR='\033[2;35m'    # Dim magenta
}

theme_minimal() {
    THEME_PROMPT='\033[1m'          # Just bold
    THEME_HEADER='\033[1m'          # Just bold
    THEME_ACCENT='\033[0m'          # Normal
    THEME_CMD='\033[2m'             # Dim
    THEME_SUCCESS='\033[0;32m'      # Green
    THEME_WARN='\033[0;33m'         # Yellow
    THEME_ERROR='\033[0;31m'        # Red
    THEME_INFO='\033[0m'            # Normal
    THEME_MUTED='\033[2m'           # Dim
    THEME_SEPARATOR='\033[2m'       # Dim
}

# List available themes with preview
list_themes() {
    local current="${SHELLIA_THEME:-default}"
    echo "Available themes:"
    for t in "${SHELLIA_AVAILABLE_THEMES[@]}"; do
        # Temporarily apply to show preview
        apply_theme "$t"
        local marker=""
        [[ "$t" == "$current" ]] && marker=" (active)"
        echo -e "  ${THEME_PROMPT}${t}${NC}${marker}  ${THEME_MUTED}-${NC} ${THEME_HEADER}shellia${NC} ${THEME_ACCENT}v${SHELLIA_VERSION}${NC} ${THEME_SEPARATOR}|${NC} ${THEME_CMD}\$ ls -la${NC}"
    done
    # Re-apply current theme
    apply_theme "$current"
}
