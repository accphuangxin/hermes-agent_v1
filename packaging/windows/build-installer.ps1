# ============================================================================
# Hermes Agent Windows Installer Builder
# ============================================================================
# Builds a fully self-contained Windows installer (.exe) using Inno Setup.
# Bundles a complete Python runtime + all dependencies. No external Python needed.
#
# Requirements:
#   - Windows 10+ with PowerShell 5.1+
#   - uv (https://docs.astral.sh/uv/)
#   - Inno Setup 6+ (https://jrsoftware.org/isinfo.php)
#     OR run with -PortableOnly to skip installer and produce a zip
#
# Usage:
#   .\build-installer.ps1                    # Build .exe installer (requires Inno Setup)
#   .\build-installer.ps1 -PortableOnly      # Build portable .zip only
#   .\build-installer.ps1 -Sign              # Sign with signtool (requires cert)
#
# Output:
#   dist\hermes-agent-<version>-windows-<arch>-setup.exe
#   dist\hermes-agent-<version>-windows-<arch>-portable.zip
# ============================================================================

param(
    [switch]$PortableOnly,
    [switch]$Sign,
    [string]$PythonVersion = "3.11",
    [string]$InnoSetupPath = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path "$ScriptDir\..\..").Path
$Arch = if ([System.Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }

# Parse version from pyproject.toml
$VersionLine = Get-Content "$ProjectRoot\pyproject.toml" | Where-Object { $_ -match '^version\s*=' } | Select-Object -First 1
$Version = ($VersionLine -replace '.*"(.+)".*', '$1')

# Directories
$BuildDir = "$ProjectRoot\dist\windows-build"
$InstallDir = "$BuildDir\hermes-agent"
$Output = "$ProjectRoot\dist\hermes-agent-$Version-windows-$Arch"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Hermes Agent Windows Installer Builder" -ForegroundColor Cyan
Write-Host " Version: $Version" -ForegroundColor Cyan
Write-Host " Arch:    $Arch" -ForegroundColor Cyan
Write-Host " Python:  $PythonVersion" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Clean previous build
if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# --- Step 1: Copy full Python runtime ---
Write-Host "[1/6] Bundling complete Python $PythonVersion runtime..." -ForegroundColor Yellow

# Ensure uv has the requested Python version
uv python install $PythonVersion 2>$null

# Find the uv-managed Python installation
$PythonBin = (uv python find $PythonVersion).Trim()
Write-Host "  Found:  $PythonBin"
# Windows layout: <install-dir>\python.exe  (one level up)
# Unix layout:    <install-dir>/bin/python   (two levels up)
$PythonBinDir = Split-Path -Parent $PythonBin
if ((Split-Path -Leaf $PythonBinDir) -eq 'bin') {
    $PythonHome = Split-Path -Parent $PythonBinDir
} else {
    $PythonHome = $PythonBinDir
}

Write-Host "  Source: $PythonHome"

# Copy the entire Python installation
Copy-Item -Recurse -Force $PythonHome "$InstallDir\python"

# Remove the externally-managed marker
$ExternallyManaged = "$InstallDir\python\Lib\python$PythonVersion\EXTERNALLY-MANAGED"
if (Test-Path $ExternallyManaged) { Remove-Item $ExternallyManaged }
# Also check standard Windows layout
Get-ChildItem "$InstallDir\python" -Recurse -Filter "EXTERNALLY-MANAGED" -ErrorAction SilentlyContinue | Remove-Item -Force

Write-Host "  Verifying Python..." -ForegroundColor Gray
& "$InstallDir\python\python.exe" --version
if ($LASTEXITCODE -ne 0) {
    # Try alternative path layout
    & "$InstallDir\python\bin\python.exe" --version
}

# Determine python executable path
if (Test-Path "$InstallDir\python\python.exe") {
    $PythonExe = "$InstallDir\python\python.exe"
    $PythonRelExe = "python\python.exe"
} elseif (Test-Path "$InstallDir\python\bin\python.exe") {
    $PythonExe = "$InstallDir\python\bin\python.exe"
    $PythonRelExe = "python\bin\python.exe"
} else {
    Write-Error "Cannot find python.exe in bundled Python installation"
    exit 1
}

# --- Step 2: Install hermes-agent and dependencies ---
Write-Host "[2/6] Installing hermes-agent and dependencies..." -ForegroundColor Yellow

uv pip install --python $PythonExe "$ProjectRoot[messaging,cron,mcp,honcho,acp,bedrock,dingtalk,feishu,google,homeassistant,sms,slack,tts-premium,web]"

# --- Step 3: Copy bundled assets ---
Write-Host "[3/6] Copying bundled skills and assets..." -ForegroundColor Yellow

Copy-Item -Recurse "$ProjectRoot\skills" "$InstallDir\skills"
Copy-Item -Recurse "$ProjectRoot\optional-skills" "$InstallDir\optional-skills"

# --- Step 4: Create CLI wrapper batch files ---
Write-Host "[4/6] Creating CLI wrappers..." -ForegroundColor Yellow

$Wrappers = @{
    "hermes"       = "hermes_cli.main", "main"
    "hermes-agent" = "run_agent", "main"
    "hermes-acp"   = "acp_adapter.entry", "main"
}

foreach ($cmd in $Wrappers.Keys) {
    $module = $Wrappers[$cmd][0]
    $func = $Wrappers[$cmd][1]

    # .cmd wrapper for CMD
    @"
@echo off
set "PYTHONHOME=%~dp0python"
set "HERMES_BUNDLED_SKILLS=%~dp0skills"
set "HERMES_OPTIONAL_SKILLS=%~dp0optional-skills"
"%~dp0$PythonRelExe" -c "import sys; sys.argv[0] = '$cmd'; from $module import $func; $func()" %*
"@ | Set-Content -Path "$InstallDir\$cmd.cmd" -Encoding ASCII

    # .ps1 wrapper for PowerShell
    @"
`$env:PYTHONHOME = "`$PSScriptRoot\python"
`$env:HERMES_BUNDLED_SKILLS = "`$PSScriptRoot\skills"
`$env:HERMES_OPTIONAL_SKILLS = "`$PSScriptRoot\optional-skills"
& "`$PSScriptRoot\$PythonRelExe" -c "import sys; sys.argv[0] = '$cmd'; from $module import $func; $func()" @args
"@ | Set-Content -Path "$InstallDir\$cmd.ps1" -Encoding UTF8
}

# --- Step 5: Skipped (portable zip not required) ---
Write-Host "[5/6] Skipped (zip packaging disabled)" -ForegroundColor Gray

# --- Step 6: Build Inno Setup installer ---
if (-not $PortableOnly) {
    Write-Host "[6/6] Building installer..." -ForegroundColor Yellow

    # Find Inno Setup compiler
    $IsccPaths = @(
        $InnoSetupPath,
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe"
    ) | Where-Object { $_ -ne "" }

    $Iscc = $null
    foreach ($path in $IsccPaths) {
        if (Test-Path $path) { $Iscc = $path; break }
    }

    if ($null -eq $Iscc) {
        Write-Host "  Inno Setup not found — skipping .exe installer" -ForegroundColor Yellow
        Write-Host "  Install from: https://jrsoftware.org/isdl.php" -ForegroundColor Yellow
        Write-Host "  Or use -PortableOnly to skip this step" -ForegroundColor Yellow
    } else {
        # Generate Inno Setup script
        $IssFile = "$BuildDir\hermes-agent.iss"
        @"
[Setup]
AppName=Hermes Agent
AppVersion=$Version
AppPublisher=Nous Research
AppPublisherURL=https://nousresearch.com
DefaultDirName={localappdata}\hermes-agent
DefaultGroupName=Hermes Agent
OutputDir=$ProjectRoot\dist
OutputBaseFilename=hermes-agent-$Version-windows-$Arch-setup
Compression=lzma2/ultra64
SolidCompression=yes
PrivilegesRequired=lowest
ChangesEnvironment=yes
SetupIconFile=$ProjectRoot\assets\icon.ico
UninstallDisplayIcon={app}\assets\icon.ico
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Files]
Source: "$InstallDir\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Hermes Agent"; Filename: "{cmd}"; Parameters: "/k ""{app}\hermes.cmd"""; WorkingDir: "{userdocs}"
Name: "{group}\Uninstall Hermes Agent"; Filename: "{uninstallexe}"

[Registry]
Root: HKCU; Subkey: "Environment"; ValueType: string; ValueName: "HERMES_HOME"; ValueData: "{%USERPROFILE%}\.hermes"; Flags: createvalueifdoesntexist uninsdeletevalue
Root: HKCU; Subkey: "Environment"; ValueType: string; ValueName: "HERMES_BUNDLED_SKILLS"; ValueData: "{app}\skills"; Flags: createvalueifdoesntexist uninsdeletevalue
Root: HKCU; Subkey: "Environment"; ValueType: string; ValueName: "HERMES_OPTIONAL_SKILLS"; ValueData: "{app}\optional-skills"; Flags: createvalueifdoesntexist uninsdeletevalue

[Run]
Filename: "{cmd}"; Parameters: "/c mkdir ""%USERPROFILE%\.hermes\sessions"" ""%USERPROFILE%\.hermes\cron"" ""%USERPROFILE%\.hermes\memories"" ""%USERPROFILE%\.hermes\skills"" ""%USERPROFILE%\.hermes\logs"""; Flags: runhidden
Filename: "{cmd}"; Parameters: "/c if not exist ""%USERPROFILE%\.hermes\config.yaml"" (echo browser:> ""%USERPROFILE%\.hermes\config.yaml"" && echo   cdp_url: ""http://localhost:9222"">> ""%USERPROFILE%\.hermes\config.yaml"")"; Flags: runhidden
Filename: "schtasks.exe"; Parameters: "/create /tn ""HermesGateway"" /tr ""{app}\hermes.cmd gateway start"" /sc ONLOGON /ru ""%USERNAME%"" /f /rl LIMITED"; Flags: runhidden
Filename: "schtasks.exe"; Parameters: "/run /tn ""HermesGateway"""; Flags: runhidden nowait
Filename: "{cmd}"; Parameters: "/k echo. & echo   Hermes Agent installed successfully! & echo. & echo   Run 'hermes setup' to configure your LLM provider. & echo. & pause"; Description: "Open terminal with instructions"; Flags: postinstall nowait

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
    Path: string;
    AppDir: string;
begin
    if CurStep = ssPostInstall then
    begin
        // Add to user PATH
        RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path);
        AppDir := ExpandConstant('{app}');
        if Pos(AppDir, Path) = 0 then
        begin
            if Path <> '' then
                Path := Path + ';';
            Path := Path + AppDir;
            RegWriteStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path);
        end;
    end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
    Path: string;
    AppDir: string;
    P: Integer;
