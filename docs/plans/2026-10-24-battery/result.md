# 电池与续航：执行结果

对应的 plan：`docs/plans/2026-10-24-battery/plan.md`。最新一轮在最上面。

## 轮次

<!-- 执行者：在这一行下面插入新的一轮，格式见 relay Skill 的 references/result-template.md「第 N 轮」 -->

### 第 1 轮（2026-10-24，Claude Code 子 Agent · Claude Opus 5.5，推理强度：宿主默认）

**提交范围**：`71cf2fd..7c15fb4`（本轮提交：`0186f4c` feat: read battery status through key whitelist、`25bca0c` feat: record 24-hour battery charge history、`6413c97` feat: add battery card to system page、`02b31e6` fix: use fictitious cycle count in battery fixtures、`7c15fb4` docs: record battery round 1 result）

**开工检查**：无人值守；plan 复核：不需要（格式 relay-plan v2，定稿 2026-10-24，未超过 3 天）

**完成的条目**

| 编号 | 提交 | 验收证据 |
|---|---|---|
| 1 | `0186f4c`、`02b31e6` | `scripts/test.sh System.Battery` 退出 0，8 项全过：四种供电状态与无电池；65535 / 0 / 负数预计时间；放电负电流取绝对值（含 64 位无符号位模式还原）；缺 `AdapterDetails`、缺 `Voltage`、类型错误逐项为空；`MaxCapacity` 与原始容量换算并存；旧 `BatteryMetrics` JSON（无 `status`）可解码；白名单读取器面对顶层和嵌套字典里的序列号键时只请求、只输出白名单键；解析问题列表只含键名和类别、不含原文。`SystemCollector.batteryProperties()` 改为 `IORegistryEntryCreateCFProperty` 逐键读取，`git grep -n IORegistryEntryCreateCFProperties Sources/MeowMacSystem/SystemCollector.swift` 无输出（退出 1）。实机：`MEOWMAC_LIVE=1 scripts/test.sh System.Live.Battery` 退出 0，关键行“电池实测对照：供电 true，充电 true，电量 true，循环次数 true，最大容量 true，字段问题 0 项”；原值在 `build/acceptance/battery/live-reading.txt`，`grep -ci serial` 为 0。结论：本机（接电源）MeowMac 白名单读数的供电状态、是否充电、电量与 `pmset -g batt` 一致，循环次数、最大容量与过滤后的 `system_profiler SPPowerDataType` 一致。 |
| 2 | `25bca0c` | `scripts/test.sh Battery.History` 退出 0，7 项全过（假时钟、临时目录）：每 10 秒采样 16 分钟只在 0/300/600/900 秒记点；供电变化立即补点；睡眠期间采样被忽略、唤醒后首点是段起点并立即记录；唤醒或重启后两点只隔 200、100 秒也分段、不计入摘要；重启后接上旧历史；24 小时裁剪、坏行（含越界电量、`noBattery`、未知状态）、超大文件、未来超过 60 秒的行；无电池时不建目录；D10 摘要边界（跨 400 秒缺口、只有接电源、只有 1 个点、331 秒不计而 330 秒计入、一侧接电源的区间、电量回升不算耗电、端点功率去重求均值、覆盖 24 小时未用电池）。负控：把 `maxGap` 改成 331、去掉唤醒段起点后 4 项失败，随后已改回。记录器挂在 `MeowMacApplication.sample()`，`willSleep` 调 `sleep()`，`didWake` 先调 `wake()` 再采样。 |
| 3 | `6413c97`、`02b31e6` | `scripts/test.sh Battery` 退出 0；`Core.PanelLayout/电池块迁移与拒绝` 覆盖：v1、v2 只缺电池时可见追加到末尾且显隐不变、写回四项、与 `system.sensors` 删除同时生效、已有电池保持原样、缺其他项 / 重复 / 未知 id / 跨页拒绝、猫包 `panel` 同样迁移。`UI.Battery/*` 覆盖四种状态文案、D6 充电文案（“预计 35 分钟充满”，不含百分号）、预计时间不可用文案、功率格式 0 / 9.95 / 9.94 / 100 W（“0.0 W”“10.0 W”“9.9 W”“100.0 W”）、摘要文案、无电池与未采集时不渲染、隐藏后不渲染、悬停只选 5 分钟内的真实样本、斜纹时段。首屏：`UI.Battery/真实容器首屏仍含磁盘` 用 `PanelHosting` 的真实容器测量四种状态，面板 820 pt，可视 583 pt，磁盘底边 563 pt ≤ 583，电池底边 717 pt（可滚动到达），曲线 328×24 pt（`build/acceptance/battery/preview/first-screen.txt`）。合成预览 8 张加悬停 2 张：`build/acceptance/battery/preview/battery-{discharge,charging,ac,sparse}-{light,dark}.png`、`battery-hover-{light,dark}.png`，每张 720 px 宽、展开高 966 pt。SPEC「系统页」新增第 5 项和配色行，PANEL_LAYOUT_FORMAT 改为系统页四项并写迁移规则。 |

