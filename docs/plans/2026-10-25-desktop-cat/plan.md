# 桌面猫

- 格式：relay-plan v2
- 目标：当前的猫像桌面宠物一样蹲在屏幕角落，头顶的玻璃气泡显示用户选的 1～4 项指标；可拖动吸附、单击开面板、右键选指标，开关和指标在设置里管理。
- 规划：Claude Opus 5.5
- 定稿：2026-10-25
- 复核：无
- 模式：delegate（用户 2026-10-25 指定）
- 执行宿主：Claude Code 子 Agent（每轮一个执行者，按条目的「执行者要求」选模型）
- 复审宿主：Claude Code 全新子 Agent，只读
- 执行规则：`~/.claude/skills/relay/references/execute.md`；本 plan 的例外：无
- 执行者自主权：宽松（见决策点 D12）
- 推荐执行者：强推理模型、高推理档位
- 轮次上限：4
- 用量上限：无
- 结果文档：`docs/plans/2026-10-25-desktop-cat/result.md`

## 总纲

- 开工前提：D45 已由用户批准并写入 `docs/DECISIONS.md`（`a61ffa2`），`plan-baseline` 已移到该提交；设计稿 `docs/design/mockups/mini-window.html` 方案 A 已由用户选定（2026-10-25）。已满足。
- 范围：桌面猫的配置与指标目录；透明置顶窗口、拖动吸附、多屏与位置持久化；猫与气泡视图；右键菜单；设置窗口外观栏“桌面猫”分组和底部设置菜单开关；SPEC 同步；安装、性能和实机验收。
- 不做：新增猫的姿态（坐、打哈欠等）；透明度设置；整窗点击穿透模式；新增数据源或提高任何采集频率；猫在桌面上走动；把桌面猫配置写进猫包；修改 TunCanary；推送。
- 全部条目与轮次：
  - 第 1 轮：条目 1～4（配置与指标目录、窗口与吸附、猫与气泡视图、设置入口与文档）；
  - 第 2 轮：条目 5（安装、性能和实机验收）。
- 整体验收：`scripts/check.sh` 通过；合成预览与设计稿方案 A 逐项一致；安装后打开桌面猫、面板关闭时，10 分钟平均自身 CPU 比关闭桌面猫时高出不超过 1 个百分点；用户实机验收外观、材质、拖动吸附、点击穿透、全屏 App 上的显示、右键菜单和设置分组。

## 背景与已知事实

- 决策：D45（桌面猫）、D11（速度只表示负载）、D12（健康形态）、D20（猫包边界）、D33（液态玻璃）、D36（菜单栏猫）、D38（设置窗口与即时生效规则）、D42（提醒规则，提醒档位来源）。
- 设计稿：`docs/design/mockups/mini-window.html`，以方案 A 和页面底部「口径」为准，方案 B、C 只作对比。本地查看要用 HTTP 打开（帧图是相对路径），例如在 `docs/design` 下 `python3 -m http.server`；`file://` 打开时猫不显示。
- 猫的现有实现：
  - `Sources/MeowMacUI/CatRenderer.swift:4` 的 `CatDisplay`（负载、帧间隔、速度线、模板、停止、减少动态效果）和 `PanelState.catDisplay()`（第 21 行），`CatRenderer.image(cat:display:frame:size:)`（第 34 行，默认 50×18）。
  - `Sources/MeowMacUI/MenuBarCatImage.swift`：菜单栏图像缓存和赋值。
  - `Sources/MeowMacUI/ApplicationCadence.swift:5`：唯一的帧计时器 `scheduleFrame` 和 2 秒采样计时器；`MeowMacApplication.updateCatImage()`（`MeowMacApplication.swift:376`）在每帧更新菜单栏。
  - 帧图合同：`docs/design/CAT_FORMAT.md`、SPEC「菜单栏猫」。
