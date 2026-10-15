# 代理流量统计（本机）

公开记录说明：实测原值、采样明细、配置摘要和精确运行时刻仅保留在忽略的 `build/acceptance/`；本文保留方法、阈值、对比偏差和验收结论。

- 格式：relay-plan v2
- 目标：MeowMac 在后台按小时记录本机经代理的流量（按进程、域名、规则、节点），网络页新增“代理流量”卡片显示今天和近 7 天的用量与 Top 进程；可选把小时汇总追加到笔记库，和家里 zspace 的数据一起对账。
- 规划：Claude Opus 5.5
- 定稿：2026-10-13
- 复核：2026-10-13，第 3 轮规划
- 模式：relay
- 执行宿主：Codex（见「接力配置」）
- 复审宿主：Codex 全新会话（见「接力配置」）
- 执行规则：`~/.claude/skills/relay/references/execute.md`；本 plan 的例外：无
- 执行者自主权：宽松（见决策点 D10）
- 推荐执行者：强推理模型、高推理档位
- 轮次上限：4
- 用量上限：无
- 结果文档：`docs/plans/2026-10-13-proxy-traffic/result.md`

## 总纲

本任务是“代理流量摸排”的第二部分：

| 部分 | 位置 | 内容 |
| --- | --- | --- |
| A | `~/projects/eastcn/meowkit/docs/plans/2026-10-13-mihomo-traffic/plan.md` | 共用的数据格式 `mihomo-traffic/SCHEMA.md`、zspace 用的采集脚本、对账日报 |
| B（本 plan） | MeowMac | 按同一格式采集本机流量，加网络页卡片 |
| C | 规划者保留 | 给 Hermes 的 zspace 部署提示词 |

- **开工前提**（规划者在启动前核对，不满足就不启动）：
  1. A 已完成，并且复审通过；
  2. 已满足（2026-10-13）：D43 与 AGENTS.md 修改已写入 `0a6c601`，`plan-baseline` 已移到该提交。
- 范围：本机采集、本地历史、检查点、可选导出到笔记库、网络页卡片、布局迁移、设计文档同步、安装和实机验收。
- 不做：修改 TunCanary 仓库；调用 mihomo 的写接口；在执行阶段写真实的笔记库目录（只写 `build/` 下的临时目录，真实导出由用户在实机验收时打开）；家里 zspace 的任何部署；推送。
- 全部条目与轮次：
  - 第 1 轮：条目 1～3（采集逻辑、采集运行和本地存储、导出到笔记库）；
  - 第 2 轮：条目 4～5（卡片和布局迁移、安装和实机验收）。
- 整体验收：`scripts/check.sh` 通过；安装后 MeowMac 持续采集，本地历史按小时增加，行格式符合 SCHEMA；卡片与设计稿一致；配置导出目录后整点追加一行；采集带来的 CPU 增量在限额内；用户实机验收卡片和导出。

## 背景与已知事实

- 动机：机场订阅流量消耗过快，本机开着 Clash Verge Rev 的 TUN，`rule` 模式，最后一条规则是 `MATCH,🐟 漏网之鱼`，没有命中前面规则的流量全部走代理。需要按进程和规则看清本机的消耗。
- 控制接口：TunCanary 的 `MihomoController.locate()` 是 public，返回 socket 路径（`../tuncanary/Sources/TunCanarySystem/Proxy/MihomoController.swift:18`），socket 归当前用户、权限 600、不需要 secret。TunCanary 读 socket 的 `UnixHTTPClient` 是 internal（同文件第 127 行），MeowMac 用不到，按 D43 自己实现只读客户端。
- 性能：已做只读控制接口验证；耗时、响应大小、连接数及资源原值仅保留在本地验收材料中。
- 现有可参照的写法：
  - 历史：`Sources/MeowMacCore/NetworkHistory.swift`（JSONL、坏行跳过、超大文件当作空）、`Sources/MeowMacUI/NetworkHistoryRecorder.swift`（后台串行队列写盘，失败只记日志）、`Sources/MeowMacCore/QuotaHistory.swift`（按期限裁剪）；
  - 配置：`Sources/MeowMacCore/LocalConfig.swift`（`decodeIfPresent` 加默认值、越界回退）；
  - 卡片：`Sources/MeowMacCore/PanelLayout.swift:13-18`（功能块目录）、`PanelLayout.migrated`（2026-10-04 新增 `network.traffic` 的迁移先例）、`Sources/MeowMacUI/PanelView.swift:36-60`（`PanelCardRegistry`）、`Sources/MeowMacUI/NetworkPage.swift:505`（`NetworkTraffic` 卡片）；
  - 设计文档：`docs/design/SPEC.md`「网络页」、`docs/design/PANEL_LAYOUT_FORMAT.md` 第 61～65 行。

