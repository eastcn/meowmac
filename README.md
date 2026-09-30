# MeowMac

MeowMac 是一个 macOS 菜单栏应用，用猫的速度和形态显示整机负载与健康状态，并汇总系统、AI 额度和网络状态。

## 构建与安装

运行需要 macOS 14 或更新版本。构建需要带 macOS 26 SDK 的 Command Line Tools；SwiftPM 的 tools-version 保持 5.10。将 TunCanary 仓库放在本仓库的相邻目录 `../tuncanary`。

```sh
scripts/check.sh
scripts/build-app.sh
scripts/install.sh
```

应用安装到 `~/Applications/MeowMac.app`。安装脚本遇到正在运行的 MeowMac 时会退出；请先自行退出旧实例。

## 数据来源

- 系统状态来自 macOS 公开接口。清理记录来自 Mole 的 `mo history --json`。
- AI 额度来自 CodexBarCLI。需要安装 CodexBar；MeowMac 不启动 CodexBar.app。
- 网络检测通过相邻目录中的 TunCanary 库运行。MeowMac 读取 TunCanary 设置，状态文件保存在自己的应用数据目录。

本项目使用 MIT 许可。

渠道 logo 来自 CodexBar 的 ProviderIcon SVG 资源，分别是 Anthropic、OpenAI、DeepSeek 和 OpenCode 的商标。商标权归各自所有者。