- 应用入口：`Sources/MeowMacUI/MeowMacApplication.swift:58`（`applicationDidFinishLaunching`，状态栏、弹出面板、各协调器装配）、`togglePopover`（第 302 行）、`openPanel(at:)`（第 290 行）、`panelState.onOpenSettings`（第 132 行）。
- 总览指标：`Sources/MeowMacUI/PanelView.swift:329`（`OverviewMetric`）、`overviewMetrics(for:)`（第 354 行）、`overviewColor(for:)`（第 347 行）；额度窗口选择器 `Sources/MeowMacCore/PanelLayout.swift:40`（`selectedWindow(in:)`）、第 48 行（`selector(for:among:)`）。指标格式和颜色尽量复用这些，不另写一套口径。
- 配置：`Sources/MeowMacCore/LocalConfig.swift`（`LocalConfig` 字段、`CodingKeys`、`ConfigStore.load`、`saveField`/`updateObject` 只改单字段并保留未知字段）。
- 设置：`Sources/MeowMacUI/SettingsWindow.swift:119`（`SettingsWindowController`、`open(section:)`）、`Sources/MeowMacUI/AppearanceSettings.swift`（外观栏的样式与布局草稿，“取消 / 保存”）、`Sources/MeowMacUI/ImmediateSettings.swift`（即时生效的写法）、`Sources/MeowMacUI/SettingsMenu.swift:12`（底部设置菜单）。
- 性能测量：`scripts/profile-self.sh`（即 `scripts/self-performance.py`），`live` 子命令按 PID 测已安装应用，原值只写 `build/acceptance/self-performance/`。2026-10-23 的参考：面板关闭时自身约 2.9%。
- 预览：`MEOWMAC_RENDER_DIR` 合成渲染（`Sources/MeowMacUI/PanelPreviewRenderer.swift`，`Sources/MeowMacSelfTest/LayoutAcceptanceTests.swift:62`）。
- 宿主限制：Claude Code 子 Agent 没有 Computer Use。真实材质、拖动手感、点击穿透和全屏 App 上的显示由用户实机验收，执行者不尝试其他截屏或注入鼠标事件的方式。

## 必读

- `AGENTS.md`、`docs/DECISIONS.md`（重点 D45，以及 D11、D12、D20、D33、D36、D38）。
- 设计稿 `docs/design/mockups/mini-window.html` 方案 A 与「口径」；`docs/design/SPEC.md`「菜单栏猫」「材质」「颜色」「字号」「统一设置窗口」。
- 同类任务的历史坑：`docs/plans/2026-10-24-battery/result.md` 复审节（前台用例必须实跑、不放宽断言；原生材质截不到时交用户实机验收）；`docs/plans/2026-10-07-alert-rules/` 的教训：状态类配置要覆盖新建、编辑、停用、删除、恢复默认、坏配置六条路径。

## 授权范围

- 允许：本地 git commit；`scripts/check.sh`、`scripts/test.sh`、`scripts/build-app.sh`；`scripts/install.sh`（按 AGENTS.md 让旧进程正常退出，第 2 轮也用它重启应用）；只读查询窗口列表（`CGWindowListCopyWindowInfo`）核实桌面猫窗口是否在屏；`shasum` 比对构建与安装产物；`scripts/profile-self.sh live` 测已安装应用；第 2 轮运行 `MEOWMAC_UI_TESTS=1 scripts/test.sh <过滤词>` 的前台用例（会弹出 MeowMac 自己的窗口）；验收期间用 `caffeinate -i -w <pid>` 防止空闲睡眠；在 `build/` 下写测试输出、预览图和测量数据；第 2 轮按 AGENTS.md 的例外临时修改 `config.json` 中的桌面猫字段（只限本 plan 新增的那一个字段，修改前备份，验收后逐字节恢复）。
- 不允许：推送；修改 TunCanary；`sudo` 或修改系统设置；结束任何进程（`scripts/install.sh` 的正常退出除外）；Computer Use 或注入鼠标、键盘事件；改 `config.json` 中桌面猫以外的字段；在设置窗口里点保存。没列在“允许”里的都不允许。
- 权限请求被拒时不自行绕开；在 result 记录原文，把相关验收标为“需规划者实测”。

## 决策点

类型：`偏好`（执行者不能改）、`技术`（执行者可凭证据更正或提异议）、`安全`（只能收紧）。

