#!/bin/bash
# ============================================================================
# Hermes Agent macOS Uninstaller
# ============================================================================
# Removes the installed Hermes Agent package. Does NOT delete user data
# (~/.hermes/) — that is left for the user to remove manually.
#
# Usage:
#   sudo ./uninstall.sh
# ============================================================================

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root. Run with: sudo $0"
    exit 1
fi

echo "Removing Hermes Agent..."

# Remove installation directory
rm -rf /usr/local/hermes-agent

# Remove CLI symlinks
rm -f /usr/local/bin/hermes
rm -f /usr/local/bin/hermes-agent
rm -f /usr/local/bin/hermes-acp

# Forget the package receipt
pkgutil --forget com.nousresearch.hermes-agent 2>/dev/null || true

echo ""
echo "  ☤ Hermes Agent has been uninstalled."
echo ""
echo "  User data (~/.hermes/) was preserved."
echo "  To remove it: rm -rf ~/.hermes"
echo ""
