#!/bin/bash
# ============================================================================
# Hermes Agent Windows Portable Builder (cross-build from macOS/Linux)
# ============================================================================
# Downloads the Windows embeddable Python package and builds a self-contained
# portable zip that can be extracted and run on any Windows 10+ x64 machine.
#
# Requirements:
#   - macOS or Linux with curl, unzip, pip (host Python 3.11+)
#   - Internet access (downloads ~25MB Python embeddable package)
#
# Usage:
#   ./packaging/windows/build-portable.sh
#
# Output:
#   dist/hermes-agent-<version>-windows-x64-portable.zip
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PYTHON_VERSION="3.11.9"
PYTHON_SHORT="311"

# Parse version from pyproject.toml
VERSION=$(grep '^version' "$PROJECT_ROOT/pyproject.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')

# Directories
BUILD_DIR="$PROJECT_ROOT/dist/windows-build"
INSTALL_DIR="$BUILD_DIR/hermes-agent"
OUTPUT="$PROJECT_ROOT/dist/hermes-agent-${VERSION}-windows-x64-portable.zip"

# Python embeddable package URL
PYTHON_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-embed-amd64.zip"
PIP_URL="https://bootstrap.pypa.io/get-pip.py"

echo "============================================"
echo " Hermes Agent Windows Portable Builder"
echo " Version: $VERSION"
echo " Python:  $PYTHON_VERSION (embeddable)"
echo " Target:  Windows x64"
echo "============================================"
echo ""

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$INSTALL_DIR"

# --- Step 1: Download Windows Python embeddable ---
echo "[1/7] Downloading Python $PYTHON_VERSION embeddable for Windows..."

PYTHON_ZIP="$BUILD_DIR/python-embed.zip"
curl -fSL "$PYTHON_URL" -o "$PYTHON_ZIP"
unzip -q "$PYTHON_ZIP" -d "$INSTALL_DIR/python"

echo "  Downloaded and extracted."

# --- Step 2: Enable pip in embeddable Python ---
echo "[2/7] Enabling pip support..."

# The embeddable distribution has import restrictions via python3XX._pth file.
# We need to uncomment 'import site' and add Lib/site-packages.
PTH_FILE="$INSTALL_DIR/python/python${PYTHON_SHORT}._pth"
if [ -f "$PTH_FILE" ]; then
    # Uncomment 'import site' line and add site-packages
    sed -i.bak 's/^#import site/import site/' "$PTH_FILE"
    echo "Lib/site-packages" >> "$PTH_FILE"
    rm -f "${PTH_FILE}.bak"
fi

# Download get-pip.py
curl -fSL "$PIP_URL" -o "$BUILD_DIR/get-pip.py"

echo "  pip support enabled."

# --- Step 3: Install packages using uv with Windows target platform ---
echo "[3/7] Installing hermes-agent and dependencies..."

SITE_PACKAGES="$INSTALL_DIR/python/Lib/site-packages"
mkdir -p "$SITE_PACKAGES"

# Use uv pip install with --target and --python-platform for cross-platform install.
# Downloads Windows x64 wheels for binary packages.
# Note: mistral and voice extras excluded — no Windows wheels available
uv pip install \
    --target "$SITE_PACKAGES" \
    --python-platform x86_64-pc-windows-msvc \
    --python-version "3.11" \
    "$PROJECT_ROOT[messaging,cron,cli,mcp,honcho,acp,bedrock,dingtalk,feishu,google,homeassistant,sms,slack,tts-premium,web]"

echo "  Dependencies installed."

# --- Step 4: Copy bundled assets ---
echo "[4/7] Copying bundled skills and assets..."

cp -R "$PROJECT_ROOT/skills" "$INSTALL_DIR/skills"
cp -R "$PROJECT_ROOT/optional-skills" "$INSTALL_DIR/optional-skills"

# --- Step 5: Create wrapper scripts ---
echo "[5/7] Creating CLI wrappers..."

# hermes.cmd (for CMD)
cat > "$INSTALL_DIR/hermes.cmd" << 'CMD'
@echo off
chcp 65001 >nul 2>&1
set "PYTHONHOME=%~dp0python"
set "PYTHONPATH=%~dp0python\Lib\site-packages"
set "PYTHONIOENCODING=utf-8"
set "HERMES_BUNDLED_SKILLS=%~dp0skills"
set "HERMES_OPTIONAL_SKILLS=%~dp0optional-skills"
"%~dp0python\python.exe" -c "import sys,ctypes;k=ctypes.windll.kernel32;k.SetConsoleMode(k.GetStdHandle(-11),7);sys.argv[0]='hermes';from hermes_cli.main import main;main()" %*
CMD

# hermes-agent.cmd
cat > "$INSTALL_DIR/hermes-agent.cmd" << 'CMD'
@echo off
chcp 65001 >nul 2>&1
set "PYTHONHOME=%~dp0python"
set "PYTHONPATH=%~dp0python\Lib\site-packages"
set "PYTHONIOENCODING=utf-8"
set "HERMES_BUNDLED_SKILLS=%~dp0skills"
set "HERMES_OPTIONAL_SKILLS=%~dp0optional-skills"
"%~dp0python\python.exe" -c "import sys,ctypes;k=ctypes.windll.kernel32;k.SetConsoleMode(k.GetStdHandle(-11),7);sys.argv[0]='hermes-agent';from run_agent import main;main()" %*
CMD

# hermes.ps1 (for PowerShell)
cat > "$INSTALL_DIR/hermes.ps1" << 'PS1'
$env:PYTHONHOME = "$PSScriptRoot\python"
$env:PYTHONPATH = "$PSScriptRoot\python\Lib\site-packages"
$env:PYTHONIOENCODING = "utf-8"
$env:HERMES_BUNDLED_SKILLS = "$PSScriptRoot\skills"
$env:HERMES_OPTIONAL_SKILLS = "$PSScriptRoot\optional-skills"
& "$PSScriptRoot\python\python.exe" -c "import sys,ctypes;k=ctypes.windll.kernel32;k.SetConsoleMode(k.GetStdHandle(-11),7);sys.argv[0]='hermes';from hermes_cli.main import main;main()" @args
PS1

# --- Step 6: Create setup helper ---
echo "[6/7] Creating setup helper..."

cat > "$INSTALL_DIR/INSTALL.txt" << 'TXT'
Hermes Agent - Windows Portable
================================

Quick Start:
1. Extract this zip to any folder (e.g. C:\hermes-agent\)
2. Open Command Prompt or PowerShell in that folder
3. Run: hermes.cmd setup
4. Run: hermes.cmd

To add to PATH permanently (optional):
1. Open Settings > System > About > Advanced system settings
2. Click "Environment Variables"
3. Under "User variables", edit "Path"
4. Add the folder where you extracted hermes-agent

Gateway (messaging platforms):
   hermes.cmd gateway setup
   hermes.cmd gateway start
TXT

# Pre-configure defaults in .env template
cat > "$INSTALL_DIR/default.env" << 'ENV'
API_SERVER_ENABLED=true
API_SERVER_PORT=8643
GATEWAY_ALLOW_ALL_USERS=true
API_SERVER_KEY=123123
ENV

# Pre-configure default config.yaml (browser cdp_url for graphical Chrome)
cat > "$INSTALL_DIR/default-config.yaml" << 'YAML'
browser:
  cdp_url: "http://localhost:9222"
YAML

# Create a quick-start batch file that seeds .env before setup
cat > "$INSTALL_DIR/setup.cmd" << 'CMD'
@echo off
echo.
echo  Hermes Agent Setup
echo  ===================
echo.

:: Create HERMES_HOME and seed .env defaults if not exists
if not defined HERMES_HOME set "HERMES_HOME=%LOCALAPPDATA%\hermes"
if not exist "%HERMES_HOME%" mkdir "%HERMES_HOME%"
if not exist "%HERMES_HOME%\sessions" mkdir "%HERMES_HOME%\sessions"
if not exist "%HERMES_HOME%\cron" mkdir "%HERMES_HOME%\cron"
if not exist "%HERMES_HOME%\memories" mkdir "%HERMES_HOME%\memories"
if not exist "%HERMES_HOME%\skills" mkdir "%HERMES_HOME%\skills"
if not exist "%HERMES_HOME%\logs" mkdir "%HERMES_HOME%\logs"

:: Seed .env with defaults (only if .env doesn't exist yet)
if not exist "%HERMES_HOME%\.env" (
    copy "%~dp0default.env" "%HERMES_HOME%\.env" >nul
)

:: Seed config.yaml with browser.cdp_url (only if config.yaml doesn't exist yet)
if not exist "%HERMES_HOME%\config.yaml" (
    copy "%~dp0default-config.yaml" "%HERMES_HOME%\config.yaml" >nul
)

:: Register scheduled task so hermes gateway starts at every login
schtasks /create /tn "HermesGateway" /tr "\"%~dp0hermes.cmd\" gateway start" /sc ONLOGON /ru "%USERNAME%" /f /rl LIMITED >nul 2>&1
echo   Registered HermesGateway as a login startup task.

:: Start gateway now
start "" /b "%~dp0hermes.cmd" gateway start

call "%~dp0hermes.cmd" setup
pause
CMD

# --- Step 7: Create zip archive ---
echo "[7/7] Creating portable zip..."

rm -f "$OUTPUT"
(cd "$BUILD_DIR" && zip -qr "$OUTPUT" "hermes-agent/")

ZIP_SIZE=$(du -h "$OUTPUT" | cut -f1)

# Cleanup
rm -rf "$BUILD_DIR"

echo ""
echo "============================================"
echo " Build complete!"
echo " Output: $OUTPUT"
echo " Size:   $ZIP_SIZE"
echo "============================================"
echo ""
echo "Usage on Windows:"
echo "  1. Extract the zip"
echo "  2. Run: hermes.cmd setup"
echo "  3. Run: hermes.cmd"
echo ""