## 必读

- `AGENTS.md`、`docs/DECISIONS.md`（重点 D5、D7、D15、D35、D41 和开工前新增的 D43）、`docs/design/SPEC.md`「网络页」、`docs/design/PANEL_LAYOUT_FORMAT.md`。
- `../meowkit/mihomo-traffic/SCHEMA.md`：行格式、字段含义、采集算法和已知误差。MeowMac 的实现必须与它一致；两边有冲突时以 SCHEMA 为准，冲突写进 result。
- `../meowkit/mihomo-traffic/mihomo_traffic.py` 和它的测试：算法的参考实现，测试场景照搬到 Swift。
- 设计稿：`docs/plans/2026-10-13-proxy-traffic/design.html`（用户 2026-10-13 定稿），页面底部的「版式」和「数据口径」是实现规格。

## 授权范围

- 允许：本地 git commit；`scripts/check.sh`、`scripts/test.sh`、`scripts/build-app.sh`；`scripts/install.sh`（按 AGENTS.md 让旧进程正常退出）；需要重启 MeowMac 时重新运行 `scripts/install.sh`；实机验收期间用 `caffeinate -i` 防止系统睡眠；条目 5 中临时修改真实 `config.json` 的 `proxyTrafficEnabled` 和 `proxyTrafficExportDirectory` 两个字段（改前把原文件复制到 `build/acceptance/config.json.bak`，只改这两个字段，测完逐字节恢复原文件并在 result 里写配置逐字节恢复结论，摘要仅保留在本地验收材料中）；只读访问本机 mihomo socket（`GET /connections`、`GET /version`）；读取 TunCanary 和 meowkit 仓库的文件；在 `build/` 下写测试输出、实测数据和截图；`MEOWMAC_LIVE=1` 的实机用例；离线自测和合成数据预览图；用 Computer Use 打开 MeowMac 面板、切到网络页、切换卡片的“今天 / 近 7 天”、展开和收起进程行、截图。
- 不允许：推送；修改 TunCanary 或 meowkit 仓库；调用 mihomo 的写接口；修改 Clash Verge 的配置或重启内核；把真实的 `~/projects/EastNotes` 路径写进 `config.json`（导出只在用户实机验收时由用户配置）；Computer Use 操作 MeowMac 以外的应用；在设置窗口里点保存。没列在“允许”里的都不允许。
- 应用运行数据和验收材料分开：安装后的 MeowMac 按 D43 在 `~/Library/Application Support/MeowMac/history/proxy-traffic/` 写本地历史和检查点，这是正常运行，不受下一条限制。执行者为验收另外导出的快照、截图和原值只放 `build/acceptance/`，result 里只写结论和数量，不写真实进程名、域名和节点名。

- 第 2 轮补充（第 1 轮复审 R1 的教训）：Codex 沙箱里 `swift build`、`scripts/check.sh` 或其他命令被拒时，按正常流程申请提权运行原命令；不要自行加 `--disable-sandbox`、改缓存路径或用其他方式绕开。安装、Computer Use、`caffeinate` 和修改配置同样走审批。审批被拒或宿主不支持审批时，在 result 里记录阻碍和原文，把相关验收标为“需规划者实测”，不得绕过。

