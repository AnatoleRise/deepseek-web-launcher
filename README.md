# DeepSeek Web

一款面向 macOS 的第三方 DeepSeek Harness 菜单栏启动器。

它将本地运行的 DeepSeek Harness Web 服务收纳到菜单栏中，提供环境检测、分步安装、服务启停、版本检查和日志查看等能力。界面使用 macOS 原生 SwiftUI 与 Liquid Glass，适合希望通过图形界面使用 `dsh web` 的用户。

> [!IMPORTANT]
> 本项目是非官方第三方启动器，与 DeepSeek 官方没有隶属或授权关系。本项目不修改 DeepSeek Harness 的代码，仅围绕官方版本提供 macOS 菜单栏启动与管理能力。DeepSeek Harness 的代码、功能与许可证以其[官方仓库](https://github.com/deepseek-ai/deepseek-harness)为准。

## 主要功能

- 常驻 macOS 菜单栏，不显示 Dock 图标。
- 启动前检测 Node.js、npm 和全局 DeepSeek Harness。
- 提供分步骤安装向导，由用户分别决定是否安装 Node.js 和 Harness。
- 支持识别官方 Node 安装包、Homebrew、nvm、Volta、asdf 和 fnm 等常见环境。
- 启动、停止并监控本地 `dsh web` 服务。
- 首次启动应用时打开 Web 界面，菜单内重启服务时保持静默。
- 检查并更新全局安装的 `@deepseek-ai/dsh`。
- 使用统一日志记录检测、安装、更新和运行输出。
- 采用 macOS 原生 Liquid Glass 菜单界面，自动适配深色和浅色模式。

## 工作方式

DeepSeek Web 负责检测并调用用户环境中已有的 Node.js、npm 和 DeepSeek Harness。

应用启动后会依次执行以下检查：

1. 检查兼容的 Node.js。
2. 检查 npm。
3. 检查全局安装的 `dsh`。
4. 环境完整后启动 `dsh web`，默认地址为 <http://127.0.0.1:3080>。

如果缺少依赖，应用会显示安装向导。用户可以打开 Node.js 官方安装页、在已安装 Homebrew 时选择安装 Node 24、确认执行 Harness 全局安装命令，或者退出应用。依赖未完成时不会启动 3080 服务。

Harness 的全局安装命令为：

```bash
npm install -g @deepseek-ai/dsh
```

官方提供的 `npx @deepseek-ai/dsh web` 适合一次性运行，本启动器不把它作为持久安装方式。

## 系统要求

- macOS 26 或更高版本。
- Apple Silicon（ARM64）Mac。
- 安装依赖及检查更新时需要网络连接。
- DeepSeek Harness 当前要求 Node.js `^22.19.0 || >=24.0.0`，具体要求请以[官方项目](https://github.com/deepseek-ai/deepseek-harness)为准。

## 安装

请前往 [GitHub Releases 最新版本页面](https://github.com/AnatoleRise/deepseek-web-launcher/releases/latest) 下载适用于当前系统的安装包及 SHA-256 校验文件。

打开 DMG，将 `DeepSeek Web.app` 拖入 `Applications` 文件夹。

### 免证书测试版

当前测试版没有 Apple Developer ID 签名和公证，macOS Gatekeeper 可能阻止首次启动。请先核对 Release 页面提供的 SHA-256，并确认下载来源可信。

确认无误后执行：

```bash
xattr -dr com.apple.quarantine "/Applications/DeepSeek Web.app"
open "/Applications/DeepSeek Web.app"
```

该命令只移除 DeepSeek Web 的下载隔离标记，不会关闭系统 Gatekeeper。不要对来源不明的应用执行此操作。

更完整的步骤请参阅[安装说明](./Docs/安装说明.txt)。

## 首次启动

### 缺少 Node.js

安装向导会展示 Node.js 的版本要求，并提供：

- 打开 [Node.js 官方下载页](https://nodejs.org/en/download)。
- 检测到 Homebrew 时，由用户确认执行 `brew install node@24`。
- 重新检测或退出应用。

启动器不会自动安装 Homebrew，也不会自动使用 `sudo`。

### 缺少 DeepSeek Harness

Node.js 与 npm 通过检测后，用户可以：

- 点击按钮执行 `npm install -g @deepseek-ai/dsh`。
- 复制命令并在终端中手动安装。
- 安装完成后重新检测。
- 不安装并退出应用。

## 菜单栏操作

- **启动服务 / 停止服务**：控制当前应用管理的 `dsh web` 子进程。
- **打开 DeepSeek Web 界面**：在默认浏览器中访问本地 Web 服务。
- **检查更新**：查询 npm registry 中的最新 dsh 版本。
- **查看日志**：打开 `~/Library/Logs/dsh-web-bar.log`。
- **退出 DeepSeek Web**：停止受管服务并退出菜单栏应用。

## 从源码构建

构建要求：

- Apple Silicon Mac。
- macOS 26+。
- Apple Command Line Tools。
- 当前脚本默认使用 `MacOSX26.5.sdk`。

执行：

```bash
chmod +x Scripts/build_dmg.sh
./Scripts/build_dmg.sh
```

构建脚本会先运行隔离环境检测测试，再生成：

```text
dist/DeepSeek-Web-1.1.0-macOS26-arm64.dmg
dist/DeepSeek-Web-1.1.0-macOS26-arm64.sha256
```

脚本还会检查应用架构、最低系统版本、临时签名和发行包内容。

## 项目结构

```text
.
├── Sources/DeepSeekWeb/     # 应用、环境检测、安装向导与菜单栏逻辑
├── Tests/                   # 隔离环境检测测试
├── Resources/               # 应用图标、菜单栏图标与图标集
├── Config/                  # macOS 应用配置
├── Scripts/                 # 构建与打包脚本
├── Docs/                    # 面向最终用户的中文文档
├── Tools/IconGeneration/    # 图标生成、预览与诊断工具
├── README.md                # 项目说明
└── LICENSE                  # MIT License
```

## 安全与隐私说明

- 安装 Harness 前会显示命令，并由用户主动确认。
- 不会自动执行 `sudo`，也不会自动修改 shell 配置。
- 启动器只管理由自身启动的 dsh 子进程。
- Harness 本身的联网、模型和数据处理行为不属于本启动器能力范围，请参考 DeepSeek Harness 官方说明。

## 上游项目

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
- [Node.js](https://nodejs.org/)

## 许可证

本项目采用 [MIT License](./LICENSE)。您可以自由使用、复制、修改和分发，但需要保留许可证与版权声明。

欢迎通过 Issues 提交启动器相关的问题和建议。