| 编号 | 类型 | 问题 | 结论 |
|---|---|---|---|
| D1 | 偏好 | 版式 | 已定：按设计稿方案 A 和「口径」。猫高 52 pt；气泡在猫头顶，离猫 10 pt，右边缘与猫对齐（左侧的角时左对齐、尾巴镜像），圆角 14 pt，内边距 8 × 11 pt；指标 2 列（1 项时 1 列），每项宽 66 pt，列距 12 pt，行距 7 pt；每项是标签 10 pt、数值 15 pt 半粗、2 pt 横线。 |
| D2 | 偏好 | 默认与上限 | 已定：默认关闭；默认指标 CPU、内存压力、Claude 5 小时剩余、网速；1～4 项，顺序即显示顺序。 |
| D3 | 偏好 | 窗口行为 | 已定：始终置顶，所有桌面空间和全屏 App 上都显示，不抢焦点，不进 ⌘Tab 和调度中心；只有猫和气泡的不透明部分接收鼠标，透明处点击穿过去；不提供透明度设置。 |
| D4 | 偏好 | 鼠标交互 | 已定：拖动猫或气泡移动，松手落到所在屏幕最近的角（可见区域内，底边上方 8 pt、侧边 16 pt），0.2 秒动画，减少动态效果时直接落位；移动不到 4 pt 算单击，单击打开面板（行为同点菜单栏猫）；拖动中猫定格第 1 帧、放大 6%、倾斜约 4°。 |
| D5 | 偏好 | 右键菜单 | 已定：打开面板；指标 ▸（四类分组，已选打勾，点击即增减；满 4 项时其余变灰，只剩 1 项时不能取消）；桌面猫设置…（打开设置窗口外观栏并定位到桌面猫分组）；让猫回去（关闭）。 |
| D6 | 偏好 | 设置入口 | 已定：外观栏现有内容之下新增“桌面猫”分组：开关、位置（文字 + “放回右下角”按钮）、指标列表（拖动排序、减号删除、“添加指标…”弹出同一分组目录）。即时生效，不进外观栏“取消 / 保存”草稿，不点亮侧栏未保存橙点；外观栏“恢复默认…”不含桌面猫。底部设置菜单增加“显示桌面猫”开关项（打勾表示开）。 |
| D7 | 偏好 | 缺数据与文字溢出 | 已定：已选指标暂时没有数据显示灰色“—”，横线留空，不替换、不删除该项，配置里保留其 id；数值放不下时等比缩小字号，最小 12 pt，不出现省略号；标签放不下时先去掉右侧附注，名称不截断。 |
| D8 | 技术 | 配置形态 | 允许默认：`config.json` 新增一个字段 `desktopCat`（对象）：`enabled`（布尔，默认 false）、`metrics`（字符串数组）、`placement`（`{ "display": <稳定标识字符串>, "corner": "topLeft|topRight|bottomLeft|bottomRight" }`，默认主屏右下角）。只通过单字段写入保存，保留其他字段和未知字段。坏值的处理：类型错误或整个字段无法解析 → 整个 `desktopCat` 按默认值运行，记一条不含路径的日志，不改写文件，直到用户在界面里修改；`metrics` 中重复项去重、超过 4 项取前 4 项、全部无效时回到默认 4 项，未知 id 跳过但不从文件删除（用户在界面修改后才按当前有效列表写回）；`corner` 无效回到右下角。显示器标识用 `CGDisplayCreateUUIDFromDisplayID` 的 UUID 字符串，执行者可凭证据换成更稳定的标识。 |
| D9 | 技术 | 指标 id 与目录 | 允许默认：id 用稳定字符串：`system.cpu`、`system.memory`、`system.power`、`system.disk`、`sensor.temperature`、`sensor.fan`、`battery.level`、`quota.<provider>.<window>`（`<window>` 复用 `PanelLayout.selector(for:among:)` 的选择器口径）、`quota.<provider>.balance`、`quota.cost.today`、`network.speed`、`network.status`、`network.proxy.today`。目录只列当前可用项：额度类按已启用渠道和该渠道实际返回的窗口生成，余额型渠道只有余额；本机没有电池时不列 `battery.level`；读不到风扇或 SoC 温度的机器不列对应项。已选但当前不在目录里的项按 D7 显示“—”。数值、颜色口径按设计稿目录表，能复用总览口径的一律复用。 |
| D10 | 技术 | 刷新与渲染 | 允许默认：不新增计时器。猫的帧跟随 `ApplicationCadence` 现有帧计时器（与菜单栏同一帧号），气泡数值在现有快照或各数据源发布新值时更新。桌面猫关闭时不建窗口，或窗口不在屏幕上且不接收更新、不渲染；系统屏幕休眠时随帧计时器一起停。大尺寸猫图按 `(猫 id, 帧, 档位, 外观, 速度线, 尺寸)` 缓存，同一帧不重复光栅化。 |
| D11 | 技术 | 点击穿透的做法 | 允许默认：无边框、`isOpaque = false`、背景透明的 `NSPanel`（`.nonactivatingPanel`，层级 `.floating`，`collectionBehavior` 含 `canJoinAllSpaces`、`fullScreenAuxiliary`、`stationary`、`ignoresCycle`）。透明处的穿透优先依赖窗口服务器对全透明像素的命中规则；实测不可靠时，改为按鼠标位置是否落在猫图不透明像素或气泡圆角矩形内切换 `ignoresMouseEvents`，监听用全局与本地鼠标移动事件，不轮询。两种做法都要有离线用例覆盖命中判断函数。 |
| D12 | 偏好 | 执行者自主权 | 已定：宽松。不部署，不写线上数据，不改系统设置。 |
| D13 | 偏好 | 多屏与屏幕变化 | 已定（用户 2026-10-25 选定）：位置只存显示器标识 + 角。启动、`NSApplication.didChangeScreenParametersNotification`、程序坞或菜单栏变化时按该屏当前 `visibleFrame` 重新落位；找不到该屏时放到主屏同一个角，不改写已存的显示器标识（屏幕接回后回到原屏）。拖到另一块屏后松手，存新屏标识。 |


