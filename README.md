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

## 开发验证

`scripts/test.sh` 和 `scripts/check.sh` 默认在后台运行。纯逻辑、存储、协调器和后台渲染照常验证；会显示窗口、弹出面板或唤起终端的用例输出 `SKIP`，不计为通过。过滤词、实机开关和预览目录都不会自动开启前台验收。

需要操作原生窗口或核对真实材质时，选择不影响前台使用的时机，显式开启：

```sh
scripts/test.sh --list                         # 标出需要前台的用例
MEOWMAC_UI_TESTS=1 scripts/test.sh UI.Reset     # 可见原生容器验收
MEOWMAC_UI_TESTS=1 scripts/check.sh             # 完整离线验收，包含可见 UI
```

完整离线验收仍是交付检查的一部分。后台检查通过时，应同时记录未执行的前台用例。安装脚本使用后台启动，不自动展示验证窗口。

## 数据来源

- 系统状态来自 macOS 公开接口。清理记录来自 Mole 的 `mo history --json`。
- AI 额度来自 CodexBarCLI。需要安装 CodexBar；MeowMac 不启动 CodexBar.app。
- 网络检测通过相邻目录中的 TunCanary 库运行。MeowMac 读取 TunCanary 设置，状态文件保存在自己的应用数据目录。

本项目使用 MIT 许可。

渠道 logo 来自 CodexBar 的 ProviderIcon SVG 资源，分别是 Anthropic、OpenAI、DeepSeek 和 OpenCode 的商标。商标权归各自所有者。