- 第 2 轮中断记录（2026-10-13 17:11，Codex 服务端 `serverOverloaded` 重试 3 次后停止，规划者记录）：
  - 已完成：条目 4 已提交 `70c0076`；条目 5 的持续采集验收已通过（`build/acceptance/proxy-traffic/acceptance-round2.json`：同一次运行结算的完整小时覆盖与格式检查通过，精确运行时刻仅保留在本地验收材料中），不用重做。
  - 中断时在做性能对照的“关闭”组（16/20 个样本），这组作废，两组都要重测；导出检查、Computer Use 截图和第 2 轮 result 都还没做。
  - 规划者已把真实 `config.json` 从 `build/acceptance/config.json.bak` 逐字节恢复（与验收开始时逐字节一致，摘要仅保留在本地验收材料中）。当前运行的 MeowMac 是在采集关闭时启动的，继续前先用 `scripts/install.sh` 重启。
  - 续做时沿用 `build/acceptance/proxy-traffic/` 里已有的脚本和证据，只补没做的部分，然后写第 2 轮 result。

## 接力配置

| 角色 | 工具 | 模型 | 推理强度 |
|---|---|---|---|
| execute | codex | gpt-6.1-sol | high |
| review | codex | gpt-6-astra | medium |

- 允许推送：否
- 自动修复：是
- 允许 Computer Use 的应用：MeowMac
- 预计时长：150
- 卡住阈值：30

## D43 与 AGENTS.md 修改（用户 2026-10-13 批准，已写入 `0a6c601`，`plan-baseline` 已移到该提交）

写入 `docs/DECISIONS.md`，放在 D42 之后、「附录」之前：

> **D43　代理流量统计（2026-10-13）。** 本项是 D5 的例外，其余不变。
>
> - 本机经代理流量的统计由 MeowMac 自己实现，不写进 TunCanary，也不修改 TunCanary。只调用 TunCanary 已公开的 `MihomoController.locate()` 取得控制 socket 路径；读取 `/connections` 的客户端由 MeowMac 自己实现，只读，不调用任何写接口。
> - 数据格式遵循 meowkit 仓库的 `mihomo-traffic/SCHEMA.md`（`mihomo-traffic/v1`），来源名 `mac`，不记录来源 IP。
> - 每 5 秒采样一次，结果只在内存中累计；每 5 分钟写一次本地检查点；按小时汇总，写入 `~/Library/Application Support/MeowMac/history/proxy-traffic/`，保留 30 天。
> - 可选导出：`config.json` 的 `proxyTrafficExportDirectory` 不为空时，每个小时结束后把这一小时的汇总行追加到该目录下的 `mac/YYYY-MM-DD.jsonl`。只追加，不重命名，不建临时文件；删除该子目录下超过 30 天、文件名符合 `YYYY-MM-DD.jsonl` 的文件。默认为空，不导出。
> - 网络页新增“代理流量”功能块 `network.proxy`，设计稿见 `docs/plans/2026-10-13-proxy-traffic/design.html`。

`AGENTS.md`「必须停下来的情况」中“往仓库外写文件”的例外改为：

> 例外：应用运行时写 `~/Library/Application Support/MeowMac/`；按 D43 向用户在 `config.json` 中配置的代理流量导出目录追加小时汇总；`scripts/install.sh` 安装应用；以及当前 plan 的授权范围中明确列出字段的 `config.json` 临时修改，修改前备份，验收后逐字节恢复。

## 决策点

类型：`偏好`（执行者不能改）、`技术`（执行者可凭证据更正或提异议）、`安全`（只能收紧）。

