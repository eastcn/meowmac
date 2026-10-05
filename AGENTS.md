# MeowMac

MeowMac 是一个 macOS 菜单栏应用。菜单栏里有一只猫：跑得快慢表示整机负载，形态表示健康状态。点开是一个面板，汇总系统、AI 额度和网络三类状态。

本仓库是个人优先的开源项目，按作者自己的需求开发。本文件是仓库的权威规则，Codex 直接读取，Claude 通过 `CLAUDE.md` 引用。

## 开始工作前必读

按顺序读：

1. 本文件。
2. `docs/DECISIONS.md`：已定的产品和技术决策。实现必须符合它。
3. `docs/ROADMAP.md`：阶段划分。
4. 做界面相关的条目时：`docs/design/SPEC.md` 和 `docs/design/mockups/` 里的设计稿。
5. 当前阶段的 relay 目录：`docs/plans/<YYYY-MM-DD>-<slug>/plan.md` 和同目录的 `result.md`。`plan.md` 是当前任务的唯一状态源。

relay 目录固定为 `docs/plans/<YYYY-MM-DD>-<slug>/`。

## 受保护的文件

`AGENTS.md`、`CLAUDE.md` 和 `docs/DECISIONS.md` 只有用户能改。执行者发现实现和它们冲突时，跳过相关条目，把冲突写进 `result.md`，不要改这些文件，也不要按自己的理解绕过。

`scripts/check.sh` 会把这三个文件和 git 标签 `plan-baseline` 比对，有差异就失败。只有用户批准修改后，才能移动这个标签。

## 技术栈与目录

- SwiftPM + Command Line Tools，不使用 Xcode 工程。CLT 要带 macOS 26 SDK（D33），版本以 `swift --version` 和 `xcrun --show-sdk-version` 的实测结果为准。macOS 26 才有的 API 必须用 `#available(macOS 26, *)` 包裹，并给 macOS 14～15 留退路。`Package.swift` 的 `swift-tools-version` 保持 5.10，不切换到 Swift 6 语言模式。
- 最低系统 macOS 14。
- 不引入第三方依赖。唯一的外部包是本地的 TunCanary：`.package(path: "../tuncanary")`，即 `~/projects/eastcn/tuncanary`。
- 测试用自带的测试运行器 `MeowMacSelfTest`，写法参照 TunCanary 的 `TunCanarySelfTest`。CLT 没有 XCTest。
- 应用用 ad-hoc 签名，bundle id 为 `io.github.eastcn.meowmac`，安装到 `~/Applications/MeowMac.app`。

分层（`import` 方向只能从上往下）：

| target | 职责 |
| --- | --- |
| `MeowMac` | 程序入口，组装各层 |
| `MeowMacUI` | 状态栏、猫、面板、卡片、图表 |
| `MeowMacQuota` | 调用 CodexBarCLI、解析、额度历史 |
| `MeowMacSystem` | 系统采集和能耗诊断的数据来源 |
| `MeowMacCore` | 纯逻辑：模型、配置、健康判定、速度映射、刷新调度、解析器 |

`MeowMacCore` 除了读写配置文件和历史文件，不做其他 I/O。

## 验证命令

```sh
scripts/check.sh      # 受保护文件、依赖、编译、全部离线自测。每次提交前必须通过
scripts/test.sh       # 只跑自测，可加过滤词，例如 scripts/test.sh Core.Health
scripts/build-app.sh  # 生成 build/MeowMac.app
scripts/install.sh    # 安装到 ~/Applications/MeowMac.app 并启动
```

实机采集的用例默认不跑，用 `MEOWMAC_LIVE=1 scripts/test.sh <过滤词>` 显式开启。

## 必须停下来的情况

遇到下面任何一种，跳过相关条目，写进 `result.md`，不要自己决定：

- 实现和 `docs/DECISIONS.md` 冲突。
- 需要引入第三方依赖。
- 需要修改 TunCanary 仓库，包括把某个类型改成 `public`。
- 需要 `sudo`、修改系统设置，或者往仓库外写文件。例外：应用运行时写 `~/Library/Application Support/MeowMac/`，以及 `scripts/install.sh` 安装应用。
- 验收标准达不到。不要降低标准，不要放宽测试断言。

## 禁止的操作

- 执行真正的清理，例如不带 `--dry-run` 的 `mo clean`。
- 结束任何进程。唯一的例外：`scripts/install.sh` 可以让正在运行的 MeowMac 自己正常退出，例如 `osascript -e 'quit app id "io.github.eastcn.meowmac"'`，不能用 `kill`。
- 启动或修改 CodexBar.app 及其配置。只调用 `/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI`。例外（2026-10-05 用户批准）：应用的“额度源设置”可以在用户点保存后，通过 CodexBarCLI 的 `config enable`、`config disable` 和 `config set-api-key --stdin` 写 CodexBar 配置。开发和测试只能用 `CODEXBAR_CONFIG` 指向 `build/` 下的临时配置文件，不能写真实配置；真实配置的写入只由用户在实机验收时操作。
- 调试时 Claude 额度的实时调用每 5 分钟最多 1 次，避免触发频率限制。
- 开启开机启动，或者退出、修改用户正在运行的 TunCanary。
- 推送到远程仓库。推送需要用户在对话里明确同意。

## 公开内容的红线

本仓库将来会公开，写进仓库的一切都会公开。

- 不写入任何与用户雇主或其内部 VPN 客户端相关的内容，包括名称、路径、网段和 DNS 地址，脱敏后也不行。
- 不提交真实环境采集的数据。测试夹具只用虚构数据，不能有真实邮箱、IP、账号和组织名。
- 使用真实数据的截图只放在 `build/acceptance/`（已被 git 忽略），不提交。提交进仓库的预览图只用合成数据渲染。
- 验收需要的实机原值，例如 CPU、功耗、进程名和休眠断言，也写到 `build/acceptance/`。result 里只写对比结论和偏差，例如“两边的整机功耗相差不到 5%”。

## 提交

- 作者固定为 `east <hefengeast@gmail.com>`，已在仓库级配置，不要改全局 git 配置。
- 提交信息用英文 Conventional Commits，例如 `feat: add quota history store`。
- 一个改动一个提交，重构不要和功能混在一起。
- 本机代理会断开 `github.com:22`。推送时走 443 端口：`GIT_SSH_COMMAND="ssh -p 443" git push ssh://git@ssh.github.com:443/eastcn/meowmac.git main`。

## 写作

界面文案、代码注释和文档用简体中文，遵循 zh-tech-writing 规范：短句，平实，给出事实和数字。
