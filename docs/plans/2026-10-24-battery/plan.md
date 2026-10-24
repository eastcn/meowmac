# 电池与续航

公开记录说明：电池实测原值（容量 mAh、电压、电流、序列号以外的全部原始字段）只放在忽略的 `build/acceptance/`；本文只写方法、阈值、对比偏差和验收结论。序列号在任何地方都不记录。

- 格式：relay-plan v2
- 目标：系统页新增“电池”卡片，显示当前电量、供电和充放电状态、系统给出的预计时间、近 24 小时电量曲线和电池健康；没有电池的 Mac 不显示。
- 规划：Claude Opus 5.5
- 定稿：2026-10-24
- 复核：2026-10-24，第 2 轮规划
- 模式：delegate（用户 2026-10-24 指定）
- 执行宿主：Claude Code 子 Agent（每轮一个执行者，按条目的「执行者要求」选模型）
- 复审宿主：Claude Code 全新子 Agent，只读
- 执行规则：`~/.claude/skills/relay/references/execute.md`；本 plan 的例外：无
- 执行者自主权：宽松（见决策点 D9）
- 推荐执行者：强推理模型、高推理档位
- 轮次上限：4
- 用量上限：无
- 结果文档：`docs/plans/2026-10-24-battery/result.md`

## 总纲

- **开工前提**（规划者在启动前核对，不满足就不启动）：D6 已由用户确认（2026-10-24，设计稿已同步）；D44 已由用户批准，规划者写入 `docs/DECISIONS.md` 并提交，`plan-baseline` 已移到该提交。已满足（2026-10-24）：D44 写入 `1b2e437`，`plan-baseline` 已移到该提交。
- 范围：电池读数的采集与解析；近 24 小时电量历史（本地持久化）；系统页“电池”卡片和布局迁移；SPEC 与布局格式文档同步；安装和接电源状态下的实机验收。
- 不做：低电量提醒或任何新提醒规则；MeowMac 自行推算续航；读取或显示电池序列号；修改 TunCanary；充电控制（充电上限、优化充电的开关）；推送。
- 全部条目与轮次：
  - 第 1 轮：条目 1～3（采集与解析、24 小时电量历史、卡片和布局迁移）；
  - 第 2 轮：条目 4（安装和实机验收）。
- 整体验收：`scripts/check.sh` 通过；安装后接电源状态的卡片读数与 `pmset -g batt`、`system_profiler SPPowerDataType` 一致；历史文件按 5 分钟增长且只保留 24 小时；卡片与设计稿逐项一致；用户实机验收拔掉电源后的放电状态、充电状态和 24 小时曲线。

## 背景与已知事实

- 设计稿：`docs/design/mockups/battery.html`（用户 2026-10-24 定稿）。四个状态：使用电池、充电中、接电源未充电、刚启动记录不足。页面底部「口径」是实现规格。
- 现有采集：`Sources/MeowMacSystem/SystemCollector.swift:130` 的 `batteryMetrics()` 已经读 IORegistry `AppleSmartBattery`，只取 `Temperature` 和 `PowerTelemetryData.SystemLoad`；`BatteryMetrics` 在 `Sources/MeowMacCore/SystemMetrics.swift:56`。系统快照约每 2 秒采一次（`Sources/MeowMacUI/ApplicationCadence.swift`，第 1 轮复审 R7 更正）。
- 规划者 2026-10-24 在本机（macOS 26.6.2，接电源、未充电、电量 80%）实测，不需要 sudo 能读到：
  - 顶层：`ExternalConnected`、`IsCharging`、`FullyCharged`、`CurrentCapacity`（百分比）、`MaxCapacity`（系统口径的最大容量百分比，与“系统设置 › 电池”一致）、`AppleRawMaxCapacity`、`DesignCapacity`（mAh）、`CycleCount`、`DesignCycleCount9C`、`Voltage`（mV）、`Amperage`（mA，放电为负）、`AvgTimeToEmpty`、`AvgTimeToFull`（分钟）、`BatteryInstalled`。
  - 接电源未充电时 `AvgTimeToEmpty`、`AvgTimeToFull`、`TimeRemaining` 都是 65535，`Amperage` 为 0。
  - `AdapterDetails.Watts`：适配器额定功率。
  - 公开接口 `IOPSCopyPowerSourcesInfo` 的 `BatteryHealth` 返回 “Check Battery”，而 `system_profiler` 显示 “Condition: Normal”，两者矛盾，所以不使用这个字段。
  - “未充电”的原因（充电上限或优化充电）没有公开字段；`ChargerData.NotChargingReason` 是未文档化的位掩码，不解析。
