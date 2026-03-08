#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SHELLIA_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/shellia"
SHELLIA_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/shellia"

echo "Uninstalling shellia..."

# Remove wrapper script
if [[ -f "${INSTALL_DIR}/shellia" ]]; then
    rm -f "${INSTALL_DIR}/shellia"
    echo "Removed ${INSTALL_DIR}/shellia"
else
    echo "No wrapper found at ${INSTALL_DIR}/shellia"
fi

# Remove cloned source (from curl install)
if [[ -d "${SHELLIA_DATA_DIR}/src" ]]; then
    rm -rf "${SHELLIA_DATA_DIR}/src"
    echo "Removed ${SHELLIA_DATA_DIR}/src"
    # Remove data dir if empty
    rmdir "$SHELLIA_DATA_DIR" 2>/dev/null || true
fi

# Ask about config
if [[ -d "$SHELLIA_CONFIG_DIR" ]]; then
    echo ""
    echo "Configuration directory found at ${SHELLIA_CONFIG_DIR}"
    echo "Contains: config, profiles, dangerous_commands, system_prompt"
    # Source utils for portable read (if available)
    if [[ -f "${SHELLIA_DATA_DIR}/src/lib/utils.sh" ]]; then
        source "${SHELLIA_DATA_DIR}/src/lib/utils.sh"
        _read_prompt "Remove configuration? [y/N]: " remove_config
    elif [[ -n "${ZSH_VERSION:-}" ]]; then
        read -r "?Remove configuration? [y/N]: " remove_config
    else
        read -rp "Remove configuration? [y/N]: " remove_config
    fi
    if [[ "$remove_config" =~ ^[Yy]$ ]]; then
        rm -rf "$SHELLIA_CONFIG_DIR"
        echo "Removed ${SHELLIA_CONFIG_DIR}"
    else
        echo "Keeping ${SHELLIA_CONFIG_DIR}"
    fi
fi

echo ""
echo "shellia has been uninstalled."
echo ""
echo "Note: If the installer added a PATH line to your shell config,"
echo "you may want to remove it manually:"
echo "  # Added by shellia installer"
echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