与设计稿逐项对照（读 `battery.html` 源码中的尺寸、颜色和文案，对照预览图）：标题行字号字重、预计时间行加重、“近 24 小时”、24 pt 曲线、接电源绿色 14% 底、20% 橙色虚线、斜纹、灰线浅填充、末点圆点、三点时间轴“昨天 HH:mm”、图例色块与摘要、健康行左右两段均一致。偏差：①摘要和曲线数值由合成历史按 D10 计算，与设计稿写死的数值不同；②“刚启动”状态见「技术更正与异议」；③时间轴按本机时区显示；④悬停提示框画在曲线上方，会盖住标题行，与磁盘卡片现有做法相同。

**缺陷扫描**

扫描轮次：1。真实入口与环境：`PanelPreviewRenderer.systemPagePNG` 的展开系统页（360 pt 宽，预览材质退路），浅色和深色；`PanelHosting` 真实容器测量；实机白名单读取一次。

| 轮次 | 问题及证据 | 分类 | 修复与提交 | 复验结果 |
|---|---|---|---|---|
| 1 | 夹具和合成预览沿用设计稿的循环次数，该值与本机实测循环次数相同（对照 `build/acceptance/battery/live-reading.txt`），违反“夹具只用虚构数据” | 范围内的缺陷 | 改为 123，`02b31e6` | `scripts/check.sh` 退出 0，381 项 0 失败；其余虚构值 4321 / 4500 / 4620 / 12000 / 775 / 2050 / 9300 / 3100 与实测文件逐个比对无重合 |
| 1 | 标题行下间距 3 pt，设计稿 `.heading` 为 8 px（电池未像磁盘那样覆盖成 3 px） | 范围内的缺陷 | 提交前改为 8 pt，含在 `6413c97` | 首屏测量电池块高 149 → 154 pt，磁盘仍在首屏 |
| 1 | 窗口起点恰好落在两次记录之间时，左端出现不足 5 分钟的斜纹细条 | 范围内的缺陷 | 提交前改为窗口开头不超过 330 秒的空白不算缺失，含在 `6413c97` | `UI.Battery/无电池不渲染与悬停选择` 通过，含“窗口开头超过 330 秒才算缺失”断言 |

最终剩余：无。

**顺手修复**

无。

**自主决定**

| 条目 | 选择 | 备选 | 理由 |
|---|---|---|---|
| 1 | 缺 `ExternalConnected` 时按“使用电池”处理；服务存在但缺 `BatteryInstalled` 时视为有电池 | 新增“未知”状态 | D8 只列五种状态；预计时间仍只取系统值，不会编造数字 |
| 1 | `MaxCapacity` 只接受 0～200，`CurrentCapacity` 只接受 0～100，越界写“—” | 原样显示 | Intel 机型的 `MaxCapacity` 是 mAh，不能当百分比显示 |
| 1 | 布尔字段只接受 CFBoolean，数字字段不接受 CFBoolean；`Amperage` 按 64 位位模式还原负值 | 宽松转换 | 对应“字段类型错误”验收；IOKit 可能以无符号数返回负电流 |
| 2 | 文件名 `samples.jsonl`，上限 4 MiB；本次运行第一次记点时整体重写（顺带清掉过期和坏行），之后追加，每小时重写一次 | 照网络历史在启动时重写 | 启动时重写会在无电池的 Mac 上建目录，违反“无电池不建目录” |
| 2 | 曲线和摘要除段起点外，相隔超过 330 秒也断开 | 只按段起点断开 | 没收到睡眠通知的停顿（卡顿、时钟跳变）同样不能插值，与 D10 的 330 秒口径一致 |
| 3 | 已充满的功率写整机功耗，预计行写“由电源供电，电池已充满”；充电但无预计时间写“充电中，系统还没给出预计充满时间” | 不显示 | 设计稿没画这两种情况；沿用 D3、D7 的口径 |
| 3 | 没有可统计区间时：记录已覆盖 24 小时（最早一点距现在 ≥ 24 小时 − 330 秒）写“近 24 小时未用电池”，否则写“已记录 N 分钟”，N 为最早一点到现在 | 只看有无用电池的点 | 刚启动接电源时写“近 24 小时未用电池”会误导 |
| 3 | 迁移把电池追加到系统页末尾，即使用户把磁盘挪到了别处 | 插到 `system.disk` 之后 | plan 写的是“追加到末尾”；默认顺序下两者相同 |
| 3 | 时长不足 1 小时写“N 分钟”，整小时写“N 小时”，其余“N 小时 M 分”；功率四舍五入到 1 位小数 | 沿用 `MetricFormat.duration`（会写“6 小时 0 分”） | 对齐设计稿“用电池 6 小时”“4 小时 20 分” |
| 3 | 电池曲线的悬停用独立的 `PanelState.batteryHoverDate`，`TrendMouseSurface` 由 private 改为 internal 复用 | 复用 `chartHoverDate` | 系统趋势的悬停时刻按 15 分钟 / 1 小时换算，共用会让其他曲线画错联动竖线 |