- 现有可参照的写法：
  - 历史：`Sources/MeowMacCore/NetworkHistory.swift`（JSONL、24 小时保留 `retention`、坏行跳过、超大文件当作空，目录 `history/network`）、`Sources/MeowMacUI/NetworkHistoryRecorder.swift`（后台串行队列写盘，失败只记日志）。
  - 卡片：`Sources/MeowMacCore/PanelLayout.swift:14`（系统页功能块目录）、`PanelLayout.migrated`（第 172 行，`network.traffic`、`network.proxy` 的迁移先例）、`Sources/MeowMacUI/PanelView.swift:49`（`PanelCardRegistry`）、`Sources/MeowMacUI/SystemCards.swift`（`DiskCard` 第 231 行：局部量程、斜纹、悬停写法）。
  - 合成数据预览：`MEOWMAC_RENDER_DIR`（见 `Sources/MeowMacSelfTest/LayoutAcceptanceTests.swift:62`）。
  - 设计文档：`docs/design/SPEC.md`「系统页」、`docs/design/PANEL_LAYOUT_FORMAT.md`（第 61～65 行的迁移规则）。

## 必读

- `AGENTS.md`、`docs/DECISIONS.md`（重点 D9、D19、D32、D43 和开工前新增的 D44）、`docs/design/SPEC.md`「系统页」和配色表、`docs/design/PANEL_LAYOUT_FORMAT.md`。
- 设计稿 `docs/design/mockups/battery.html`，包括底部「口径」。
- 同类任务的历史坑：`docs/plans/2026-10-13-proxy-traffic/result.md` 的复审节（权限被拒时不绕开；原生图像与交互截不到时由用户实机验收）。

## 授权范围

- 允许：本地 git commit；`scripts/check.sh`、`scripts/test.sh`、`scripts/build-app.sh`；`scripts/install.sh`（按 AGENTS.md 让旧进程正常退出）；只读执行 `pmset -g batt`、`pmset -g rawbatt`，以及按 D11 过滤的 `system_profiler SPPowerDataType`；`MEOWMAC_LIVE=1` 的实机用例；第 2 轮运行 `MEOWMAC_UI_TESTS=1 scripts/test.sh <过滤词>` 的前台用例（会弹出 MeowMac 自己的窗口）；验收期间用 `caffeinate -i -w <pid>` 防止空闲睡眠；在 `build/` 下写测试输出、实测数据、预览图和截图；读取 TunCanary 仓库的文件；用 Computer Use 打开 MeowMac 面板、切到系统页、滚动到电池卡片、悬停查看提示、截图。
- 不允许：运行 `ioreg`（见 D11）；推送；修改 TunCanary；`sudo`、`pmset` 的任何写操作或修改充电设置；把电池序列号或原始 mAh、电压、电流写进仓库；Computer Use 操作 MeowMac 以外的应用；在设置窗口里点保存。没列在“允许”里的都不允许。
- 应用运行数据和验收材料分开：安装后的 MeowMac 按 D44 在 `~/Library/Application Support/MeowMac/history/battery/` 写电量历史，这是正常运行。执行者为验收另外导出的读数和截图只放 `build/acceptance/battery/`，result 里只写结论和偏差。
- 命令或 Computer Use 的权限请求被拒时，不自行绕开；在 result 记录原文，把相关验收标为“需规划者实测”。

