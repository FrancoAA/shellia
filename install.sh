#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/FrancoAA/shellia.git"
INSTALL_DIR="${HOME}/.local/bin"
SHELLIA_DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/shellia"
SHELLIA_SRC="${SHELLIA_DATA_DIR}/src"

echo "Installing shellia..."

# Check dependencies
for cmd in jq curl git; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' is required. Please install it first."
        exit 1
    fi
done

# Determine source directory
# If running from a cloned repo (install.sh exists alongside shellia), use that.
# If running via curl (piped), clone the repo.
SCRIPT_DIR=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -n "$SCRIPT_DIR" && -f "${SCRIPT_DIR}/shellia" ]]; then
    # Running from cloned repo
    SOURCE_DIR="$SCRIPT_DIR"
    echo "Using local source: ${SOURCE_DIR}"
else
    # Running via curl — clone the repo
    echo "Cloning shellia..."
    if [[ -d "$SHELLIA_SRC" ]]; then
        echo "Updating existing installation..."
        git -C "$SHELLIA_SRC" pull --quiet
    else
        mkdir -p "$SHELLIA_DATA_DIR"
        git clone --quiet "$REPO_URL" "$SHELLIA_SRC"
    fi
    SOURCE_DIR="$SHELLIA_SRC"
fi

# Create install directory
mkdir -p "$INSTALL_DIR"

# Create wrapper script that points to the source
cat > "${INSTALL_DIR}/shellia" <<EOF
#!/usr/bin/env bash
exec "${SOURCE_DIR}/shellia" "\$@"
EOF
chmod +x "${INSTALL_DIR}/shellia"

cat > "${INSTALL_DIR}/shia" <<EOF
#!/usr/bin/env bash
exec "${SOURCE_DIR}/shellia" "\$@"
EOF
chmod +x "${INSTALL_DIR}/shia"

echo "Installed to ${INSTALL_DIR}/shellia (alias: shia)"

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
