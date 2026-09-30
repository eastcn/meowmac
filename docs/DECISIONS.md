# MeowMac 决策记录

本文记录 2026-09-29 用户与规划者逐条讨论后确认的决策。编号在讨论中确定，后续引用保持不变，所以不连续。

本文受保护：只有用户能改。执行者发现实现和本文冲突时，按 `AGENTS.md` 的规则跳过并记录。

## 定位与路线

**D1　自建应用。** MeowMac 是个人优先的开源项目，MIT 许可，按作者自己的需求开发，不接功能请求。

否决的方案：

- fork RunCat Neo：它运行在 App Sandbox 里，不能起子进程，也读不到系统网络状态。
- 以 MacTools 为宿主写插件：它的功能覆盖面广，但每项都做得比较浅；编译需要 Xcode；第三方插件只能由同一 Team ID 签名的宿主加载；插件 ABI 从 v2 变到 v7。
- 合并 Mole 的代码：Mole 是 GPL-3.0，而且它在 M5 上读不到 CPU 温度和风扇转速。

**D2　技术栈。** SwiftPM + Command Line Tools，不安装 Xcode。最低 macOS 14。ad-hoc 签名，安装到 `~/Applications/MeowMac.app`。2026-09-30 补充：Command Line Tools 升级到带 macOS 26 SDK 的版本，以便使用液态玻璃（D33）。升级由用户执行。

**D3　仓库与标识。** 仓库在 `~/projects/eastcn/meowmac`，bundle id 为 `io.github.eastcn.meowmac`。先只建本地仓库，推送到 GitHub 的 `eastcn/meowmac` 需要用户单独授权。TunCanary 先移到 `~/projects/eastcn/tuncanary`，MeowMac 用 `.package(path: "../tuncanary")` 依赖它。

否决的方案：在 TunCanary 仓库里扩展；把 TunCanary 源码搬进本仓库；用 git URL 依赖 TunCanary（本地改动要先推送、打标签，才能在 MeowMac 里用上）。

**D4　语言与名称。** 界面、注释和文档用中文，提交信息的格式与 TunCanary 一致。应用不叫 RunCat，也不使用 RunCat 的图标和猫的形象。

## 数据源

**D5　网络。** 通过 SwiftPM 依赖 TunCanary 的库。v0.1 直接嵌入它的 `MonitorController` 和 `PopoverRootView`。2026-09-30 修改：网络页改由 MeowMac 自己画，读取 `AppModel` 的公开数据，不再嵌入 `PopoverRootView`，见 D35。TunCanary 保持公开，进入维护模式，今后作为网络检测引擎，新的网络检测能力写进 TunCanary。

**D6　额度。** 调用 CodexBarCLI，只用 DeepSeek、Codex、Claude 和 OpenCodeGo 这 4 个渠道。CodexBar.app 不再常驻。计费数据来自 `cost --breakdown --json`，只有 Claude 和 Codex 有。

**D7　额度历史。** MeowMac 自己定时采样，写成 JSONL，放在 `~/Library/Application Support/MeowMac/`，保留 90 天。v0.2 时一次性导入 CodexBar 已有的历史文件。

**D8　刷新策略。**

- 每 30 分钟刷新一次全部渠道，不区分是否活跃。
- 每 60 秒调用一次 `sessions --json-v2`。某个渠道的会话从 active 全部变成 idle 后，5 分钟后补刷这个渠道一次。
- 支持手动刷新。距上次刷新不到 1 分钟的请求合并成一次。
- 打开面板只显示缓存和数据时间，不触发刷新。
- 休眠时暂停；唤醒后如果距上次刷新超过 30 分钟，立即补刷一次。

**D9　系统采集。** v0.1 只用公开接口：CPU、内存压力、swap、磁盘、网络、整机功耗、电池温度和 `thermalState`。精确的 SoC 温度和风扇转速要走私有接口，放到 v0.3 的实验卡片，读不到时显示“不可用”。