## D44（用户 2026-10-24 批准，已写入 `1b2e437`）

> **D44　电池与续航（2026-10-24）。** 本项补充 D9 和 D30，其余不变。
>
> - 电池读数来自 IORegistry 的 `AppleSmartBattery`（与 D9 的电池温度同源，不需要 sudo）：电量、供电与充放电状态、电压和电流、系统给出的平均预计时间、最大容量、循环次数和适配器额定功率。不读取、不记录序列号；不使用公开接口里的电池健康文字。
> - 预计时间只显示系统给出的值，MeowMac 不自行推算续航。
> - 每 5 分钟记录一个电量点，供电状态变化时立即补记一点，写入 `~/Library/Application Support/MeowMac/history/battery/`，保留 24 小时。
> - 系统页新增“电池”功能块 `system.battery`，默认排在磁盘之后；没有电池的 Mac 不显示。设计稿见 `docs/design/mockups/battery.html`。
> - 本项不新增提醒规则。

## 决策点

类型：`偏好`（执行者不能改）、`技术`（执行者可凭证据更正或提异议）、`安全`（只能收紧）。

| 编号 | 类型 | 问题 | 结论 |
|---|---|---|---|
| D1 | 偏好 | 卡片内容和版式 | 已定：按设计稿 `battery.html`（用户 2026-10-24 定稿）。 |
| D2 | 偏好 | 卡片位置 | 已定：系统页 `system.battery`，默认排在 `system.disk` 之后，可隐藏、可调顺序。 |
| D3 | 偏好 | 续航估算 | 已定：只用系统的 `AvgTimeToEmpty`、`AvgTimeToFull`；值为 65535、0、负数或接电源未充电时不显示数字，写设计稿对应文案。不自行推算。 |
| D4 | 偏好 | 历史粒度和保留 | 已定：每 5 分钟一点，供电状态（接电源、充电）变化时立即补一点；保留 24 小时；曲线固定显示近 24 小时，不跟随系统趋势的 15 分钟 / 1 小时切换。 |
| D5 | 偏好 | 提醒 | 已定：不新增提醒规则；20% 虚线只是曲线上的参考线。 |
| D6 | 偏好 | 充电时的预计文案 | 已定：写“预计 N 分钟充满”，不写目标百分比（用户 2026-10-24 选定，修改设计稿“充到 80%”的写法）。`AvgTimeToFull` 在开启充电上限或优化充电时的目标值没有公开说明。 |
| D7 | 技术 | 字段口径 | 允许默认：电量 `CurrentCapacity`；健康 `MaxCapacity`（%），悬停提示按设计稿写原始满充 `AppleRawMaxCapacity` 与设计容量 `DesignCapacity` 的 mAh 值及二者换算的百分比（界面运行时显示即可，这些真实值不进仓库）；充放电功率 = `Voltage` × `Amperage` 取绝对值，换算成 W，保留 1 位小数；接电源未充电时功率写整机功耗（已有 `SystemLoad`）；适配器 `AdapterDetails.Watts`。字段缺失或类型不符时该项显示“—”，不影响其他项。 |
| D8 | 技术 | 状态判定 | 允许默认：`ExternalConnected` 为假 → 使用电池；为真且 `IsCharging` 为真 → 充电中；为真且 `FullyCharged` 为真 → 已充满；其余 → 接电源 · 未充电。没有 `AppleSmartBattery` 服务或 `BatteryInstalled` 为假 → 无电池，卡片不显示（不占位）。 |
| D9 | 偏好 | 执行者自主权 | 已定：宽松。不部署，不写线上数据，不改系统设置。 |
| D10 | 技术 | 24 小时摘要 | 允许默认：历史分连续采集段，应用启动后和每次系统唤醒后的第一个点标记为新段起点（行字段 `segmentStart: true`）；曲线和摘要都不跨段连线、不跨段累计，段起点前的空档画斜纹。只统计同一段内相邻两点都在使用电池、间隔不超过 330 秒的区间；用电池时长为这些区间之和；耗电为这些区间内电量下降之和；平均功率为这些点放电功率的均值。没有这样的区间时写“已记录 N 分钟”或“近 24 小时未用电池”。 |
| D11 | 安全 | 隐私和公开红线 | 已定：应用按字段白名单逐键读取 `AppleSmartBattery`（`IORegistryEntryCreateCFProperty`，或读取 `BatteryData`、`AdapterDetails` 后只取白名单子键），不再取完整属性字典，不碰任何序列号键。验收不运行 `ioreg` 命令：IORegistry 的真实值只经应用自己的白名单读取器取得（`MEOWMAC_LIVE=1` 用例，只输出白名单标量；读取或解析失败时只输出错误类别，不输出原文）。`system_profiler SPPowerDataType` 是一行一个字段的文本，只允许经 `grep -E '^ *(Cycle Count|Maximum Capacity|Condition|State of Charge \(%\)|Charging|Fully Charged):'` 按行首字段名过滤后显示或写文件；`pmset -g batt` 不含序列号，可直接使用。不允许完整的 `system_profiler` 输出或任何 `ioreg` 输出进入终端日志、result 或 `build/`。序列号在任何地方都不记录。夹具和预览图只用虚构数据；过滤后的真实读数只在 `build/acceptance/battery/`。 |
| D12 | 偏好 | 设计稿“刚启动 · 记录不足”与 D10 的冲突（第 1 轮复审 R3） | 已定：以 D10 为准（用户 2026-10-24 选定）。设计稿该状态改为只有 1 个点、“已记录 4 分钟”的示例。 |

