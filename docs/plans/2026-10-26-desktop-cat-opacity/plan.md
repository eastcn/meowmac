# 桌面猫：透明度

- 格式：relay-plan v2
- 目标：设置里可以分别调桌面猫的猫和气泡的不透明度（20%～100%）；鼠标停上去时两者变回 100%，离开后回到设定值。
- 规划：Claude Opus 5.5
- 定稿：2026-10-26
- 复核：无
- 模式：delegate（用户 2026-10-26 指定）
- 执行宿主：Claude Code 子 Agent（一个执行者）
- 复审宿主：Claude Code 全新子 Agent，只读
- 执行规则：`/Users/yanxiaodong/.claude/skills/relay/references/execute.md`；本 plan 的例外：无
- 执行者自主权：宽松（见决策点 D9）
- 推荐执行者：强推理模型、高推理档位
- 轮次上限：3
- 用量上限：无
- 结果文档：`docs/plans/2026-10-26-desktop-cat-opacity/result.md`

## 总纲

- 开工前提：
  - D48 已写入 `docs/DECISIONS.md`（`a75c9b3`，用户 2026-10-26 批准），`plan-baseline` 已移到该提交。已满足。
  - 设计稿 `docs/design/mockups/mini-window.html`「透明度（D48）」一节和设置示意已由用户确认（2026-10-26）。已满足。
  - 性能工具 CPU 单位修复（`df74e34`）已按用户要求合并进 main（`4dec241`）。已满足。
- 范围：`desktopCat` 新增猫和气泡两个不透明度字段；显示时按设定值淡化，悬停、拖动、缩放时变回 100%；设置分组新增两个滑块和“恢复默认”；SPEC 和合成预览同步；安装、性能和实机验收。
- 不做：
  - 右键菜单里的透明度项；
  - 整窗 `alphaValue` 方案（猫和气泡要分开调）；
  - 改变点击穿透规则（透明度不影响命中范围）；
  - 落点框、缩放把手的透明度；
  - 进猫包；
  - 新增计时器或轮询；
  - 修改 TunCanary；推送。
- 全部条目与轮次：第 1 轮：条目 1～4。
- 整体验收：
  - `scripts/check.sh` 通过。
  - 合成预览与设计稿「透明度（D48）」逐项一致。
  - 已安装应用开着桌面猫、面板关闭时，猫和气泡都设 40% 比都设 100%，480 秒平均自身 CPU 高出不超过 0.5 个百分点（用合并修复后的 `scripts/profile-self.sh live`）。
  - 用户实机验收：两种透明度在浅色、深色壁纸上的观感；悬停变实和回落的手感；20% 时仍能拖、单击、右键；液态玻璃在半透明时的效果。

## 背景与已知事实

- 决策：D48（本任务）、D45（桌面猫）、D46（结束提示）、D47（大小）、D33（材质）。
- 现有实现：
  - 配置 `Sources/MeowMacCore/DesktopCat.swift`：`DesktopCatConfig`（第 43 行），`CodingKeys` 在第 64 行，`catHeight` 的按字段回退在第 88～92 行，手写的 `==` 在第 107 行（新增字段必须加进去）。单字段保存 `LocalConfig.saveDesktopCatHeight`（第 583 行）是本任务保存函数的样板。
  - 视图 `Sources/MeowMacUI/DesktopCatView.swift`：`DesktopCatContentView` 把气泡、猫（`DesktopCatFigure`，含投影）、把手和结束提示叠在一个 `ZStack` 里。速度线画在猫图里（`DesktopCatImage`）。
  - 气泡材质：macOS 26 `glassEffect(.regular, in:)`（第 145 行）；macOS 14～15 是 `NSVisualEffectView` 的 `.hudWindow`（第 227～231 行）。结束提示同理（第 179～191 行）。
  - 鼠标：`Sources/MeowMacUI/DesktopCatWindow.swift` 的 `updateMouseThrough`（约第 372 行）由全局和本地 `mouseMoved` 监视器驱动，不轮询；把手的 0.3 秒隐藏用 `DispatchWorkItem`（`updateHandle`）。命中用 `hitShape()`，猫的部分按帧图的 alpha 蒙版（`alphaMask`，约第 432 行），和视图的显示透明度无关。拖动和缩放期间 `updateMouseThrough` 直接返回。
  - 设置 `Sources/MeowMacUI/DesktopCatSettings.swift`：大小滑块在第 202～225 行，拖动只改草稿、松手写入，是透明度滑块的样板。
  - 合成预览 `Sources/MeowMacUI/DesktopCatPreview.swift`。
  - 已有用例：`Sources/MeowMacSelfTest/DesktopCatConfigTests.swift`、`DesktopCatSizeTests.swift`、`DesktopCatSettingsTests.swift`、`DesktopCatViewTests.swift`、`DesktopCatWindowTests.swift`。