**D10　清理。** 面板显示磁盘空间和 `mo history --json` 的清理记录。点清理后打开终端运行 `mo clean`，由用户在终端里预览和确认。应用不在后台清理。

## 猫与健康

**D11　速度只表示负载。** 负载取 CPU 使用率和内存压力换算值中较大的一个，映射到每帧 0.5 秒（空闲）到 0.05 秒（满载）。内存用压力，不用已用百分比，因为 macOS 总会把内存用满。

**D12　健康状态用形态表示，分三档。**

| 档位 | 形态 |
| --- | --- |
| 正常 | 奔跑，速度随负载变化 |
| 提醒 | 照常奔跑，整只猫变成橙色（2026-09-30 确定） |
| 严重 | 停下来，不再按负载调速 |

同一时间只显示最严重的一档。v0.1 用代码画的剪影，三档靠颜色区分；正式美术放到 v0.2。

**D13　信号归档。**

- 严重：DNS 泄漏或 TUN 失效、站点探测连续失败、出口 IP 所在地区超出允许范围。
- 提醒：任一额度窗口剩余低于 20%、磁盘剩余低于 10%、`thermalState` 达到 serious 或以上、数据源失效、D14 的能耗异常。

**D14　能耗诊断。** 放在 v0.1 的系统页。温度只是症状，进程引起的能耗异常才是根源。

原因层：

- 进程能耗排行前 5 名。每 60 秒用 `top` 采样一次，显示进程名、CPU 和能耗影响分。
- 失控进程：单个进程占用超过一个核心的 90%，持续 10 分钟。
- 休眠被阻止：某个进程持有阻止休眠的断言超过 2 小时。
- 内存压力处于 warn 或以上，持续 10 分钟。

症状层分两级：

- 建议降温：`thermalState` 为 fair 并持续 5 分钟。v0.3 起，风扇转速超过最大值的 80% 并持续 5 分钟也算。只在总览条上加一个标记，猫的形态不变。
- 已降频：`thermalState` 达到 serious 或以上，归入提醒档。

判定只看 CPU。能耗影响分是 Apple 的启发式分数，没有单位，只用来排序和展示。

发现异常时只提示“建议用 AI 诊断”。只有温度偏高、没找到异常进程时，提示“温度偏高，未发现异常进程，建议降温或用 AI 诊断”。不提供结束进程的按钮，也不跳转到 AI 工具。

例子：`BTLEServer` 卡在忙循环里，持续占满一个核心。整机 CPU 只高了几个百分点，只看猫的速度发现不了；失控进程规则能直接指出它。

**D14a　技术验证。** v0.1 验证 `proc_pid_rusage` 的 `ri_energy_nj` 能否读到其他用户和 root 的进程。结果只记录，由规划者决定是否用它替代 `top` 子进程。

**D15　判定规则的位置。** 健康判定规则写在统一的本机配置里，不随猫配置切换。

## 面板与配置

**D16　面板结构。** 顶部是总览条，中间是系统、额度和网络三个标签页，底部固定放刷新、清理和设置。容器用弹出面板，不用 `NSMenu`，因为 `NSMenu` 一点击就关闭，放不了多步交互。

**D17　默认标签页。** 打开面板时显示问题最严重的那一类。都正常时显示上次看的那一页。

**D18　总览条。**

- 第 1 行：当前档位、最严重的问题、降温标记。点击问题跳到对应标签页。一切正常时显示“一切正常”和最近刷新时间。
- 第 2 行：CPU、内存压力、一个可选的额度窗口、网络状态灯。额度窗口默认是 Claude 的 5 小时窗口，默认显示剩余，也可以改成已用。2026-09-30 修改：4 块都显示数字。内存显示已用百分比和已用/总量，压力只用横线颜色表示；网络显示实时下行和上行速率，结论只用横线颜色表示。细则见 `docs/design/SPEC.md`。