## 进度

| 编号 | 条目 | 档位 | 状态 | 提交 |
|---|---|---|---|---|
| 1 | 电池读数的采集与解析 | 可交付 | 已完成，第 1 轮复审通过 | `0186f4c`、`02b31e6` |
| 2 | 24 小时电量历史 | 需强模型 | 已完成，第 1 轮复审通过 | `25bca0c` |
| 3 | 电池卡片和布局迁移 | 需强模型 | 已完成，第 1 轮复审通过（修复 `393424a`） | `6413c97`、`02b31e6` |
| 4 | 安装和实机验收 | 可交付 | 已完成，第 2 轮复审通过（修复 `2ce3309`），2026-10-24 用户实机验收通过 | `4a737b4`、`958f9df` |

## 执行清单

### 1. 电池读数的采集与解析

- 依据：D3、D7、D8、D11；「背景与已知事实」中的实测字段。
- 改法：
  - `MeowMacCore`：扩展 `BatteryMetrics`（或新增 `BatteryStatus`，名称可调整），保持现有 `temperatureCelsius`、`systemPowerWatts` 的含义和解码兼容；新增状态（无电池、使用电池、充电中、已充满、接电源未充电）、电量、最大容量、原始满充与设计容量换算的百分比、循环次数与设计循环次数、充放电功率、预计放电与充电分钟数、适配器额定功率。解析函数是纯逻辑，输入是 IORegistry 属性字典，不在 Core 做 I/O。
  - 65535、0、负数的预计时间解析为“不可用”；电流为 0 时功率为 0；缺字段只影响对应项。
  - `MeowMacSystem`：`SystemCollector.batteryMetrics()` 改为按 D11 的字段白名单逐键读取（现有 `IORegistryEntryCreateCFProperties` 取完整字典的写法一并替换，温度和整机功耗照旧可用），组装成只含白名单键的字典交给 Core 解析；不写日志。
- 验收：`scripts/test.sh` 新增套件，夹具用虚构值，覆盖：四种供电状态和无电池；65535 / 0 / 负数预计时间；放电负电流取绝对值；缺 `AdapterDetails`、缺 `Voltage`、字段类型错误；`MaxCapacity` 与原始容量换算并存；旧 `BatteryMetrics` 的 JSON 仍能解码。增加合成测试：白名单读取器面对同一嵌套字典里既有允许字段又有序列号键时，输出只含允许字段；解析失败时不输出原文。`MEOWMAC_LIVE=1 scripts/test.sh <套件>` 读一次本机：断言状态与 `pmset -g batt` 的供电描述一致、电量与其百分比一致、循环次数与 `system_profiler` 一致；原值写 `build/acceptance/battery/`，result 只写是否一致。
- 相关决策点：D3、D7、D8、D11

