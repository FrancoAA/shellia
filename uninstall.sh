#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SHELLIA_HOME="${HOME}/.shellia"

echo "Uninstalling shellia..."

# Remove wrapper script
if [[ -f "${INSTALL_DIR}/shellia" ]]; then
    rm -f "${INSTALL_DIR}/shellia"
    echo "Removed ${INSTALL_DIR}/shellia"
else
    echo "No wrapper found at ${INSTALL_DIR}/shellia"
fi

# Remove cloned source (from curl install)
if [[ -d "${SHELLIA_HOME}/src" ]]; then
    rm -rf "${SHELLIA_HOME}/src"
    echo "Removed ${SHELLIA_HOME}/src"
fi

# Ask about config
if [[ -d "$SHELLIA_HOME" ]]; then
    echo ""
    echo "Configuration directory found at ${SHELLIA_HOME}"
    echo "Contains: config, dangerous_commands, system_prompt"
    read -rp "Remove configuration? [y/N]: " remove_config
    if [[ "$remove_config" =~ ^[Yy]$ ]]; then
        rm -rf "$SHELLIA_HOME"
        echo "Removed ${SHELLIA_HOME}"
    else
        echo "Keeping ${SHELLIA_HOME}"
    fi
fi

echo ""
echo "shellia has been uninstalled."
echo ""
echo "Note: If the installer added a PATH line to your shell config,"
echo "you may want to remove it manually:"
echo "  # Added by shellia installer"
echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