- 性能工具：`scripts/profile-self.sh live` 测已安装应用。`df74e34` 之前 CPU 百分比小约 41.7 倍，以前的测量值不能和本次直接比，本次只比同一工具下的两组读数。上一个任务的性能对比因单次读数波动大于门槛没通过，所以本次 A、B 交替各测两次。
- 宿主限制：Claude Code 子 Agent 没有 Computer Use，截不到真实液态玻璃。半透明玻璃的观感由用户实机验收。

## 必读

- `AGENTS.md`；`docs/DECISIONS.md` 的 D48，以及 D45、D47。
- 设计稿「透明度（D48）」和「设置 › 外观 › 桌面猫」两节；`docs/design/SPEC.md`「桌面猫」和外观栏桌面猫分组那一段（约第 222 行）。
- 同类任务的历史坑：
  - `docs/plans/2026-10-25-desktop-cat/result.md` 复审节：前台用例必须实跑，不放宽断言；原生材质截不到时交给用户实机验收。
  - `docs/plans/2026-10-07-alert-rules/` 的教训：状态类配置要覆盖新建、编辑、停用、删除、恢复默认、坏配置六条路径。
  - `docs/plans/2026-10-25-desktop-cat-sessions/result.md` 第 3 轮：性能读数波动，要交替测量、固定显示器。

## 授权范围

- 允许：
  - 本地 git commit。
  - `scripts/check.sh`、`scripts/test.sh`、`scripts/build-app.sh`、`scripts/install.sh`。`install.sh` 按 AGENTS.md 让旧进程正常退出，条目 4 也用它重启应用。
  - `scripts/profile-self.sh live` 测已安装应用；`caffeinate -i -w <pid>`。
  - 条目 4 运行 `MEOWMAC_UI_TESTS=1 scripts/test.sh <过滤词>` 的前台用例。
  - 在 `build/` 下写测试输出、预览图和测量数据。
  - 条目 4 按 AGENTS.md 的例外临时修改 `config.json` 的 `desktopCat.enabled`、`desktopCat.catOpacity`、`desktopCat.bubbleOpacity` 三个字段。修改前备份，验收后逐字节恢复。
- 不允许：
  - 推送；修改 TunCanary；修改 `AGENTS.md`、`CLAUDE.md`、`docs/DECISIONS.md`。
  - 改 `config.json` 中上面三个字段以外的内容。
  - `sudo` 或修改系统设置；结束任何进程（`scripts/install.sh` 的正常退出除外）。
  - Computer Use，或注入鼠标、键盘事件。
  - 提交 `docs/plans/2026-10-25-desktop-cat-sessions/result.md`（另一个会话的未提交改动，保持原样）。
- 没列在“允许”里的都不允许。
- 权限请求被拒时不自行绕开；在 result 记录原文，把相关验收标为“需规划者实测”。

## 决策点

类型：`偏好`（执行者不能改）、`技术`（执行者可凭证据更正或提异议）、`安全`（只能收紧）。