**D19　布局以卡片为单位。** 卡片用代码实现，遵守同一个 `Card` 协议。标签页只是卡片的分组，由配置文件决定。卡片内部显示什么，由卡片自己的设置决定。

**D20　猫配置。** 一只猫是一个目录，例如 `年糕.cat/`，包含菜单栏帧图、面板样式、布局、总览条和卡片显示选项。不包含健康判定规则、刷新策略、数据源配置和凭据，所以可以放进 git，也可以分享。同一时间只有一只猫生效。

**D21　可插拔接口。** 额度源和采集项通过统一接口接入。机场订阅额度会用到它。

**D30　联动图。** 系统页常驻一张联动图：CPU 负载、整机功耗和电池温度共用一条时间轴，背景用 `thermalState` 着色。时间范围可选 15 分钟或 1 小时。用途是观察高负载时功耗和温度怎么变化，不依赖异常触发。v0.3 再加上 SoC 温度和风扇转速。

## 阶段与执行

**D22　阶段。**

| 阶段 | 内容 |
| --- | --- |
| v0.1 能用 | 临时猫图、三个标签页、写死的默认布局、嵌入 TunCanary、能耗诊断、联动图 |
| v0.2 年糕 | 猫配置体系、自定义帧图、导入 CodexBar 历史 |
| v0.3 传感器 | 精确温度和风扇转速、风扇触发的降温提示 |
| v0.4 机场 | 机场订阅额度卡片 |

**D23　通知与 TunCanary 独立应用。** v0.1 不新增通知，保留嵌入的 TunCanary 原有的网络告警。v0.1 验收通过后，退出独立运行的 TunCanary，关闭它的开机启动。DNS guard 守护进程继续保留。

**D24　交付物。** `AGENTS.md`、`CLAUDE.md`、本文件、`docs/ROADMAP.md`、每个阶段一个 relay 目录（`plan.md` 和 `result.md`），以及 `scripts/check.sh`。

**D25　验收。** 执行者是 Codex 或 Sonnet 5.5。每个阶段结束都由用户验收，通过后才能进入下一阶段。达不到验收标准时，执行者不能降低标准。

**D31　AI 模块。** 以后有其他用户时，再考虑内置 AI 诊断模块。

## 设计（2026-09-30 确定）

v0.1 第一轮交付的界面不合格，原因是规划里没有视觉要求。这一节补上。

**D32　设计稿是实现依据。** 设计稿源文件在 `docs/design/mockups/`，规范在 `docs/design/SPEC.md`。界面实现以这两份为准，和设计稿不一致的地方视为缺陷。按 D39 定出终稿后，这两份会更新为终稿版本。风格参照 CodexBar：分节平铺，细进度条，次要信息靠右，用灰色。

**D33　液态玻璃。** 用 macOS 26 SDK 编译，使用系统的液态玻璃材质；macOS 14～15 退回普通材质。代码用 `#available(macOS 26, *)` 区分。否决的方案：保持 SDK 14.4，用 `NSVisualEffectView` 模拟，因为效果和系统里的其他软件不一致。

**D34　额度页的内容。** 在窗口和花费之外，增加账号和套餐、节奏预估（进度条上的刻度和文字）、可重置次数、用量趋势（长周期折线，5 小时窗口画成每个窗口的峰值柱状图）和本地存储。本地存储只显示大小和“在访达中显示”，不提供删除，理由同 D10。

**D35　网络页自己画。** 读取 TunCanary `AppModel` 的公开数据，用 MeowMac 的视觉重新呈现，不修改 TunCanary。

**D36　菜单栏猫。** v0.1 用设计稿里的矢量版；v0.2 做猫配置时再细致打磨，或者换成 AI 绘制的素材。负载不低于 0.7 时加三道速度线。

**D37　渠道 logo。** 用 CodexBar 仓库里的 `ProviderIcon-*.svg`。logo 是各公司的商标，公开发布时在 README 里注明。