## 进度

| 编号 | 条目 | 档位 | 状态 | 提交 |
|---|---|---|---|---|
| 1 | 桌面猫配置与指标目录 | 需强模型 | 未开始 | |
| 2 | 透明窗口、拖动吸附与多屏 | 需强模型 | 未开始 | |
| 3 | 猫与气泡视图 | 需强模型 | 未开始 | |
| 4 | 右键菜单、设置入口与文档同步 | 需强模型 | 未开始 | |
| 5 | 安装、性能和实机验收 | 可交付 | 后续轮次 | |

## 执行清单

### 1. 桌面猫配置与指标目录

- 依据：D45；D2、D7、D8、D9。
- 改法：
  - `MeowMacCore`：新增桌面猫配置模型（开关、指标列表、位置），接进 `LocalConfig` 的解码和 `CodingKeys`，按 D8 容错；提供只写 `desktopCat` 字段的保存函数（沿用 `ConfigStore` 单字段写法）。
  - `MeowMacCore`：指标 id 的解析与校验、目录项模型（分类、显示名、是否可用）、纯函数“给定快照与已选 id → 每项的标签、附注、数值文本、横线比例与颜色角色、是否缺数据”。不在 Core 做 I/O。若数值所需数据只在 `MeowMacUI` 的类型里，目录和取值放 `MeowMacUI`，Core 只放 id、配置和校验，按分层规则取舍并在 result 说明。
  - 额度窗口的 id 复用 `PanelLayout.selector(for:among:)`，与总览“额度窗口”选择一致。
- 验收：`scripts/test.sh` 新增套件，夹具全部虚构，覆盖状态路径：
  - 新建：无字段时默认关闭、默认 4 项、右下角；打开后写回的 JSON 只新增 `desktopCat`，其他字段和未知字段逐字节不变（以解析后比较为准，键序不要求）。
  - 编辑：增、减、重排指标；改角和屏；减到 1 项后拒绝再减；第 5 项拒绝。
  - 停用再启用：指标和位置保持。
  - 删除：不适用（没有删除整个配置的入口）；单个指标的删除归入“编辑”。
  - 恢复默认：不适用（外观栏“恢复默认…”不含桌面猫，D6）；加一条用例证明外观恢复默认不改动 `desktopCat`。
  - 坏配置：`desktopCat` 类型错误、`metrics` 非数组、重复、超过 4 项、全部未知、`corner` 非法、整个 `config.json` 无效时保存被拒且不覆盖原文件。
  - 目录：渠道被移除后其窗口不在目录、已选项显示“—”且 id 保留；无电池不列电量；余额型渠道只有余额；每类指标的数值文本、单位、颜色角色与设计稿目录表一致（含 0、缺测、超大网速 `↓128.6M`）。
- 执行者要求：强推理模型、高推理档位。
- 相关决策点：D2、D7、D8、D9