| 编号 | 类型 | 问题 | 结论 |
|---|---|---|---|
| D1 | 偏好 | 调哪部分 | 已定（用户 2026-10-26）：猫和气泡分开调。猫的透明度连同投影、速度线；气泡的透明度连同结束提示（D46）。落点框和缩放把手不受影响。 |
| D2 | 偏好 | 范围和默认值 | 已定（用户 2026-10-26）：各自 20%～100%，步长 5%，默认 100%。 |
| D3 | 偏好 | 悬停 | 已定（用户 2026-10-26）：鼠标在猫的不透明像素、气泡、结束提示或显示中的把手上时，猫和气泡都过渡到 100%；离开后 0.3 秒回到设定值，期间回来就取消回落。拖动和缩放期间保持 100%，松手后按鼠标位置决定。“减少动态效果”开启时直接切换。 |
| D4 | 偏好 | 点击穿透 | 已定（用户 2026-10-26）：不变。命中仍按猫图的 alpha 蒙版和气泡、提示、把手的形状，与显示透明度无关。 |
| D5 | 偏好 | 入口 | 已定（用户 2026-10-26）：只在设置外观栏的桌面猫分组，“大小”下面依次是“猫的不透明度”“气泡不透明度”两个滑块，右侧显示百分比；气泡那一行末尾是“恢复默认”按钮，两项都是 100% 时变灰。拖动时只改显示（桌面猫实时跟着变），松手写配置；即时生效，不进外观栏草稿。右键菜单不加。版式见设计稿「设置 › 外观 › 桌面猫」。 |
| D6 | 技术 | 配置字段 | 允许默认：`desktopCat.catOpacity` 和 `desktopCat.bubbleOpacity`，数字，取值 0.2～1.0。缺省为 1.0。读取时按字段回退：不是数字、小于 0.2 或大于 1.0 时这一项按 1.0 显示，不改写文件，记一条不含路径的诊断，例如“桌面猫的气泡不透明度无效，已按 100% 显示”；其他字段不受影响。合法但不在 5% 步长上的值照原值显示，滑块位置和百分比文字按四舍五入到 5% 显示。写入时先吸附到 5% 步长再夹到 0.2～1.0。保存用一个单字段函数（同 `saveDesktopCatHeight`）：只改这一个键，`desktopCat` 的其他字段和未知字段的值保留（文件会被重新格式化，不保证原始字节）；`desktopCat` 不存在或不是对象时退回整个桌面猫配置保存。“恢复默认”一次写两个键为 1.0（一次写盘）。 |
| D7 | 技术 | 显示实现 | 允许默认：在 SwiftUI 里分别对猫（`DesktopCatFigure`，含投影）和气泡、结束提示加 `.opacity`，不用窗口的 `alphaValue`。把手不加。玻璃材质下若 `.opacity` 直接作用于 `glassEffect` 视图出现边缘发白或模糊层不变淡，可改为先 `compositingGroup()` 再加透明度，或换别的写法，做法和理由写进 result。过渡 0.15 秒 `easeInOut`。 |
| D8 | 技术 | 悬停状态 | 允许默认：视图模型增加“是否变实”状态，由 `updateMouseThrough` 用 `hitShape().contains` 的结果驱动，回落用 `DispatchWorkItem` 延迟 0.3 秒，不新增计时器和轮询。拖动、缩放开始时置为变实，结束时按鼠标位置重新判断。打开右键菜单期间保持变实（菜单弹出时鼠标在猫上）。 |
| D9 | 偏好 | 执行者自主权 | 已定：宽松。不部署，不写线上数据，不改系统设置。 |

## 进度

| 编号 | 条目 | 档位 | 状态 | 提交 |
|---|---|---|---|---|
| 1 | 透明度配置 | 可交付 | 已交付，待复审 | `71ced34` |
| 2 | 显示与悬停变实 | 需强模型 | 已交付，待复审 | `61ac6ea` |
| 3 | 设置入口与文档同步 | 可交付 | 已交付，待复审 | `4abc344` |
| 4 | 安装、性能和实机验收 | 可交付 | 已交付，待复审（性能读数不稳定，见 result） | `b915591`；本轮提交：docs: record desktop cat opacity round 1 |