**技术更正与异议**

| 类型 | 对象 | 证据 | 处理 | 影响 |
|---|---|---|---|---|
| 验收与决策冲突 | 设计稿“刚启动 · 记录不足”状态（曲线有约 30 分钟的放电线，摘要写“已记录 30 分钟”）与 D10 | 按 D10，5 分钟一点、30 分钟会有 6 段可统计区间，摘要必然是“用电池 30 分钟 · 耗电 …”，不会出现“已记录 30 分钟” | 以 D10 为准：合成预览用刚启动 4 分钟、只有 1 个点的历史，摘要为“已记录 4 分钟”，曲线左侧全是斜纹 | 用户实机看到的“记录不足”只在启动后约 5 分钟内出现；如要 30 分钟内都显示“记录不足”，需要改 D10 |
| 异议 | plan「背景与已知事实」“系统快照每 10 秒采一次” | `Sources/MeowMacUI/ApplicationCadence.swift` 的采样定时器是 2 秒 | 未改 plan；记录器按时刻判断，不依赖采样间隔 | 无 |

**plan 勘误**

无。

**建议**

- 设计稿 `battery.html` 的示例循环次数与本机实测值相同，建议规划者换成虚构值（设计稿是用户定稿的文件，执行者没有改）。
- `SystemUpdatePath` 的“电池”数据源失败计数仍以温度为空判定，无电池的 Mac 会持续累加；与本任务无关，未改。

**外部写入**

- 无。只有本地提交 5 个（含本提交），未推送；未运行 `ioreg`、`sudo`、`pmset` 写参数；`pmset -g batt` 和过滤后的 `system_profiler SPPowerDataType` 只在实机用例里运行一次；真实读数只写 `build/acceptance/battery/live-reading.txt`。

**跳过的决策点**

- 无。

**未做**

- 条目 4：按 plan 属于第 2 轮。

**偏离 plan 的地方**

- 无（迁移位置、刚启动状态见「自主决定」和「技术更正与异议」）。

**未验证**

- 前台 UI 用例（需 `MEOWMAC_UI_TESTS=1`，会弹出可见窗口，无人值守时未运行）：`LayoutSettingsTests` 中改为四项的期望、布局设置里“本机没有电池”的提示没有在真实设置窗口里核对。
- 电池曲线的原生 tracking 悬停事件、液态玻璃材质下的显示：预览图走预览材质退路，悬停图由设置状态渲染；真实弹出面板留给条目 4 和用户实机验收。
- 放电、充电状态的实机读数：本机接电源，只验证了当前状态；拔插电源由用户在条目 4 验收。
- 与设计稿的对照只读 HTML 源码，没有把设计稿渲染出来并排比较（授权范围不含浏览器）。

**自检**