**D38　设置入口。** 底部“设置”按钮弹出菜单，v0.1 不做设置窗口，阈值等配置通过“打开配置文件…”修改。

**D39　先对比设计稿，再单独实现。** 用同一份设计需求（`docs/design/BRIEF.md`）让 GPT 另出一版视觉稿，和现有画布对比，挑一版或取两边的长处合成终稿，再交给一个执行者实现。现有画布和 `SPEC.md` 在终稿确定前只是候选方案之一。否决的方案（同日早些时候的 D39）：同一份 plan 由 GPT 和 Opus 各实现一版再比较，因为实现成本翻倍，而分歧主要出在设计上，应该在设计阶段解决。

## 附录：已验证的事实

以下事实在 2026-09-29 于作者的 MacBook Pro（Apple M5，16 GB，macOS 26.6.2）上验证。

**CodexBarCLI 0.60.5**，路径 `/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI`。

- CodexBar.app 退出后仍能正常工作。
- `usage --provider <p> --json` 的耗时：Claude 12～14 秒，Codex 4～6 秒，DeepSeek 1 秒，OpenCodeGo 1～2 秒。每次都实时请求，不读缓存。
- 返回一个数组，每项有 `provider`、`source` 和 `usage`。`usage` 里有 `primary`、`secondary`、`tertiary` 三个窗口，每个窗口有 `usedPercent`、`windowMinutes`、`resetsAt` 和 `resetDescription`，字段可能缺失。有的渠道还有 `pace`，含 `summary`、`willLastToReset` 等字段。Codex 另有 `credits` 和 `usage.providerCost`。
- `dashboard` 一次返回所有已启用的渠道，单个渠道失败会作为这一行的错误返回；支持 `--timeout` 和 `--output`。耗时未测。
- `cost --provider <claude|codex> --days N --breakdown --json` 读本地日志，耗时不到 1 秒。返回 `daily[]`，每项有 `date`、各类 token 数、`totalCost` 和 `modelBreakdowns`。Codex 另有 `projects[]`。
- `sessions --json-v2` 耗时约 1 秒。每个会话有 `provider`、`state`（`active` 或 `idle`）、`lastActivityAt`、`startedAt`、`pid` 等字段。只覆盖 Claude Code、Codex、pi 和 OMP。
- CodexBar.app 的额度历史在 `~/Library/Application Support/com.steipete.codexbar/history/<provider>.json`，由应用写入，CLI 不能导出。

**系统数据。**

- `top -l 2 -s 1 -o power -stats pid,command,cpu,power` 不需要 sudo，能列出所有用户的进程，包括 `WindowServer`。进程名最多显示 16 个字符。
- IORegistry 的 `AppleSmartBattery` 不需要 sudo 就能读：`Temperature` 是百分之一摄氏度（3051 表示 30.51°C）；`PowerTelemetryData` 里有 `SystemLoad` 等功耗字段，单位待核对。
- SDK 头文件里 `rusage_info_v6` 有 `ri_energy_nj` 字段。
- `mo status --json` 在 M5 上的 `cpu_temp` 和 `fan_speed` 都是 0。
- `mo clean` 是交互式终端程序，没有 JSON 输出。需要 sudo 时会停下来等按键。

**TunCanary。**

- `MonitorController` 和 `AppModel` 是 `public` 的。界面层只公开了整个弹窗 `PopoverRootView`，7 个卡片视图是 `internal`。
- `AppModel` 的 `overall`、`local`、`siteHistory`、`egressResults`、`egressState`、`lastCheckedAt` 是 `public` 的（2026-09-30 核实）。这些类型内部的字段能否在 TunCanary 外面读到，实现时再逐个核对。
- `SettingsStore()` 在当前 bundle id 不是 TunCanary 时，使用 `UserDefaults(suiteName: "io.github.eastcn.tuncanary")`，所以嵌入后读到的是用户现有的 TunCanary 设置。