## 执行清单

### 1. 透明度配置

- 依据：D48；D2、D6。
- 改法：`DesktopCatConfig` 增加两个字段、解码回退、编码、`==`、`with(...)` 构造方法和校验；`LocalConfig` 增加单字段保存和“恢复默认”的两键保存；吸附和夹取写成纯函数，放在 `MeowMacCore`。
- 验收（离线用例，按六条路径）：
  - 新建：配置里没有这两个键时都是 1.0；第一次保存只新增对应的键。保存沿用 `LocalConfig.updateObject`，它会重新格式化整个 JSON，所以这里按解析后的对象比较：其他字段（含 `desktopCat` 内外的未知字段）的值不变，不要求原始字节不变（预审 P1）。下面“只改了这一个键”“其他字段不变”都按这个口径。
  - 编辑：保存 0.4 后重新读取是 0.4；只改了这一个键。0.43 写入为 0.45，0.12 写入为 0.2，1.3 写入为 1.0。
  - 停用：`enabled` 改为 false 再改回 true，两个透明度保持不变。
  - 删除：手动删掉键后读取为 1.0，不产生诊断。
  - 恢复默认：两个键都写成 1.0，一次写盘；其他字段不变（解析后比较）。
  - 坏配置：字符串、`null`、负数、0.1、1.5 分别按 1.0 读取，文件不改写，诊断不含路径，且 `metrics`、`placement`、`catHeight` 等其他字段照常读取；0.33 这类合法非步长值原样读取。
  - 原有的桌面猫配置用例不改断言。
- 相关决策点：D2、D6

### 2. 显示与悬停变实

- 依据：D48；D1、D3、D4、D7、D8；设计稿「透明度（D48）」。
- 改法：
  - 视图模型增加两个设定值和“变实”状态；`DesktopCatContentView` 按 D7 分别给猫和气泡、提示加透明度。
  - `DesktopCatWindow`：配置变化时把设定值同步到视图模型；按 D8 驱动“变实”和 0.3 秒回落；拖动、缩放、右键菜单期间保持变实。
  - 合成预览：`DesktopCatPreview` 增加透明度的场景。
- 验收：
  - 离线用例：
    - 显示用的透明度：设定 0.4 / 0.6 时，不悬停分别是 0.4 和 0.6；悬停时都是 1.0；离开后 0.3 秒前仍是 1.0，之后回到设定值；0.3 秒内回来不回落；拖动和缩放期间是 1.0。可以把延迟和时钟注入成参数来测，不用真实等待。
    - 命中：同一鼠标位置，设定 0.2 和 1.0 时 `hitShape().contains` 的结果相同（猫内、气泡内、透明处各一点）。
    - 把手和落点框的透明度不随设定变化。
    - 不新增计时器：对窗口控制器的计时器或监视器计数断言，开启透明度前后数量相同。
  - 合成预览：输出到 `build/acceptance/desktop-cat-opacity/preview/`，浅色和深色各一张：默认 100/100、猫 100 气泡 60、40/40、20/20 带 1 条结束提示、40/40 悬停态。和设计稿「透明度（D48）」逐张对照，result 写对照结论。预览用的 macOS 14～15 退路材质，不代表液态玻璃，液态玻璃交给用户实机验收。
- 执行者要求：强推理模型、高推理档位。
- 相关决策点：D1、D3、D4、D7、D8

### 3. 设置入口与文档同步

- 依据：D48；D5。
- 改法：
  - `DesktopCatSettings.swift`：在“大小”下面加两个滑块和“恢复默认”，写法同大小滑块（拖动只改显示、松手写入，失败时在分组下方显示原因、界面保持原值）。
  - `docs/design/SPEC.md`「桌面猫」新增一条“透明度（D48）”，外观栏桌面猫分组那一段补上两个滑块和“恢复默认”；“合成预览”清单补透明度场景。
