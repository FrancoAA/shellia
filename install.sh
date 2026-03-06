#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing shellia..."

# Check dependencies
for cmd in jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' is required. Please install it first."
        exit 1
    fi
done

# Create install directory
mkdir -p "$INSTALL_DIR"

# Create wrapper script
cat > "${INSTALL_DIR}/shellia" <<EOF
#!/usr/bin/env bash
exec "${SCRIPT_DIR}/shellia" "\$@"
EOF
chmod +x "${INSTALL_DIR}/shellia"

echo "Installed to ${INSTALL_DIR}/shellia"

# Check if ~/.local/bin is already in PATH
if echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
    echo ""
    echo "shellia is ready! Run 'shellia init' to configure your API provider."
    exit 0
fi

# Detect shell and find the right RC file
detect_rc_file() {
    local shell_name
    shell_name=$(basename "${SHELL:-/bin/bash}")

    case "$shell_name" in
        zsh)
            echo "${HOME}/.zshrc"
            ;;
        bash)
            if [[ "$(uname -s)" == "Darwin" ]]; then
                # macOS: prefer .bash_profile if it exists, else .bashrc
                if [[ -f "${HOME}/.bash_profile" ]]; then
                    echo "${HOME}/.bash_profile"
                else
                    echo "${HOME}/.bashrc"
                fi
            else
                echo "${HOME}/.bashrc"
            fi
            ;;
        *)
            echo "${HOME}/.profile"
            ;;
    esac
}

RC_FILE=$(detect_rc_file)

echo ""
echo "${INSTALL_DIR} is not in your PATH."
read -rp "Add it to ${RC_FILE}? [Y/n]: " add_to_path
add_to_path="${add_to_path:-Y}"

if [[ "$add_to_path" =~ ^[Yy]$ ]]; then
    echo '' >> "$RC_FILE"
    echo '# Added by shellia installer' >> "$RC_FILE"
    echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "$RC_FILE"
    echo "Added to ${RC_FILE}"
    echo ""
    echo "Run 'source ${RC_FILE}' or restart your terminal, then:"
    echo "  shellia init"
else
    echo ""
    echo "Add this to your shell config manually:"
    echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    echo ""
    echo "Then run 'shellia init' to configure your API provider."
fi