| 编号 | 类型 | 问题 | 结论 |
|---|---|---|---|
| D1 | 偏好 | 功能放在哪里 | 已定：全部在 MeowMac，不改 TunCanary（用户 2026-10-13 选定，见 D43 草案）。 |
| D2 | 偏好 | 粒度和保留期限 | 已定：按小时汇总，本地和导出都保留 30 天。 |
| D3 | 偏好 | 采集和写盘的频率 | 已定：5 秒采样，只在内存里累计；5 分钟写一次本地检查点；整点后追加一行到导出目录。 |
| D4 | 偏好 | 导出到笔记库 | 已定：`config.json` 的 `proxyTrafficExportDirectory`，默认为空即不导出；用户实机验收时自己配置为笔记库内的 `Hermes/设备与网络/代理流量/数据` 的绝对路径。程序在其下写 `mac/` 子目录。 |
| D5 | 偏好 | 卡片 | 已定：按设计稿 `design.html` 实现。“今天 / 近 7 天”切换、合计、小时（或按天）柱状图、Top 5 进程（可展开看 Top 5 域名和最多的规则、节点）、底部 MATCH 占比，读不到控制接口时显示空状态。 |
| D6 | 技术 | 采集的开关 | 允许默认：`config.json` 的 `proxyTrafficEnabled`，默认 `true`。关闭时不读 socket，卡片显示“代理流量统计已关闭”。 |
| D7 | 技术 | 采样线程和刷新界面 | 允许默认：采样和计算在后台串行队列；每次采样后把当前小时的汇总交给主线程。面板没打开时不触发界面计算。系统睡眠时暂停，唤醒后继续；睡眠期间不计入 `coverage_seconds`。 |
| D8 | 技术 | 卡片可用性 | 允许默认：`network.proxy` 始终可用，不依赖 TunCanary 的 `networkModel`；没有数据时显示空状态。 |
| D9 | 安全 | 隐私和公开红线 | 已定：不记录来源 IP；日志不打印域名和进程明细；测试夹具和预览图只用虚构数据（`example.*`、保留网段、虚构进程名）；真实截图只在 `build/acceptance/`。 |
| D11 | 技术 | 第 2 批复审 R1、R2 的处理（2026-10-13，规划者） | 已定：R1 超标的原因尚未确定。原测法用 `ps %cpu`（衰减均值），两组样本波动较大，原始统计量仅保留在本地验收材料中；规划者的 `sample` 调用栈里，`proxy-traffic` 队列不是热点，但这只是线索，不能换算成 CPU 百分比。上限 0.5 个百分点不变，第 3 轮按条目 6 改用累计 CPU 时间复核。R2 原生图像与交互：宿主的 Computer Use 和窗口截图都不可用，转入整体验收中的用户实机验收，不再交给执行者。 |
| D10 | 偏好 | 执行者自主权 | 已定：宽松。不部署，不写线上数据；真实导出由用户打开。 |

## 进度

| 编号 | 条目 | 档位 | 状态 | 提交 |
|---|---|---|---|---|
| 1 | 采集逻辑（纯逻辑） | 需强模型 | 已交付，待复审 | 2e8c4e7 |
| 2 | 采集运行、检查点和本地历史 | 需强模型 | 已交付，待复审 | 7d16f3f |
| 3 | 导出到笔记库目录 | 可交付 | 已交付，待复审 | 本轮提交：feat: export proxy traffic hourly history |
| 4 | 代理流量卡片和布局迁移 | 需强模型 | 已完成（原生图像与交互转入用户实机验收，见 D11） | 6f81c61 |
| 5 | 安装和实机验收 | 可交付 | 持续采集与临时导出已通过（e7e7978）；截图转入用户实机验收（D11） | e7e7978 |
| 6 | 性能对照复测（第 3 轮） | 可交付 | 已完成 | e0e74fa |

## 执行清单

### 1. 采集逻辑（纯逻辑）

