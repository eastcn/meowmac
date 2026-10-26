# 桌面猫：透明度：执行结果

对应的 plan：`docs/plans/2026-10-26-desktop-cat-opacity/plan.md`。最新一轮在最上面。

## 轮次

<!-- 执行者：在这一行下面插入新的一轮，格式见 relay Skill 的 references/result-template.md「第 N 轮」 -->

### 第 1 轮（2026-10-26，Claude Code 子 Agent · Claude Opus 5.5，推理强度按派发默认）

**提交范围**：`04fd3d1..`（本轮提交：`71ced34`、`61ac6ea`、`4abc344`、`b915591`，以及本节所在的 `docs: record desktop cat opacity round 1`，提交号由复审者补）

**开工检查**：无人值守；plan 复核：不需要（`relay-plan v2`，定稿 2026-10-26）

**完成的条目**

| 编号 | 提交 | 验收证据 |
|---|---|---|
| 1 | `71ced34` | `scripts/test.sh DesktopCat` 退出码 0。新增 `Core.DesktopCatOpacity/*` 7 例全部 PASS：吸附与百分比（0.43→0.45、0.12→0.2、1.3→1.0，0.33→“35%”）；新建（缺省 1.0，第一次保存只新增 `catOpacity`，顶层和 `desktopCat` 其余字段含未知字段按解析后对象比较不变；`desktopCat` 缺失或不是对象时整组写入）；编辑（0.4 读回 0.4，每次只改一个键；整个文件损坏时拒绝且字节不变）；停用（整组保存 enabled false/true，两个透明度保持）；删除（删键读 1.0，无诊断）；恢复默认（一次调用写两个键为 1.0，其余字段不变）；坏配置（`"abc"`、`null`、`-0.5`、`0.1`、`1.5`、`[0.5]` 两个键各测一遍：按 1.0 读，文件字节不变，诊断仅一条且不含路径，`metrics`、`placement`、`catHeight` 照常；0.33 原样读取）。原有桌面猫配置用例未改断言，全部 PASS。`==` 已含两个新字段。 |
| 2 | `61ac6ea` | 新增 `UI.DesktopCatOpacity/悬停变实、0.3 秒回落与拖动缩放保持`（延迟任务注入为手动执行，不真实等待：不悬停 0.4/0.6；悬停猫、气泡、把手都是 1/1；离开后投递一个 0.3 秒任务，执行前仍 1/1、执行后回到 0.4/0.6；0.3 秒内回来任务被取消、执行也不回落；缩放和拖动期间 1/1，拖到左上松手后鼠标不在猫上，回落；“减少动态效果”开时 `solidAnimated == false`，关掉后为 true；`hide()` 清掉变实）、`命中与显示透明度无关`（猫内、气泡内、透明边距三点，在 0.2/0.2、0.2/1.0、1.0/0.2 下 `hitShape().contains` 与 1.0/1.0 相同）、`把手和落点框不随设定变化`（合成预览 40% 与 100% 两场景把手中心像素相同；拖动时猫窗口和落点框窗口 `alphaValue` 都是 1）、`不新增监视器和计时器`（100% 与 40% 下鼠标监视器都是 2 个；不动鼠标不投递任务，进出一次只投递一个一次性任务），全部 PASS。合成预览：`MEOWMAC_RENDER_DIR=build/acceptance/desktop-cat-opacity/preview scripts/test.sh DesktopCat.Preview`，退出码 0，“桌面猫合成预览：62 张”，透明度 10 张为 `build/acceptance/desktop-cat-opacity/preview/desktop-cat-opacity{Default,Bubble60,40,20Toast,40Hover}-{light,dark}.png`。逐张对照设计稿「透明度（D48）」：默认外观不变；猫 100% 气泡 60% 只淡化气泡；40%/40% 深色两者都淡；20%/20% 结束提示与气泡一起淡；悬停态两者 100%。差别：悬停态预览同时显示缩放把手（真实窗口鼠标停在猫上时会出把手，D47），设计稿只画了光标。预览用设计稿的半透明底色代替玻璃，不代表液态玻璃。 |
| 3 | `4abc344` | 新增 `UI.DesktopCatOpacity/设置滑块拖动只改显示、松手写一次与失败回滚` PASS：0.2→“20%”、0.33→“35%”；两项 1.0 时“恢复默认”不可用；连拖三次只改草稿和桌面猫显示（控制器模型 0.4），文件字节不变、回调 0 次；松手写一次，重复松手不写；合法非步长值滑块按 0.35 显示、桌面猫按 0.33 显示；恢复默认一次写两键；文件损坏时显示原因，滑块和桌面猫回到 1.0，文件不变。SPEC「桌面猫」新增“透明度（D48）”一条，外观栏分组一段补两个滑块和“恢复默认”，「视觉验收」补透明度预览清单。前台用例见条目 4。 |
| 4 | `b915591`（前台用例改为按 NSSlider 视图定位，见技术更正） | 1）`scripts/build-app.sh && scripts/install.sh` 退出码 0；`shasum -a 256` 构建产物与 `~/Applications/MeowMac.app/Contents/MacOS/MeowMac` 相同（`24faabbf…2fa28`）。2）`MEOWMAC_UI_TESTS=1 scripts/test.sh DesktopCat` 退出码 0，“自测完成：65 项，0 项失败，0 项前台验收未执行”，含 `UI.DesktopCatWindow/设置里两行不透明度滑块与大小对齐`：真实设置窗口中三条宽 140 pt 的滑块左缘都在 x 403，自上而下为大小、猫、气泡，“恢复默认大小”和“恢复默认”按钮列对齐、后者可用。截图 `build/acceptance/desktop-cat-opacity/settings-opacity-{light,dark}.png`，与设计稿设置示意一致（大小下依次两行，猫行 100% 无按钮，气泡行 60% 带“恢复默认”）。3）性能：见下方「性能」。4）`config.json` 恢复后 `cmp` 逐字节一致，权限 `-rw-------`。5）`scripts/check.sh` 退出码 0：“自测完成：476 项，0 项失败，53 项前台验收未执行”“check 通过”。 |

