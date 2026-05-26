# Hermes Agent 打包指南

## macOS 打包（.pkg 安装包）

**环境要求：**
- macOS + Xcode Command Line Tools
- [uv](https://docs.astral.sh/uv/)

**基本打包：**
```bash
./packaging/macos/build-pkg.sh
```

**可选参数：**
```bash
# 指定 Python 版本（默认 3.11）
./packaging/macos/build-pkg.sh --python 3.12

# 签名（需要 Apple Developer ID）
./packaging/macos/build-pkg.sh --sign "Developer ID Installer: Your Name (TEAM_ID)"

# 同时指定签名和 Python 版本
./packaging/macos/build-pkg.sh --python 3.11 --sign "Developer ID Installer: Your Name (TEAM_ID)"
```

**输出：**
```
dist/hermes-agent-<version>-macos-<arch>.pkg
# 示例：dist/hermes-agent-0.14.0-macos-arm64.pkg
```

> 未签名的包安装时需右键 → 打开，绕过 Gatekeeper。

**卸载：**
```bash
sudo ./packaging/macos/uninstall.sh
```

---

## Windows 打包

### 方式一：便携版 zip（可在 macOS/Linux 上交叉构建）

**环境要求：**
- macOS 或 Linux
- curl、unzip、Python 3.11+（宿主机）
- 需要联网（下载约 25MB Python embeddable 包）

```bash
./packaging/windows/build-portable.sh
```

**输出：**
```
dist/hermes-agent-<version>-windows-x64-portable.zip
# 示例：dist/hermes-agent-0.14.0-windows-x64-portable.zip
```

**Windows 上使用便携版：**
```cmd
# 解压后在目录中运行：
hermes.cmd setup
hermes.cmd
```
```powershell
# 或用 PowerShell：
.\hermes.ps1 setup
.\hermes.ps1
```

---

### 方式二：完整安装包 .exe（需在 Windows 上构建）

**环境要求：**
- Windows 10+ (64-bit)
- PowerShell 5.1+
- [uv](https://docs.astral.sh/uv/)
- [Inno Setup 6+](https://jrsoftware.org/isdl.php)（仅构建 .exe 时需要）

```powershell
# 构建 .exe 安装包（需要 Inno Setup）
.\packaging\windows\build-installer.ps1

# 仅构建便携版 zip（无需 Inno Setup）
.\packaging\windows\build-installer.ps1 -PortableOnly

# 构建并签名（需要代码签名证书）
.\packaging\windows\build-installer.ps1 -Sign

# 指定 Python 版本（默认 3.11）
.\packaging\windows\build-installer.ps1 -PythonVersion 3.12
```

**输出：**
```
dist\hermes-agent-<version>-windows-x64-portable.zip
dist\hermes-agent-<version>-windows-x64-setup.exe
```

**安装包行为：**
- 安装到 `%LOCALAPPDATA%\hermes-agent\`
- 自动添加到用户 PATH
- 设置 `HERMES_HOME=%LOCALAPPDATA%\hermes`
- 创建开始菜单快捷方式

**卸载：** 通过"添加或删除程序"，用户数据 `%LOCALAPPDATA%\hermes\` 会被保留。
