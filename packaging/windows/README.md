# Windows Installer Build

Builds a self-contained Windows installer for Hermes Agent.

## Prerequisites

- Windows 10+ (64-bit)
- [uv](https://docs.astral.sh/uv/) — Python package manager
- [Inno Setup 6](https://jrsoftware.org/isdl.php) — optional, for .exe installer

## Build

```powershell
# Portable zip only (no Inno Setup needed)
.\packaging\windows\build-installer.ps1 -PortableOnly

# Full installer (.exe)
.\packaging\windows\build-installer.ps1

# With code signing
.\packaging\windows\build-installer.ps1 -Sign
```

## Output

| File | Description |
|------|-------------|
| `dist\hermes-agent-<ver>-windows-x64-portable.zip` | Portable — extract and run `hermes.cmd` |
| `dist\hermes-agent-<ver>-windows-x64-setup.exe` | Installer — adds to PATH, creates Start Menu entry |

## What the installer does

1. Installs to `%LOCALAPPDATA%\hermes-agent\`
2. Adds install directory to user PATH
3. Sets `HERMES_HOME=%LOCALAPPDATA%\hermes`
4. Creates `%LOCALAPPDATA%\hermes\{sessions,cron,memories,skills,logs}`
5. Adds Start Menu shortcut

## Uninstall

Use "Add or Remove Programs" or run the uninstaller from Start Menu. User data (`%LOCALAPPDATA%\hermes\`) is preserved.

## Portable usage

Extract the zip anywhere and run:

```cmd
hermes.cmd setup
hermes.cmd
```

Or in PowerShell:

```powershell
.\hermes.ps1 setup
.\hermes.ps1
```