| 项 | 结果 | 说明或证据 |
|---|---|---|
| 只做了执行清单、范围内缺陷修复和满足条件的顺手修复 | 是 | 条目 1～3；条目 4 未做 |
| 范围内缺陷已修复并重新验收；卡住或跳过的项已记录，未标成已完成 | 是 | 见「缺陷扫描」 |
| 顺手修复不碰核心，不加依赖，行数在本档上限内 | 不适用 | 无顺手修复；`02b31e6` 是范围内缺陷修复（9 行 + 9 行） |
| 顺手修复每项都有单独的 `fix:` 提交、理由、复验证据和 result 记录 | 不适用 | 同上 |
| 没有改变核心；没有放宽安全 | 是 | `git diff --quiet plan-baseline -- AGENTS.md CLAUDE.md docs/DECISIONS.md` 退出 0；读取改为逐键白名单，只收紧 |
| 自主决定、技术更正与异议、plan 勘误都已记录并附理由或证据 | 是 | 见上 |
| 已做交付前缺陷扫描，最多 2 轮；问题分类、修复、复验和剩余问题已写进 result | 是 | 1 轮 |
| 验收的预览、截图和测试走真实路径；模拟证据仅作补充，未验证项已记录 | 是 | 首屏用 `PanelHosting` 真实容器；预览走 `systemPagePNG`；见「未验证」 |
| 没有降低验收标准或放宽测试断言 | 是 | 改动的旧用例只把系统页期望从三项改为四项（`SensorUITests`、`PanelLayoutUITests`、`LayoutSettingsTests`），拒绝类断言不变 |
| 每个执行条目至少一个提交 | 是 | `git log --oneline 71cf2fd..HEAD`：`02b31e6 fix: use fictitious cycle count in battery fixtures`、`6413c97 feat: add battery card to system page`、`25bca0c feat: record 24-hour battery charge history`、`0186f4c feat: read battery status through key whitelist`（另加本 result 提交） |
| 做过的条目都满足执行者要求；不满足的已跳过 | 是 | 条目 2、3 要求强推理模型：Claude Opus 5.5 |
| 外部写入都在授权范围内 | 是 | 无外部写入 |
| 用户可见的改动没有混进 refactor 提交 | 是 | 无 refactor 提交 |
| 新增的后台任务、异常分支都有日志，没有静默吞掉异常 | 是 | 电量历史写入失败、坏行、超大文件都写 `battery-history` 日志 |
| 临时文件、临时脚本都已清理，包括远端机器上的 | 是 | 测试临时目录在用例内删除；负控改动已改回（`grep -n "maxGap: TimeInterval = 330"` 命中） |
| `scripts/check.sh` 通过，`plan-baseline` 比对通过 | 是 | 最后一次 `scripts/check.sh` 退出 0：“自测完成：381 项，0 项失败，50 项前台验收未执行”“check 通过” |
| 没有修改 `../tuncanary` | 是 | `git -C ../tuncanary status --short` 0 行 |
| 新代码和夹具中没有读取或记录电池序列号；`SystemCollector` 不再用完整属性字典读电池 | 是 | `git grep -n -i serial` 在新代码中只命中 `JSONSerialization` 和 `BatteryStatusTests.whitelist` / `issuesWithoutRawText` 的虚构负例（`FAKE-SERIAL-*`、`SerialString` 等键，用来证明读取器不读不传）；`git grep -n IORegistryEntryCreateCFProperties Sources/MeowMacSystem/SystemCollector.swift` 无输出 |
| `build/acceptance/battery/` 下的文件不含 `Serial` | 是 | `grep -r -i serial build/acceptance/battery \| wc -l` 为 0 |
| 夹具和预览图只用虚构数据；仓库里没有本机原始 mAh、电压、电流读数 | 是 | 见「缺陷扫描」第 1 行的逐值比对 |
| 没有调用 `pmset` 的写参数、没有 `sudo`、没有运行 `ioreg` | 是 | 实机用例只运行 `/usr/bin/pmset -g batt` 和带 `grep -E` 行首过滤的 `system_profiler SPPowerDataType` |

**复审**

<!-- 复审者只读，输出由调度者写入 -->

**修复记录**

按规划者指令只修 R1、R2、R6，未改复审结论。修复提交：本提交 `docs: fix battery round 1 review findings`（提交号由调度者补）。

| 编号 | 提交 | 改动 | 验证 |
|---|---|---|---|
| R1 | 本提交 | `docs/design/SPEC.md` 健康行示例的循环次数改为 123，与设计稿一致 | `scripts/check.sh` 退出 0：“自测完成：381 项，0 项失败，50 项前台验收未执行”“check 通过” |
| R2 | 本提交 | result 第 1 轮「缺陷扫描」和「建议」两处去掉实测循环次数，改为“与本机实测值相同” | 同上；`grep -n "77" result.md` 只剩与该值无关的命中 |
| R6 | 本提交 | 「提交范围」补为 `71cf2fd..7c15fb4`，本轮提交列出 `7c15fb4` | 同上 |