### 2. 24 小时电量历史

- 依据：D4、D10；`NetworkHistory` 和 `NetworkHistoryRecorder` 的写法。
- 改法：
  - `MeowMacCore`：电量历史模型，行字段至少有时刻、电量、供电状态、放电功率（可空）、是否为段起点（D10）；JSONL 读写、坏行跳过、超大文件当作空、24 小时裁剪、拒绝未来超过 60 秒的行。摘要计算按 D10。
  - `MeowMacUI`：记录器挂在现有 10 秒系统采样路径上：距上一点满 300 秒，或供电状态与上一点不同，就记一点；后台串行队列写盘，失败只记日志；启动时读入历史。无电池时不建目录、不写文件。睡眠期间不记录；启动后和每次唤醒（`NSWorkspace.didWakeNotification`，沿用现有睡眠唤醒处理）后的第一个点写 `segmentStart: true`，并立即记录，不等满 300 秒。
  - 文件放 `~/Library/Application Support/MeowMac/history/battery/`。
- 验收：离线自测用假时钟和临时目录，覆盖：5 分钟节奏；供电变化立即补点；睡眠缺口不插值；跨休眠或重启但两点间隔仍不超过 330 秒时不连线、不计入摘要；重启后接上历史；24 小时裁剪；坏行和超大文件；未来时刻的行；无电池不写盘；D10 摘要的各种边界（跨缺口、只有接电源、只有 1 个点、间隔 331 秒）。
- 执行者要求：强推理模型、高推理档位。
- 相关决策点：D4、D10

### 3. 电池卡片和布局迁移

- 依据：D1、D2、D5、D6、D8；设计稿 `battery.html`；D32。
- 改法：
  - `PanelLayoutCatalog` 系统页新增 `system.battery`（标题“电池”），排在 `system.disk` 之后。
  - `PanelLayout.migrated` 照 `network.proxy` 的先例：系统页恰好只缺 `system.battery`、其余完整且不重复时，以可见状态追加到末尾（`system.disk` 之后）；与 `system.sensors` 的删除规则可同时生效；其他缺项、重复、未知 id 仍拒绝。猫包 `panel` 同样适用。
  - `PanelCardRegistry` 注册卡片；无电池时卡片不渲染、不占位，布局设置里仍可见并注明“本机没有电池”。
  - 卡片按设计稿实现：标题行（电量 20pt 半粗、供电状态、靠右功率）、预计时间行、近 24 小时曲线（328pt 宽，接电源时段绿色 14% 底，无记录斜纹，20% 橙色虚线，灰色线加浅填充）、时间轴、图例和摘要行、健康行。悬停曲线显示真实采样时刻、电量和供电状态，规则同磁盘卡片（只选距鼠标不超过 5 分钟的真实样本）；悬停健康行显示原始满充与设计容量的 mAh 值及换算百分比（同 D7）。
  - 同步 `docs/design/SPEC.md`「系统页」（新增第 5 项“电池”，从设计稿「口径」改写）和配色表，`docs/design/PANEL_LAYOUT_FORMAT.md`（系统页四项、迁移规则）。
- 验收：
  - 离线自测：布局迁移（只缺 `system.battery`；同时有 `system.sensors`；缺其他项时拒绝；写入时系统页四项）；卡片数据计算（四种状态的文案、D6 的充电文案、预计时间不可用的文案、功率格式边界 0 / 9.95 / 100 W、摘要文案）。
  - 合成数据预览图：设计稿四个状态各一张，浅色和深色，放 `build/acceptance/battery/preview/`，与设计稿逐项对照，偏差写进 result。
  - 首屏规则：SPEC 中“正常状态的系统页在 820pt 内完整显示趋势图、能耗排行和磁盘”仍然满足（电池卡片在磁盘之后，可滚动到达），用预览图量高度证明。
