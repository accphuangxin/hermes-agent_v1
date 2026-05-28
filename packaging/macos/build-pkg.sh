#!/bin/bash
# ============================================================================
# Hermes Agent macOS .pkg Builder
# ============================================================================
# Builds a fully self-contained macOS installer package (.pkg) that bundles
# a complete Python runtime + all dependencies. No external Python needed.
# After installation, `hermes setup` works immediately.
#
# Requirements:
#   - macOS with Xcode Command Line Tools
#   - uv (https://docs.astral.sh/uv/)
#
# Usage:
#   ./packaging/macos/build-pkg.sh
#   ./packaging/macos/build-pkg.sh --sign "Developer ID Installer: Your Name"
#
# Output:
#   dist/hermes-agent-<version>-macos-<arch>.pkg
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PYTHON_VERSION="3.11"
ARCH="$(uname -m)"  # arm64 or x86_64

# Parse version from pyproject.toml
VERSION=$(grep '^version' "$PROJECT_ROOT/pyproject.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')

# Directories
BUILD_DIR="$PROJECT_ROOT/dist/macos-build"
INSTALL_PREFIX="/usr/local/hermes-agent"
PKG_ROOT="$BUILD_DIR/pkg-root"
SCRIPTS_DIR="$BUILD_DIR/scripts"
OUTPUT="$PROJECT_ROOT/dist/hermes-agent-${VERSION}-macos-${ARCH}.pkg"

# Signing identity (optional)
SIGN_IDENTITY=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --sign)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --python)
            PYTHON_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: build-pkg.sh [--sign \"Developer ID Installer: ...\"] [--python 3.11]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "============================================"
echo " Hermes Agent macOS Package Builder"
echo " Version: $VERSION"
echo " Arch:    $ARCH"
echo " Python:  $PYTHON_VERSION"
echo "============================================"
echo ""

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$PKG_ROOT$INSTALL_PREFIX" "$SCRIPTS_DIR"

# --- Step 1: Copy full Python runtime ---
echo "[1/6] Bundling complete Python ${PYTHON_VERSION} runtime..."

# Ensure uv has the requested Python version
uv python install "$PYTHON_VERSION" 2>/dev/null || true

# Find the uv-managed Python installation
PYTHON_BIN="$(uv python find "$PYTHON_VERSION")"
PYTHON_HOME="$(dirname "$PYTHON_BIN")/.."
PYTHON_HOME="$(cd "$PYTHON_HOME" && pwd)"

echo "  Source: $PYTHON_HOME"

# Copy the entire Python installation into the package.
# Use -RL to dereference symlinks — ensures no broken symlinks after pkg install.
cp -RL "$PYTHON_HOME" "$PKG_ROOT$INSTALL_PREFIX/python"

# Remove the externally-managed marker so we can install packages into it
rm -f "$PKG_ROOT$INSTALL_PREFIX/python/lib/python${PYTHON_VERSION}/EXTERNALLY-MANAGED"

# Verify the bundled python works
"$PKG_ROOT$INSTALL_PREFIX/python/bin/python3" --version

# --- Step 2: Install hermes-agent and dependencies ---
echo "[2/6] Installing hermes-agent and dependencies..."

# Install with all extras for maximum compatibility (voice, bedrock, mistral, etc.)
# Exclude only 'dev' and 'matrix' (matrix has broken native deps on macOS)
uv pip install \
    --python "$PKG_ROOT$INSTALL_PREFIX/python/bin/python3" \
    "$PROJECT_ROOT[anthropic,messaging,cron,cli,pty,mcp,honcho,acp,bedrock,dingtalk,feishu,google,homeassistant,sms,modal,daytona,slack,tts-premium,web]"

# --- Step 3: Copy bundled assets ---
echo "[3/6] Copying bundled skills and assets..."

cp -R "$PROJECT_ROOT/skills" "$PKG_ROOT$INSTALL_PREFIX/skills"
cp -R "$PROJECT_ROOT/optional-skills" "$PKG_ROOT$INSTALL_PREFIX/optional-skills"

# --- Step 4: Create wrapper scripts in /usr/local/bin ---
echo "[4/6] Creating CLI wrappers..."

mkdir -p "$PKG_ROOT/usr/local/bin"

_make_wrapper() {
    local cmd="$1" module="$2" func="$3"
    cat > "$PKG_ROOT/usr/local/bin/$cmd" << 'WRAPPER_HEAD'
#!/bin/bash
export PYTHONHOME="/usr/local/hermes-agent/python"
export HERMES_BUNDLED_SKILLS="/usr/local/hermes-agent/skills"
export HERMES_OPTIONAL_SKILLS="/usr/local/hermes-agent/optional-skills"

# Auto-fix ~/.hermes ownership on first run (handles root-owned dirs from pkg install)
HERMES_DIR="${HERMES_HOME:-$HOME/.hermes}"
if [ -d "$HERMES_DIR" ] && [ ! -w "$HERMES_DIR" ]; then
    echo "Fixing ~/.hermes permissions (one-time)..."
    sudo chown -R "$(whoami)" "$HERMES_DIR"
fi
WRAPPER_HEAD
    cat >> "$PKG_ROOT/usr/local/bin/$cmd" << EOF
exec /usr/local/hermes-agent/python/bin/python${PYTHON_VERSION} -c "import sys; sys.argv[0] = '${cmd}'; from ${module} import ${func}; ${func}()" "\$@"
EOF
    chmod +x "$PKG_ROOT/usr/local/bin/$cmd"
}

_make_wrapper hermes       hermes_cli.main   main
_make_wrapper hermes-agent run_agent         main
_make_wrapper hermes-acp   acp_adapter.entry main

# --- Step 5: Create postinstall script ---
echo "[5/6] Creating installer scripts..."

cat > "$SCRIPTS_DIR/postinstall" << 'EOF'
#!/bin/bash
# Post-installation script — runs as root during .pkg install.
# Must create ~/.hermes owned by the actual user, not root.

# In macOS .pkg installs, the console owner is the real user.
REAL_USER="$(stat -f '%Su' /dev/console 2>/dev/null)"

# Fallbacks
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    REAL_USER="$(logname 2>/dev/null || echo "")"
fi
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    # Last resort: first user with UID >= 500 (skip system accounts)
    REAL_USER="$(dscl . list /Users UniqueID | awk '$2 >= 500 {print $1; exit}')"
fi

# If we truly can't find a user, skip — hermes will create dirs on first run
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    exit 0
fi

REAL_HOME="$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
if [ -z "$REAL_HOME" ]; then
    REAL_HOME="/Users/$REAL_USER"
fi

HERMES_HOME="$REAL_HOME/.hermes"

# Create directory structure as root, then chown everything to the real user
mkdir -p "$HERMES_HOME/sessions" \
         "$HERMES_HOME/cron" \
         "$HERMES_HOME/memories" \
         "$HERMES_HOME/skills" \
         "$HERMES_HOME/logs"

# Copy bundled skills to user directory (don't overwrite existing)
if [ -d /usr/local/hermes-agent/skills ]; then
    cp -n /usr/local/hermes-agent/skills/*.md "$HERMES_HOME/skills/" 2>/dev/null || true
fi

# Pre-configure defaults
ENV_FILE="$HERMES_HOME/.env"
touch "$ENV_FILE"
grep -q "API_SERVER_ENABLED" "$ENV_FILE" || echo 'API_SERVER_ENABLED=true' >> "$ENV_FILE"
grep -q "API_SERVER_PORT" "$ENV_FILE" || echo 'API_SERVER_PORT=8643' >> "$ENV_FILE"
grep -q "GATEWAY_ALLOW_ALL_USERS" "$ENV_FILE" || echo 'GATEWAY_ALLOW_ALL_USERS=true' >> "$ENV_FILE"
grep -q "API_SERVER_KEY" "$ENV_FILE" || echo 'API_SERVER_KEY=123123' >> "$ENV_FILE"

# Seed config.yaml with browser.cdp_url so api_server uses the graphical Chrome
CONFIG_FILE="$HERMES_HOME/config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << 'YAML'
browser:
  cdp_url: "http://localhost:9222"
YAML
elif ! grep -q "cdp_url" "$CONFIG_FILE"; then
    # Append browser section if not present
    printf '\nbrowser:\n  cdp_url: "http://localhost:9222"\n' >> "$CONFIG_FILE"
fi

# Fix ownership — this is the critical step
chown -R "$REAL_USER" "$HERMES_HOME"

# Install LaunchAgent so hermes gateway (api_server) starts at login
LAUNCH_AGENTS_DIR="$REAL_HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.nousresearch.hermes-gateway.plist"
mkdir -p "$LAUNCH_AGENTS_DIR"
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nousresearch.hermes-gateway</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/hermes</string>
        <string>gateway</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$REAL_HOME/.hermes/logs/gateway.log</string>
    <key>StandardErrorPath</key>
    <string>$REAL_HOME/.hermes/logs/gateway-error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HERMES_HOME</key>
        <string>$HERMES_HOME</string>
        <key>HERMES_BUNDLED_SKILLS</key>
        <string>/usr/local/hermes-agent/skills</string>
        <key>HERMES_OPTIONAL_SKILLS</key>
        <string>/usr/local/hermes-agent/optional-skills</string>
        <key>PYTHONHOME</key>
        <string>/usr/local/hermes-agent/python</string>
    </dict>
    <key>WorkingDirectory</key>
    <string>$REAL_HOME</string>
</dict>
</plist>
PLIST

chown "$REAL_USER" "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

# Load the LaunchAgent immediately (starts gateway now, not just at next login)
su - "$REAL_USER" -c "launchctl load '$PLIST_PATH'" 2>/dev/null || true

echo ""
echo "  ☤ Hermes Agent installed successfully!"
echo ""
echo "  Get started:"
echo "    hermes setup    # Configure your LLM provider"
echo "    hermes          # Start chatting"
echo ""
exit 0
EOF
chmod +x "$SCRIPTS_DIR/postinstall"

# --- Step 6: Build .pkg ---
echo "[6/6] Building .pkg installer..."

# Build the component package
pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "com.nousresearch.hermes-agent" \
    --version "$VERSION" \
    --install-location "/" \
    "$BUILD_DIR/hermes-agent-component.pkg"

# Create distribution XML for productbuild
cat > "$BUILD_DIR/distribution.xml" << DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Hermes Agent</title>
    <welcome file="welcome.html"/>
    <license file="license.txt"/>
    <options customize="never" require-scripts="false"/>
    <domains enable_localSystem="true"/>
    <choices-outline>
        <line choice="default">
            <line choice="com.nousresearch.hermes-agent"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="com.nousresearch.hermes-agent" visible="false">
        <pkg-ref id="com.nousresearch.hermes-agent"/>
    </choice>
    <pkg-ref id="com.nousresearch.hermes-agent"
             version="$VERSION"
             onConclusion="none">hermes-agent-component.pkg</pkg-ref>
</installer-gui-script>
DIST

# Create welcome HTML
cat > "$BUILD_DIR/welcome.html" << 'HTML'
<html>
<body>
<h1>Hermes Agent ☤</h1>
<p>The self-improving AI agent built by <b>Nous Research</b>.</p>
<p>This installer will place Hermes Agent in <code>/usr/local/hermes-agent/</code>
and create the <code>hermes</code> command in <code>/usr/local/bin/</code>.</p>
<p>After installation, open Terminal and run:</p>
<pre>hermes setup</pre>
</body>
</html>
HTML

# Copy license
cp "$PROJECT_ROOT/LICENSE" "$BUILD_DIR/license.txt"

# Build the product archive
PRODUCTBUILD_ARGS=(
    --distribution "$BUILD_DIR/distribution.xml"
    --resources "$BUILD_DIR"
    --package-path "$BUILD_DIR"
    --version "$VERSION"
)

if [ -n "$SIGN_IDENTITY" ]; then
    PRODUCTBUILD_ARGS+=(--sign "$SIGN_IDENTITY")
    echo "  Signing with: $SIGN_IDENTITY"
fi

PRODUCTBUILD_ARGS+=("$OUTPUT")

productbuild "${PRODUCTBUILD_ARGS[@]}"

# Cleanup intermediate files
rm -rf "$BUILD_DIR"

echo ""
echo "============================================"
echo " Build complete!"
echo " Output: $OUTPUT"
echo " Size:   $(du -h "$OUTPUT" | cut -f1)"
echo "============================================"
echo ""

if [ -z "$SIGN_IDENTITY" ]; then
    echo "⚠  Package is unsigned. Users will need to right-click → Open to install."
    echo "   To sign: ./build-pkg.sh --sign \"Developer ID Installer: Your Name (TEAM_ID)\""
    echo ""
fi