begin
    if CurUninstallStep = usPostUninstall then
    begin
        // Remove from user PATH
        RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path);
        AppDir := ExpandConstant('{app}');
        P := Pos(AppDir, Path);
        if P > 0 then
        begin
            Delete(Path, P, Length(AppDir));
            if (P <= Length(Path)) and (Path[P] = ';') then
                Delete(Path, P, 1)
            else if (P > 1) and (Path[P-1] = ';') then
                Delete(Path, P-1, 1);
            RegWriteStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', Path);
        end;
        // Remove scheduled task
        Exec('schtasks.exe', '/delete /tn "HermesGateway" /f', '', SW_HIDE, ewWaitUntilTerminated, P);
    end;
end;
"@ | Set-Content -Path $IssFile -Encoding UTF8

        # Check if icon exists, if not remove the icon reference
        if (-not (Test-Path "$ProjectRoot\assets\icon.ico")) {
            (Get-Content $IssFile) -replace 'SetupIconFile=.*', '' -replace 'UninstallDisplayIcon=.*', '' | Set-Content $IssFile
        }

        & $Iscc $IssFile
        if ($LASTEXITCODE -eq 0) {
            $ExeOutput = "$ProjectRoot\dist\hermes-agent-$Version-windows-$Arch-setup.exe"
            if ($Sign -and (Get-Command signtool -ErrorAction SilentlyContinue)) {
                Write-Host "  Signing installer..." -ForegroundColor Gray
                signtool sign /tr http://timestamp.digicert.com /td sha256 /fd sha256 /a $ExeOutput
            }
            $ExeSize = "{0:N1} MB" -f ((Get-Item $ExeOutput).Length / 1MB)
            Write-Host "  Installer: $ExeOutput ($ExeSize)" -ForegroundColor Green
        }
    }
} else {
    Write-Host "[6/6] Skipped (portable-only mode)" -ForegroundColor Gray
}

# Cleanup build directory
Remove-Item -Recurse -Force $BuildDir

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " Build complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