- 执行者要求：强推理模型、高推理档位。
- 相关决策点：D1、D2、D5、D6、D8

### 4. 安装和实机验收（第 2 轮）

- 依据：D3、D4、D8、D12；第 1 轮复审遗留 R5。宿主（Claude Code 子 Agent）没有 Computer Use，原生面板的截图、悬停和材质交给用户实机验收，执行者不尝试其他截屏方式。
- 改法：只做验证，不改应用代码；验收脚本放 `build/acceptance/battery/`。
  1. 安装前记下历史文件现有的行数和最后一点的时刻 T0；`scripts/install.sh` 安装（会让正在运行的 MeowMac 正常退出并重启）；用 `caffeinate -i -w <验收脚本 pid>` 防睡眠，MeowMac 持续运行，直到本次启动的段起点之后出现至少 3 个周期点（最长等 20 分钟），期间不重启、不改配置。
  2. 补跑前台用例（R5）：`MEOWMAC_UI_TESTS=1 scripts/test.sh LayoutSettings` 以及第 1 轮改过期望的 `SensorUITests`、`PanelLayoutUITests` 对应过滤词；在 result 写命令、退出码和通过数。“本机没有电池”的提示若无法在本机触发，补一条离线断言覆盖它的文案和显示条件（这是允许的测试补充，用 `test:` 提交）。
  3. 历史文件检查：读 `~/Library/Application Support/MeowMac/history/battery/samples.jsonl`，只用脚本解析并输出数值摘要（点数、相邻间隔、`segmentStart` 位置），不把原行写进 result。
  4. 读数对照：`MEOWMAC_LIVE=1 scripts/test.sh System.Live.Battery` 再跑一次，与同一时刻的 `pmset -g batt`、过滤后的 `system_profiler` 对照。
- 验收：
  - 晚于 T0 的新增行中，第一行是 `segmentStart: true`（本次启动的段起点），其后至少 3 个点，相邻间隔 300 ± 15 秒且都不是段起点；文件不含 `Serial`；
  - 前台用例必须全部通过。失败或因权限阻塞时，在 result 写原文和原因，该项标为“未通过”或“需规划者实测”，条目 4 不得标为已完成；不放宽断言；
  - 读数对照全部一致；
  - `scripts/check.sh` 通过。
- 用户实机验收（执行者做完后由规划者请用户做）：打开面板 → 系统页 → 滚动到电池卡片，对照设计稿看版式和悬停；拔掉电源，1 分钟内卡片切到“使用电池”，系统给出预计时间后显示“预计还能用 …”；重新接上后切到“充电中”或“接电源 · 未充电”；曲线上出现对应的绿色底变化。
- 相关决策点：D3、D4、D8、D12

## 规划者保留

- D44 的写入、提交和 `plan-baseline` 标签移动：已由规划者完成（`1b2e437`）。
- 用户实机验收：拔插电源后的状态切换、预计时间、24 小时曲线。

## 项目专属自检

- [ ] `scripts/check.sh` 通过，`plan-baseline` 比对通过（开工前标签已移到 D44 的提交）
- [ ] 没有修改 `../tuncanary`（`git -C ../tuncanary status --short` 为空）
- [ ] `git grep -n -i serial` 在新代码和夹具中没有读取或记录电池序列号；`git grep -n IORegistryEntryCreateCFProperties Sources/MeowMacSystem/SystemCollector.swift` 不再命中电池读取
- [ ] `build/acceptance/battery/` 下的文件不含 `Serial`（`grep -r -i serial build/acceptance/battery` 为空）
- [ ] 夹具和预览图只用虚构数据；仓库里没有本机原始 mAh、电压、电流读数
- [ ] 没有调用 `pmset` 的写参数、没有 `sudo`、没有运行 `ioreg`