- 依据：SCHEMA 的「采集算法」；D2、D3、D9。
- 改法：在 `MeowMacCore` 新增 `ProxyTraffic.swift`（文件名可调整），只做纯逻辑：
  - `/connections` 响应的解析，未知字段忽略，缺字段按 SCHEMA 处理；
  - 按连接 id 计算增量，包括基线、计数回退、内核重启检测；
  - 按小时累计，生成不截断的 `by_process`，`items` 截断到 100 项并计算 `other`、`match`（`by_src` 恒为空数组）；
  - 检查点和结算遵守 SCHEMA 的不变式：结算前先写检查点，追加前完整扫描目标日文件去重，已有的行不覆盖；
  - 生成 SCHEMA 行（`source` 固定为 `mac`，`src` 恒为 `null`，`collector` 写 `meowmac/<版本>`）。时钟通过参数注入。
  - 行编码的键名和类型与 SCHEMA 完全一致。整数用 `Int64`；`hour` 用本地时区的 ISO 8601，带偏移。
- 验收：`scripts/test.sh` 新增套件，照搬 meowkit `collect` 测试的全部场景（基线、增量、回退、重启、DIRECT/REJECT/MATCH 分类、跨整点、截断与三处合计等式、`coverage_seconds` 精确值、崩溃恢复不重不丢、进程排名反例、日文件超过 256 KB 时的去重），再加一项：把 SCHEMA 中的示例行解码后重新编码，键集合相同。夹具只用虚构数据。
- 执行者要求：强推理模型、高推理档位。
- 相关决策点：D2、D3、D9

### 2. 采集运行、检查点和本地历史

- 依据：D3、D6、D7；`NetworkHistoryRecorder` 的后台队列写法。
- 改法：
  - `MeowMacSystem`：只读的 unix socket HTTP 客户端，只发 `GET`，超时 5 秒，响应上限 16 MB；socket 路径由 `MihomoController.locate()` 取得，失败时每 60 秒重试一次。
  - `MeowMacUI`：采集协调器，由 `MeowMacApplication` 启动和停止；遵守 `proxyTrafficEnabled`，处理睡眠和唤醒。
  - 存储放在 `~/Library/Application Support/MeowMac/history/proxy-traffic/`：
    - 已结束的小时追加到 `YYYY-MM-DD.jsonl`，规则同 SCHEMA：先写检查点，追加前完整扫描日文件去重，写失败下次重试；
    - `checkpoint.json` 每 5 分钟和退出时原子写入；启动时读取，接上未结算的小时和连接基线；
    - 每次结算后删除超过 30 天的文件。
  - `LocalConfig` 增加 `proxyTrafficEnabled`（默认 `true`）。
  - 给卡片提供数据：今天 24 小时和近 7 天的按小时汇总，由本地历史加上内存中当前小时组成。
- 验收：
  - 离线自测：用假时钟和假客户端，覆盖启动接检查点、内核重启、socket 不可用后恢复、睡眠时暂停（`coverage_seconds` 不增加）、写盘失败重试、30 天裁剪、关闭开关后不再读取；
  - 实机：`MEOWMAC_LIVE=1 scripts/test.sh <套件>` 读一次真实 socket，断言能解析、连接数大于 0、生成的行通过 SCHEMA 键检查；只把解析和格式检查结论写进 result，数量留在本地验收材料中。沙箱连不上 socket 时写错误原文，标为“需规划者实测”。
- 执行者要求：强推理模型、高推理档位。
- 相关决策点：D3、D6、D7

### 3. 导出到笔记库目录

- 依据：D4；D43 草案中的导出规则。
- 改法：`LocalConfig` 增加 `proxyTrafficExportDirectory`（字符串，默认为空）。不为空时：
  - 每个小时结算到本地后，把同一行追加到 `<目录>/mac/YYYY-MM-DD.jsonl`；
  - `O_APPEND` 打开，一次写入，`fsync`，不建临时文件，不重命名；
  - 追加前完整读取目标日文件（最多 24 行）去重，已有的行不覆盖；
  - 目录不存在时只创建 `mac/` 这一层；父目录不存在时不创建，记日志后跳过；
  - 写失败时下次结算一并重试；
  - 删除 `mac/` 下超过 30 天且文件名符合 `YYYY-MM-DD.jsonl` 的文件。
  - 程序第一次启用导出时，把本地历史中这 30 天里导出目录还没有的小时补写过去。