### 2. 透明窗口、拖动吸附与多屏

- 依据：D45；D3、D4、D11、D13。
- 改法：
  - `MeowMacUI` 新增桌面猫窗口控制器：按 D11 建窗口；按配置显示或隐藏；内容大小随指标数变化，变化时保持所贴的角不动。
  - 拖动：按下后移动不到 4 pt 松手算单击 → 调用与菜单栏猫相同的开面板入口（`MeowMacApplication` 里抽一个公共方法，不复制 `togglePopover` 的逻辑）；超过 4 pt 进入拖动，松手后按“所在屏 `visibleFrame` 中离窗口中心最近的角”落位，存配置。
  - 多屏和屏幕变化按 D13（设计稿「口径·位置」已同步为“接回后回到原屏”）。
  - 命中判断写成纯函数（输入：猫图 alpha 掩码或其外接区域、气泡圆角矩形、点）→ 便于离线测。
- 验收：
  - 离线用例：最近角计算（四角、屏幕中线附近、多屏 visibleFrame 带菜单栏和程序坞偏移）；4 pt 单击阈值；指标数变化时角固定；找不到屏时落到主屏同一个角且不改写已存标识、该屏接回后回到原屏；命中判断（猫不透明像素、猫透明像素、气泡内、气泡圆角外、尾巴）。
  - 前台用例（第 2 轮跑，`MEOWMAC_UI_TESTS=1`）：窗口 `level`、`collectionBehavior`、`isOpaque`、`hasShadow`、`canBecomeKey`/`canBecomeMain` 为假；显示后 frame 落在主屏 `visibleFrame` 右下角并留出 D4 的边距。
- 执行者要求：强推理模型、高推理档位。
- 相关决策点：D3、D4、D11、D13

### 3. 猫与气泡视图

- 依据：D45；D1、D7、D10；设计稿方案 A；SPEC「菜单栏猫」「材质」「颜色」。
- 改法：
  - 猫：用 `CatRenderer` 按 52 pt 高渲染当前猫（与菜单栏同一帧号、同一 `CatDisplay`），正常单色猫在浅色外观用 `labelColor` 近黑、深色外观近白，并加 1 pt 反色描边；提醒橙、严重睡姿红；彩色猫保留原色；速度线规则同菜单栏；减少动态效果定格第 1 帧。脚下柔和投影。缓存按 D10。
  - 气泡：SwiftUI 视图，玻璃材质（macOS 26 `glassEffect`；macOS 14～15 `.hudWindow` 材质的 `NSVisualEffectView` 加 0.5 pt 描边），不叠加面板暖色渐变；尾巴指向猫头。数值文字状态色用 SPEC 成对颜色。
  - 悬停某项 0.6 秒显示原生提示：全称和数据时间（例如“Claude 5 小时窗口剩余 72% · 13:57 更新”）。
  - 预览：`MEOWMAC_RENDER_DIR` 下渲染合成预览：正常 4 项、提醒、严重 3 项、2 项含缺数据、1 项、超长网速，各浅色和深色，放 `build/acceptance/desktop-cat/preview/`。
- 验收：
  - 预览图与设计稿方案 A 逐项对照（元素顺序、尺寸与间距偏差不超过 2 pt、字号字重、无省略号、深色可读），偏差写进 result。
  - 离线用例：帧号与菜单栏一致；同一帧不重复光栅化（计数器断言）；关闭状态下快照更新不触发气泡渲染（计数器断言）；缩字规则（最小 12 pt）与附注去除规则。
- 执行者要求：强推理模型、高推理档位。
- 相关决策点：D1、D7、D10

### 4. 右键菜单、设置入口与文档同步

- 依据：D45；D5、D6；设计稿「右键菜单」「设置 › 外观 › 桌面猫」。
- 改法：
  - 右键菜单按 D5，用原生 `NSMenu`，菜单构建写成可测的函数（输入目录与已选 → 菜单项标题、勾选、可用状态），参照 `SettingsMenu` 的写法。
  - 设置窗口外观栏按 D6 新增分组，即时写配置；“桌面猫设置…”能打开设置窗口并滚动到该分组（`SettingsWindowController.open(section:)` 扩展一个定位参数或等效做法）。
  - 底部设置菜单增加“显示桌面猫”勾选项。
  - 同步 `docs/design/SPEC.md`：新增「桌面猫」一节（从设计稿方案 A 与「口径」改写），「统一设置窗口」补外观栏分组和即时生效的例外。