**性能**（`scripts/profile-self.sh live --seconds 480 --repeats 1`，四次都“主进程身份与读数校验通过”；每次 `scripts/install.sh` 重启，等 20 秒，`caffeinate -i -w <pid>`；顺序 A1、B1、A2、B2；A=两项 100%，B=两项 40%；`config.json` 只改 `desktopCat.enabled`、`catOpacity`、`bubbleOpacity`，脚本断言其余字段与备份一致。脚本和原值在 `build/acceptance/desktop-cat-opacity/`）

- 显示状态取证（4a）：8 次（每次开始和结束）都找到桌面猫窗口（层级 3），光标都不在窗口内，没有一次作废，也没有需要重新取证的。
- 两组 B 的均值比两组 A 低 0.65 个百分点，在“高出不超过 0.5”之内。
- 逐次差值：B1−A1 = −1.60，B2−A2 = +0.31；A2−A1 = −1.06，B2−B1 = +0.85。
- **读数不稳定**：两次 A 相差 1.06、两次 B 相差 0.85 个百分点，都超过 0.5。按 plan 不重测，交规划者判断。

**缺陷扫描**

扫描轮次：1。真实入口与环境：合成预览走真实内容视图 `DesktopCatContentView` 和猫图缓存（预览材质）；设置截图走真实 `SettingsWindowController` 窗口（`cacheDisplay`）；离线用例走真实控制器 `DesktopCatController`（`ordersFront = false`）。

| 轮次 | 问题及证据 | 分类 | 修复与提交 | 复验结果 |
|---|---|---|---|---|
| 1 | 前台用例按辅助功能 id 找不到 SwiftUI 滑块（“缺少滑块：[]”） | 范围内的缺陷（测试写法） | 改为在真实窗口视图树里找 NSSlider，并用 AppKit 按钮 id 做行对照，`b915591` | `MEOWMAC_UI_TESTS=1 scripts/test.sh 两行不透明度` PASS |
| 1 | 深色截图全白：`cacheDisplay` 不带窗口底色 | 范围内的缺陷（截图） | 按当前外观的窗口底色垫底再合成，`b915591` | `settings-opacity-dark.png` 正常 |

最终剩余：截图里侧栏为空白（侧栏材质 `cacheDisplay` 截不到），只影响截图，不影响界面；液态玻璃见「未验证」。

**顺手修复**

无。

**自主决定**

| 条目 | 选择 | 备选 | 理由 |
|---|---|---|---|
| 1 | 整组保存（`saveDesktopCat`）总是编码两个透明度键，和 `catHeight` 一致 | 值为 1.0 时不编码 | 与现有字段一致；读取结果相同；单字段保存仍只新增对应的键 |
| 1 | 一个 `saveDesktopCatOpacity([部分: 值])` 同时承担单键保存和“恢复默认”的两键一次写盘 | 两个函数 | 少一份重复的回退逻辑 |
| 2 | 回落的延迟投递做成可注入的 `scheduleAfter`，默认 `DispatchQueue.main.asyncAfter` | 测试用真实等待 | plan 验收建议注入；用户无感知 |
| 2 | 拖动松手后调用 `updateMouseThrough()` 按鼠标位置决定回落和穿透 | 等下一次 mouseMoved | D3/D8 要求松手后按鼠标位置决定 |
| 3 | 设置拖动草稿放在 `PanelState.desktopCatOpacityDraft`，控制器在已有刷新里读取 | 视图内 `@State` 草稿 | D5 要求拖动时桌面猫实时跟着变；不新增订阅或计时 |
| 3 | 猫那一行右侧留出与按钮同宽（112 pt）的空位；气泡行按钮宽 112 pt | 按钮按文字宽 | 验收要求滑块宽度和对齐与大小一行一致 |
| 3 | 透明度行不加说明小字；分组下方提示补一句“透明度滑块拖动时只改显示，松手写配置；‘恢复默认’把两项都设回 100%。” | 每行加说明 | 与设计稿设置示意一致 |

**技术更正与异议**