- 验收：
  - 离线用例：百分比文字（0.2 →“20%”，0.33 →“35%”）；两项都是 1.0 时“恢复默认”不可用；拖动中不写配置、松手只写一次；保存失败时显示原因且滑块回到原值。
  - 前台用例（条目 4 实跑）：真实设置窗口容器里，桌面猫分组的“大小”下面出现两行滑块，宽度和对齐与大小滑块一致；截图放 `build/acceptance/desktop-cat-opacity/`，和设计稿设置示意对照。
- 相关决策点：D5

### 4. 安装、性能和实机验收

- 依据：整体验收。
- 改法：只做验证，不改应用代码。发现缺陷记入 result，由规划者决定修复。脚本和原值放 `build/acceptance/desktop-cat-opacity/`。
  1. `scripts/build-app.sh` 构建，再用 `scripts/install.sh` 安装；result 记录构建产物和已安装应用的哈希一致。
  2. 前台用例：`MEOWMAC_UI_TESTS=1 scripts/test.sh <桌面猫相关过滤词>`，result 写命令、退出码和通过数。
  3. 性能：
     1. 备份 `config.json`。
     2. A：`desktopCat.enabled = true`，两个透明度都是 1.0，用 `scripts/install.sh` 重启，测 480 秒。
     3. B：两个透明度都是 0.4，重启，测 480 秒。
     4. 再测一次 A、一次 B。四次期间不打开面板，不改显示器配置。
     4a. 显示状态取证（预审 P2）：每次测量开始和结束时，用只读方式记录 MeowMac 桌面猫窗口在屏（`CGWindowListCopyWindowInfo` 按进程号找窗口，记录边界）和光标位置（例如 `CGEvent(source: nil)?.location`），写进 `build/acceptance/desktop-cat-opacity/`。光标落在桌面猫窗口边界内，或找不到桌面猫窗口，这次数据作废。开始时光标在窗口内的，等 1 秒（回落完成）后重新取证，仍在窗口内就标“需用户移开鼠标”，交给规划者，不注入鼠标事件。result 写每次的取证结论。
     5. 逐字节恢复 `config.json`，重启。
- 验收：
  - 前台用例全部通过。
  - 两组 B 的均值比两组 A 的均值高出不超过 0.5 个百分点。result 只写四次读数的差值和均值差，不写原值。两次 A 之间或两次 B 之间相差超过 0.5 个百分点时，如实记录并标“读数不稳定”，不重测到合格为止，交给规划者判断。
  - `config.json` 恢复后逐字节一致。
  - `scripts/check.sh` 通过。
- 用户实机验收（执行者做完后，由规划者请用户做）：
  - 设置里拖两个滑块，看桌面猫实时变化；松手后重开应用，值保持；
  - 猫 100%、气泡 40%，以及两者 20%，分别放在浅色和深色壁纸上看；
  - 液态玻璃气泡在半透明时的边缘和模糊；
  - 鼠标移上去变实、移开 0.3 秒后回落的手感；拖动和拖把手缩放期间保持实色；
  - 20% 时仍能拖动、单击开面板、右键；透明处的点击仍穿过去；
  - 有结束提示时，提示跟随气泡的透明度；
  - “恢复默认”。

## 规划者保留

- D48 写入和 `plan-baseline` 移动：用户 2026-10-26 批准，规划者写入（`a75c9b3`）。
- 设计稿「透明度（D48）」：规划者起草，用户 2026-10-26 确认。
- 用户实机验收；`docs/ROADMAP.md` 记录。

## 项目专属自检

- [ ] `scripts/check.sh` 通过，`plan-baseline` 比对通过
- [ ] 没有修改 `../tuncanary`
- [ ] 没有新增计时器或轮询；悬停回落只用延迟任务
- [ ] 没有用窗口 `alphaValue` 实现透明度；命中逻辑没有读显示透明度
- [ ] `DesktopCatConfig` 的 `==` 包含两个新字段
- [ ] 夹具和预览只用虚构数据；`config.json` 原值和性能原值只在 `build/acceptance/`
- [ ] 没有提交 `docs/plans/2026-10-25-desktop-cat-sessions/result.md`