- 验收：
  - 离线用例：右键菜单的项、分组、勾选，满 4 项时未选项不可用，只剩 1 项时已选项不可用；设置模型的增、删、重排、开关、放回右下角都即时写配置，且外观栏 `isDirty` 不变；底部设置菜单含“显示桌面猫”且勾选状态跟随配置。
  - `scripts/check.sh` 通过。
- 执行者要求：强推理模型、高推理档位。
- 相关决策点：D5、D6

### 5. 安装、性能和实机验收（第 2 轮）

- 依据：整体验收；D2、D3、D10。
- 改法：只做验证，不改应用代码（发现缺陷记入 result，由规划者决定修复轮次）；验收脚本和原值放 `build/acceptance/desktop-cat/`。
  1. `scripts/build-app.sh` 构建，成功后 `scripts/install.sh` 安装；result 记录本轮提交号，以及 `build/MeowMac.app` 与 `~/Applications/MeowMac.app` 主可执行文件的哈希一致。
  2. 前台用例：`MEOWMAC_UI_TESTS=1 scripts/test.sh <桌面猫相关过滤词>`，以及外观设置、布局设置相关的既有前台用例；result 写命令、退出码和通过数。
  3. 性能：配置只在启动时读取，所以每次改完都要重启应用，重启只用 `scripts/install.sh`（它让旧进程正常退出再启动），不直接结束进程。
     1. 备份 `config.json`。
     2. 把 `desktopCat.enabled` 设为 false（字段不存在时新增只含 `enabled: false` 的 `desktopCat`），运行 `scripts/install.sh` 重启；用 `CGWindowListCopyWindowInfo` 只读核实 MeowMac 没有桌面猫窗口在屏、面板关闭；再用 `scripts/profile-self.sh live` 测 600 秒。
     3. 设为 true（其余默认），`scripts/install.sh` 重启；同样核实桌面猫窗口在屏、面板关闭；测 600 秒。
     4. 两次测量期间不打开面板、不改其他配置。
     5. 逐字节恢复 `config.json`，`scripts/install.sh` 重启。比较两次的平均自身 CPU。
- 验收：
  - 前台用例全部通过；失败或因权限阻塞时写原文和原因，标“未通过”或“需规划者实测”，条目 5 不得标为已完成；不放宽断言。
  - 开启比关闭的平均自身 CPU 高出不超过 1 个百分点；result 只写两边的差值和是否达标，原值放 `build/acceptance/desktop-cat/`。
  - `config.json` 恢复后与备份逐字节一致（`cmp` 通过）。
  - `scripts/check.sh` 通过。
- 用户实机验收（执行者做完后由规划者请用户做）：设置里打开桌面猫 → 右下角出现猫和气泡，对照设计稿看版式与玻璃；切换浅色和深色；拖到左上角和另一块屏；点气泡和猫打开面板；点猫旁边的透明处能点到下面的窗口；全屏 App 上仍显示；右键加减指标和“让猫回去”；设置里排序、删除、添加；制造一次提醒（或 `MEOWMAC_FORCE_LEVEL=warn`）看猫变橙。
- 相关决策点：D2、D3、D10

## 规划者保留

- D45 写入和 `plan-baseline` 移动：已完成（`a61ffa2`）。
- 用户实机验收：材质、拖动手感、点击穿透、全屏 App 上的显示、多屏。

## 项目专属自检

- [ ] `scripts/check.sh` 通过，`plan-baseline` 比对通过
- [ ] 没有修改 `../tuncanary`（`git -C ../tuncanary status --short` 为空）
- [ ] 没有新增计时器或采集频率：`git diff plan-baseline -- Sources | grep -nE 'Timer\.scheduledTimer|DispatchSourceTimer|asyncAfter'` 的新增行逐条说明理由（拖动落位动画除外）
- [ ] 桌面猫配置只写 `desktopCat` 一个字段；没有写进猫包
- [ ] 夹具和预览图只用虚构数据；`build/acceptance/` 以外没有真实读数
- [ ] 第 2 轮结束后 `config.json` 与备份逐字节一致