| 类型 | 对象 | 证据 | 处理 | 影响 |
|---|---|---|---|---|
| 更正 | D7 过渡写法 | — | 变实和回落在控制器里用 `withAnimation(.easeInOut(duration: 0.15))` 包住状态切换，“减少动态效果”时传 `nil`；只对 `solid` 切换做过渡，滑块拖动不带过渡 | 无 |
| 异议（未改） | D7 玻璃上直接 `.opacity` | 宿主截不到液态玻璃 | 按默认直接 `.opacity`，未加 `compositingGroup()`（它可能让玻璃取不到背后内容）。若实机看到边缘发白或模糊层不变淡，再按 D7 的备选改 | 交用户实机验收 |

**plan 勘误**

无。

**建议**

- 右键菜单打开期间保持变实只有代码路径，没有离线用例（`NSMenu.popUpContextMenu` 会阻塞测试）。如需覆盖，可把弹出菜单做成可注入。

**外部写入**

- `scripts/install.sh` 5 次（安装 1 次、测量重启 4 次）加恢复后重启 1 次，均为 `osascript` 正常退出。
- `config.json` 临时修改 4 次，只改 `desktopCat.enabled`、`catOpacity`、`bubbleOpacity`；测量前备份到 `build/acceptance/desktop-cat-opacity/config.json.bak`，结束后逐字节恢复，`cmp` 通过。
- 前台用例在真实屏幕上短暂显示桌面猫和设置窗口。
- 未推送；未改 TunCanary；未改受保护文件（`git diff --quiet plan-baseline -- AGENTS.md CLAUDE.md docs/DECISIONS.md` 通过）。

**跳过的决策点**

无。

**未做**

无。

**偏离 plan 的地方**

- 合成预览悬停态带缩放把手（设计稿只画光标），理由见条目 2。

**未验证**

- 液态玻璃（macOS 26 `glassEffect`）在半透明时的边缘和模糊：宿主没有 Computer Use，交用户实机验收。
- 右键菜单打开期间保持变实、菜单关闭后回落：无离线用例，交用户实机验收。
- 真实鼠标下的悬停手感、20% 时拖动/单击/右键、浅深壁纸观感：交用户实机验收。
- 性能读数不稳定（见「性能」）：均值差满足门槛，但同组重复读数相差超过 0.5 个百分点。

**自检**

| 项 | 结果 | 说明或证据 |
|---|---|---|
| 只做了执行清单、范围内缺陷修复和满足条件的顺手修复 | 是 | |
| 范围内缺陷已修复并重新验收；卡住或跳过的项已记录，未标成已完成 | 是 | |
| 顺手修复不碰核心，不加依赖，行数在本档上限内 | 不适用 | 无顺手修复 |
| 顺手修复每项都有单独的 `fix:` 提交、理由、复验证据和 result 记录 | 不适用 | |
| 没有改变核心；没有放宽安全 | 是 | |
| 自主决定、技术更正与异议、plan 勘误都已记录并附理由或证据 | 是 | |
| 已做交付前缺陷扫描，最多 2 轮；问题分类、修复、复验和剩余问题已写进 result | 是 | 1 轮 |
| 验收的预览、截图和测试走真实路径；模拟证据仅作补充，未验证项已记录 | 是 | 玻璃见未验证 |
| 没有降低验收标准或放宽测试断言 | 是 | 原有用例断言未改 |
| 每个执行条目至少一个提交 | 是 | `git log --oneline 04fd3d1..HEAD`：`b915591` test、`4abc344` 条目 3、`61ac6ea` 条目 2、`71ced34` 条目 1，加本节 docs 提交 |
| 做过的条目都满足执行者要求；不满足的已跳过 | 是 | 条目 2 由 Opus 5.5 执行 |
| 外部写入都在授权范围内 | 是 | |
| 用户可见的改动没有混进 refactor 提交 | 是 | |
| 新增的后台任务、异常分支都有日志，没有静默吞掉异常 | 是 | 透明度保存失败记 `desktop-cat` 日志并在设置显示原因 |
| 临时文件、临时脚本都已清理，包括远端机器上的 | 是 | 测量脚本和原值只在 `build/acceptance/desktop-cat-opacity/`（git 忽略）；测试临时文件由 `defer` 删除 |
| `scripts/check.sh` 通过，`plan-baseline` 比对通过 | 是 | 476 项 0 失败，check 通过 |
| 没有修改 `../tuncanary` | 是 | `git -C ../tuncanary status --short` 为空 |
| 没有新增计时器或轮询；悬停回落只用延迟任务 | 是 | `不新增监视器和计时器` 用例 |
| 没有用窗口 `alphaValue` 实现透明度；命中逻辑没有读显示透明度 | 是 | `把手和落点框不随设定变化`、`命中与显示透明度无关` |
| `DesktopCatConfig` 的 `==` 包含两个新字段 | 是 | `Sources/MeowMacCore/DesktopCat.swift` |
| 夹具和预览只用虚构数据；`config.json` 原值和性能原值只在 `build/acceptance/` | 是 | |
| 没有提交 `docs/plans/2026-10-25-desktop-cat-sessions/result.md` | 是 | 仍为工作区未提交改动 |

**复审**

