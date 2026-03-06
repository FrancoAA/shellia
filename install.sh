#!/usr/bin/env bash
set -euo pipefail

# Simple installer for bashia
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing bashia to ${INSTALL_DIR}..."

# Check dependencies
for cmd in jq curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' is required. Please install it first."
        exit 1
    fi
done

# Create bashia wrapper that points to the repo
cat > "${INSTALL_DIR}/bashia" <<EOF
#!/usr/bin/env bash
exec "${SCRIPT_DIR}/bashia" "\$@"
EOF

chmod +x "${INSTALL_DIR}/bashia"

echo "bashia installed successfully!"
echo ""
echo "Run 'bashia init' to configure your API provider."