- 验收：离线自测用 `build/` 下的临时目录，覆盖首次补写（目标日文件已有部分小时、超过 256 KB 时不重复）、追加去重、父目录不存在时跳过、只删过期的符合格式的文件（同目录放一个 `README.md` 和一个 `2026-01-01.txt` 断言不被删除）、导出目录不可写时不影响本地历史。
- 相关决策点：D4

### 4. 代理流量卡片和布局迁移（第 2 轮）

- 依据：D5、D8；设计稿 `design.html`。
- 改法：
  - `PanelLayoutCatalog` 网络页新增 `network.proxy`（标题“代理流量”），默认放在 `network.traffic` 之后、`network.egress` 之前。
  - `PanelLayout.migrated` 照 `network.traffic` 的先例：旧文件网络页恰好只缺 `network.proxy` 时，以可见状态插到 `network.traffic` 之后；同时还缺 `network.traffic` 的，先按旧规则补 `network.traffic`，再补 `network.proxy`。
  - 同步 `docs/design/PANEL_LAYOUT_FORMAT.md` 和 `docs/design/SPEC.md`「网络页」，加入这块卡片的规格（从设计稿的「版式」和「数据口径」改写）。
  - SwiftUI 实现，样式用现有的 `Design` 常量和组件（`SectionHeading`、分组底色、状态色）。柱状图悬停用原生提示。
- 验收：
  - 离线自测：布局迁移（只缺 `network.proxy`、两者都缺、缺其他项时拒绝）；卡片数据计算（合计、经代理占比、Top 5 进程用 `by_process` 跨小时累加后排序（含排名反例）、展开后的 Top 5 域名和最多的规则与节点取自 `items`，展开区末行显示“基于保留明细 · 未保留明细 X”（所选范围内 `other` 合计），某个进程在 `items` 里没有明细时显示“明细未保留”而不是空列表、MATCH 占比 ≥ 30% 时着橙色、无记录的小时、当前小时、单位换算的边界值 1023 KB / 1 MB / 1 GB）；
  - 合成数据预览图：设计稿的六种状态各一张，浅色和深色，放在 `build/acceptance/preview/`，和设计稿逐项对照，偏差写进 result；
  - 首屏规则：SPEC 中网络页首屏要求不受影响（新卡片在速率之后，可以滚动到达）。
- 执行者要求：强推理模型、高推理档位。
- 相关决策点：D5、D8

### 5. 安装和实机验收（第 2 轮）

- 改法：`scripts/install.sh` 安装后记下安装完成时刻 T，写进 result；用 `caffeinate -i` 保持唤醒，让 MeowMac 持续运行，直到本地历史里出现一个开始时刻不早于 T、由本次运行结算、`coverage_seconds` ≥ 3000 的小时，最长等 150 分钟。期间不重启 MeowMac、不改配置；性能对照和导出检查放在这之后做。
- 验收：
  - 本地历史中至少有 1 行 `hour` 不早于 T、`coverage_seconds` ≥ 3000，通过 SCHEMA 键检查（只写数值）；T 之前的旧历史保留，但不能用来满足本项。150 分钟内达不到时，写明各小时的 `coverage_seconds` 和读取失败计数，作为 `阻断`；
  - 用 Computer Use 打开面板 → 网络页 → 代理流量卡片：截“今天”“近 7 天”和展开一行各一张，存 `build/acceptance/`，与设计稿对照；
  - 性能：用同一个已安装的构建做两组对照，一组 `proxyTrafficEnabled` 为 `true`，一组为 `false`。每组改完配置后用 `scripts/install.sh` 重启 MeowMac，面板保持关闭，预热 2 分钟，然后 10 分钟内每 30 秒用 `ps -o %cpu=,rss= -p <MeowMac pid>` 采样一次，共 20 个样本。CPU 取 20 个样本的均值，内存取 RSS 的均值。开启组减关闭组：CPU 均值增量 ≤ 0.5 个百分点，RSS 均值增量 ≤ 20 MB。原始样本存 `build/acceptance/perf/`，两组均值只写本地验收材料，result 只写对比增量和结论；
  - 导出不在执行阶段对真实笔记库验证：在 `config.json` 里把导出目录临时指向 `build/acceptance/export/`，过整点后检查 `mac/` 下出现同样的行，测完把配置恢复为空。
- 相关决策点：D4、D6

### 6. 性能对照复测（第 3 轮）

- 依据：D11；第 2 批复审 R1。
- 改法：只做测量，不改应用代码；脚本放 `build/acceptance/perf/`。
  - 两组用同一个已安装构建，与条目 5 的流程相同：备份 `config.json`，只改 `proxyTrafficEnabled`，用 `scripts/install.sh` 重启，面板保持关闭，`caffeinate -i` 保持唤醒。
  - 每组预热 2 分钟，然后测 20 分钟：开始和结束时各读一次进程累计 CPU 时间（`ps -o cputime= -p <pid>`，或 `proc_pid_rusage` 的 user + system），再除以墙钟时长，得到平均 CPU 百分比。
  - 每组 20 分钟测量期间，每 30 秒用 `ps -o rss= -p <pid>` 采一次 RSS。
  - `sample` 只在正式计时窗口之外运行（每组测完之后），只用来定位调用栈，不把样本占比换算成 CPU 百分比：`sample <pid> 20 -file <仓库绝对路径>/build/acceptance/perf/<段名>-sample.txt > build/acceptance/perf/<段名>-sample.log 2>&1`。
  - 按“关闭、开启、关闭”的顺序测三段，用两段关闭组的均值作为基线，以减少时间漂移。
  - 测完逐字节恢复 `config.json`，在 result 写配置逐字节恢复结论，摘要仅保留在本地验收材料中；最后用 `scripts/install.sh` 以恢复后的配置重启。
- 验收：开启组平均 CPU − 关闭组基线 ≤ 0.5 个百分点；RSS 按段取 40 个样本的均值，开启段均值减去两个关闭段均值的平均值 ≤ 20 MB，结束时 RSS 作为补充记录。三段累计 CPU 秒数、墙钟时长、平均 CPU 百分比和 RSS 均值只写本地验收材料，result 只写对比偏差和结论。超标时不改阈值，记为阻断，并在 result 写出 `sample` 里 MeowMac 自身代码的热点调用栈（只写函数名，不写真实数据）。
- 相关决策点：D11

## 规划者保留

- D43 与 AGENTS.md 的写入、提交和 `plan-baseline` 标签移动：已由规划者完成（`0a6c601`）。
- 真实导出：用户实机验收时，在 `config.json` 填写笔记库路径，观察极空间同步后另一端能看到文件。
- 给 Hermes 的 zspace 部署提示词（部分 C）。

## 项目专属自检

- [ ] `scripts/check.sh` 通过，`plan-baseline` 比对通过（开工前标签已移到 D43 的提交）
- [ ] 没有修改 `../tuncanary` 和 `../meowkit`（`git -C ../tuncanary status --short` 和 `git -C ../meowkit status --short` 为空，或只有本 plan 开工前就存在的改动）
- [ ] 夹具和预览图只用虚构数据；`git grep` 不到真实进程名、域名和节点名
- [ ] 只发 `GET` 请求：`git grep -n -E "DELETE|PUT|PATCH"` 在新代码中没有命中
- [ ] 行格式与 SCHEMA 一致（测试断言键集合）
