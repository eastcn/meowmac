# 桌面猫：执行结果

对应的 plan：`docs/plans/2026-10-25-desktop-cat/plan.md`。最新一轮在最上面。

## 轮次

<!-- 执行者：在这一行下面插入新的一轮，格式见 relay Skill 的 references/result-template.md「第 N 轮」 -->

### 第 1 轮（2026-10-25，Claude Code 子 Agent · Claude Opus 5.5，高）

**提交范围**：`d4f857c..`（本轮提交：`3efd63a` `d9eeca7` `d61dafa` `13612ba` `98be03d`，外加本节所在的 `docs: record desktop cat round 1 result`，提交号由复审者补）

**开工检查**：无人值守；plan 复核：不需要（plan「复核：无」）。本宿主没有 Computer Use，前台用例（`MEOWMAC_UI_TESTS=1`）留到第 2 轮。

**会话与日志**：子 Agent 模式，无 relay 会话 id。长日志在 `docs/plans/2026-10-25-desktop-cat/.relay/`（已忽略）：`check-r1.log`、`desktopcat-r1.log`、`render-r1.log`。

**完成的条目**

提交顺序按依赖调整为 1 → 3 → 2 → 4：窗口要用视图，视图不依赖窗口。

| 编号 | 提交 | 验收证据 |
|---|---|---|
| 1 | `3efd63a` | `scripts/test.sh DesktopCat 原生菜单` 退出码 0，“自测完成：29 项，0 项失败，4 项前台验收未执行”。条目 1 的 9 项通过：`Core.DesktopCat/新建：默认值与只新增 desktopCat 字段`、`编辑：增减重排、角与屏、上下限`、`停用再启用保留指标和位置`、`坏配置回退且不改写文件`、`整个配置无效时拒绝保存`、`目录按渠道、电池与传感器生成`、`每类数值、单位与颜色角色`，以及 `UI.DesktopCat/即时写入与失败不改界面`、`外观恢复默认不改动桌面猫`。写入走 `ConfigStore.saveDesktopCat` → `updateField("desktopCat")`，只改这一个键，保留未知字段；整个文件无效时拒绝写。 |
| 3 | `d9eeca7` | 同一命令。通过：`Core.DesktopCat/气泡版式尺寸、对齐与尾巴`、`缩字最小 12 pt 与附注去除`、`UI.DesktopCat/猫图缓存同一帧不重复光栅化`（光栅化计数器断言）、`真实字体下的缩字与附注`。预览：`MEOWMAC_RENDER_DIR=$PWD/build/acceptance/desktop-cat/preview scripts/test.sh UI.DesktopCat` 退出码 0，生成 `build/acceptance/desktop-cat/preview/desktop-cat-{normal,alert,severe,missing,single,longSpeed,leftCorner}-{light,dark}.png` 共 14 张（合成数据），已逐张对照方案 A，偏差见「技术更正与异议」。 |
| 2 | `d61dafa` | 同一命令。通过：`Core.DesktopCat/最近角与落位边距`、`4 pt 单击阈值`、`指标数变化时角固定`、`找不到屏时落主屏且接回回原屏`、`点击判断猫像素气泡与尾巴`；`UI.DesktopCat/关闭时不建窗口不刷新`（关闭时快照更新不触发气泡渲染，计数器断言）、`窗口属性与右下角落位`（styleMask、层级、collectionBehavior、不能成为 key/main）、`帧号与菜单栏一致且不重复光栅化`、`拖动吸附存新屏与单击开面板`。前台用例 `UI.DesktopCatWindow/真实屏幕窗口属性与右下角` 已写，离线 SKIP，第 2 轮跑。 |
| 4 | `13612ba`、`98be03d` | 同一命令。通过：`UI.DesktopCat/右键菜单分组勾选与上下限`（满 4 项未选项不可用，剩 1 项已选项不可用，已选但不在目录的项标“（暂无数据）”且可取消）、`右键菜单原生项与回调`（NSMenu 标题、分组头、勾选、点击即写配置、打开面板和设置回调、让猫回去）、`设置分组即时写配置且不进草稿`（增、删、拖到目标行、⌥ 上下移、开关、放回右下角，每步读回文件；外观栏 `isDirty` 始终 false，外观草稿“取消”不撤回桌面猫修改）、`位置文字与暂放主屏`、`底部设置菜单显示桌面猫开关`（勾选跟随配置，点击写文件）；既有 `UI.Settings/原生菜单` 已按新增一项更新期望并通过。前台用例 `UI.DesktopCatWindow/桌面猫设置定位外观栏分组` 已写，离线 SKIP。设置菜单预览 `build/acceptance/desktop-cat/preview/settings-{light,dark}.png`（`UI.RenderOverview` 渲染）。SPEC 新增「桌面猫」一节，「底部操作栏」「统一设置窗口」「视觉验收」同步（`98be03d`）。 |

全量：`scripts/check.sh` 退出码 0，“自测完成：409 项，0 项失败，52 项前台验收未执行”“check 通过”。

**缺陷扫描**

扫描轮次：1。真实入口与环境：离线自测（真实 NSPanel、NSMenu、NSHostingView，不显示窗口）和 `MEOWMAC_RENDER_DIR` 合成预览（ImageRenderer，玻璃用 `previewMaterial` 纯色代替）；没有 Computer Use，未在屏幕上看真实窗口。

| 轮次 | 问题及证据 | 分类 | 修复与提交 | 复验结果 |
|---|---|---|---|---|
| 1 | 真实字体下缩字一次按比例算不准，长网速仍溢出（`UI.DesktopCat/真实字体下的缩字与附注` 失败） | 范围内的缺陷 | 改为每次缩 0.5 pt 逐步测量，归入 `d9eeca7` | 同一用例 PASS |
| 1 | 设置菜单预览高度曾改为 236，复看渲染图发现 210 已放得下六项，留白多余 | 顺手的小问题 | 还原为 210，并入 `13612ba` | `settings-{light,dark}.png` 无裁切 |

最终剩余：无。

**顺手修复**

无。

**自主决定**

| 条目 | 选择 | 备选 | 理由 |
|---|---|---|---|
| 2 | 直接采用 D11 的退路：全局与本地 mouseMoved 监视器按纯函数命中测试切换 `ignoresMouseEvents` | 先只依赖 AppKit 对透明像素的穿透 | NSHostingView 上透明区域默认仍吃点击，离线无法验证系统行为；命中测试可离线测 |
| 2 | 气泡刷新用 `DispatchQueue.main.async` 合并同一轮的多次快照更新 | 每次快照立即刷新 | 不是计时器，不提高频率；只把同一 run loop 内的多次更新合成一次 |
| 2 | 单击猫或气泡只打开面板，面板已开时不关闭 | 与菜单栏图标一样切换 | D45 原文是“单击打开面板” |
| 3 | 单色猫在正常、提醒、严重三态都加 1 pt 反色描边 | 只在正常态加 | 「口径」要求在任何壁纸上看得见，橙红色在深色壁纸上同样需要 |
| 4 | “放回右下角”写回默认位置（主屏右下角，不记屏幕 id） | 当前屏右下角 | 按钮文字与默认值一致，最易理解 |
| 4 | 底部菜单“显示桌面猫”放在“设置…”之后、第一条分隔线之前 | 放到配置文件项一组 | 与设置入口同组；分隔线位置保持 D38 原样 |
| 1 | 网络状态的附注取最差一项检查的名称，没有时为“站点”；今日花费的更新时间留空 | 另算原因文字和花费时间 | 只用已有数据，不新增采集 |

**技术更正与异议**

| 类型 | 对象 | 证据 | 处理 | 影响 |
|---|---|---|---|---|
| 异议 | 设计稿方案 A：速度线位置 | `desktop-cat-longSpeed-*.png`：速度线在猫身最左侧 | 未改。速度线来自与菜单栏共用的 CatRenderer 几何，改它会影响菜单栏猫 | 视觉与设计稿略有差别，待用户实机看 |
| 异议 | 网络状态严重态附注 | `desktop-cat-severe-*.png`：设计稿写“DNS”，实现的原因是检查名“代理 DNS”，放不下时按「口径」去掉附注 | 未改。附注去除规则优先于设计稿示例文字 | 严重态只显示“网络”和结论 |
| 异议 | 气泡尾巴 | 预览：尾巴为 12 × 6 pt 三角，伸出 6 pt；设计稿是旋转方块，视觉上略大 | 未改，差值在 2 pt 级别 | 无 |
| 异议 | 网速数值格式 | 预览：`↑128.0K`；设计稿 `↑128K` | 未改，沿用总览格式（SPEC 规定一位小数） | 长网速更早触发缩字 |
| 异议 | 拖动中的落点提示、悬停 0.6 s | 设计稿拖动时画四角落点框；悬停提示用原生 `.help`，延迟跟随系统 | 未做落点框；提示文字按「口径」 | 交互手感待第 2 轮和用户实机看 |

**plan 勘误**

无。

**建议**

- 第 2 轮实机看液态玻璃与 `.hudWindow` 退路的实际效果，以及透明处点击穿透；若命中测试切换有延迟感，再考虑别的做法。
- 拖动落点框可作为后续体验改进。

**外部写入**

- 无。只有本地提交，未推送；未改 `config.json`、CodexBar 配置和 `../tuncanary`。测试只写临时目录，预览只写 `build/acceptance/desktop-cat/preview/`。

**跳过的决策点**

- 无。

**未做**

- 5：按任务安排留到第 2 轮（安装、前台用例、性能、实机验收）。

**偏离 plan 的地方**

- 提交顺序为 1 → 3 → 2 → 4（plan 编号顺序是 1 → 2 → 3 → 4），理由见「完成的条目」。
- 条目 4 的 SPEC 同步单独成 `docs:` 提交 `98be03d`，代码在 `13612ba`。

**未验证**

- 前台用例 `UI.DesktopCatWindow/真实屏幕窗口属性与右下角`、`UI.DesktopCatWindow/桌面猫设置定位外观栏分组` 未运行：本宿主没有 Computer Use，按任务要求留到第 2 轮。
- 液态玻璃材质、透明处点击穿透、全屏 App 上显示、多屏拖动、深浅色切换都只有离线断言或合成预览，未在真实屏幕上看。
- 性能（开启比关闭的自身 CPU）属条目 5，未测。

**自检**

| 项 | 结果 | 说明或证据 |
|---|---|---|
| 只做了执行清单、范围内缺陷修复和满足条件的顺手修复 | 是 | 条目 1～4 |
| 范围内缺陷已修复并重新验收；卡住或跳过的项已记录，未标成已完成 | 是 | 见「缺陷扫描」；条目 5 标“后续轮次” |
| 顺手修复不碰核心，不加依赖，行数在本档上限内 | 不适用 | 无顺手修复 |
| 顺手修复每项都有单独的 `fix:` 提交、理由、复验证据和 result 记录 | 不适用 | 无顺手修复 |
| 没有改变核心；没有放宽安全 | 是 | 菜单栏猫、采集和刷新调度未改 |
| 自主决定、技术更正与异议、plan 勘误都已记录并附理由或证据 | 是 | 见上 |
| 已做交付前缺陷扫描，最多 2 轮；问题分类、修复、复验和剩余问题已写进 result | 是 | 1 轮 |
| 验收的预览、截图和测试走真实路径；模拟证据仅作补充，未验证项已记录 | 部分 | 无屏幕环境，真实窗口观感见「未验证」 |
| 没有降低验收标准或放宽测试断言 | 是 | `UI.Settings/原生菜单` 只按新增项更新期望，断言项数未减 |
| 每个执行条目至少一个提交 | 是 | `git log --oneline d4f857c..HEAD`：`98be03d docs: sync desktop cat spec`、`13612ba feat: add desktop cat context menu and settings group`、`d61dafa feat: show desktop cat in a click-through floating panel`、`d9eeca7 feat: add desktop cat figure and metric bubble views`、`3efd63a feat: add desktop cat config and metric catalog` |
| 做过的条目都满足执行者要求；不满足的已跳过 | 是 | Claude Opus 5.5，高推理 |
| 外部写入都在授权范围内 | 是 | 无外部写入 |
| 用户可见的改动没有混进 refactor 提交 | 是 | 全部为 `feat:` / `docs:` |
| 新增的后台任务、异常分支都有日志，没有静默吞掉异常 | 是 | 保存失败写日志并显示“保存失败，配置文件未改动”；启动时记录 desktopCat 配置诊断 |
| 临时文件、临时脚本都已清理，包括远端机器上的 | 是 | 测试用临时目录在 `defer` 中删除 |
| `scripts/check.sh` 通过，`plan-baseline` 比对通过 | 是 | 退出码 0，“check 通过” |
| 没有修改 `../tuncanary` | 是 | `git -C ../tuncanary status --short` 输出为空 |
| 没有新增计时器或采集频率 | 是 | `git diff plan-baseline -- Sources` 中 `Timer.scheduledTimer`、`DispatchSourceTimer`、`asyncAfter` 无新增行；唯一新增的 `DispatchQueue.main.async` 用于合并气泡刷新，见「自主决定」；帧计时复用菜单栏 |
| 桌面猫配置只写 `desktopCat` 一个字段；没有写进猫包 | 是 | 唯一写入点 `ConfigStore.saveDesktopCat` → `updateField("desktopCat")`；用例 `Core.DesktopCat/新建：默认值与只新增 desktopCat 字段` |
| 夹具和预览图只用虚构数据；`build/acceptance/` 以外没有真实读数 | 是 | 夹具用“示例内建显示器”等虚构名；预览为合成数据 |
| 第 2 轮结束后 `config.json` 与备份逐字节一致 | 不适用 | 第 2 轮项 |

**复审**

复审者：Claude Code 全新子 Agent（Opus 5.5），只读，2026-10-25。输入：plan、本节、`git diff d4f857c..82a83c6`。

结论：下一轮。没有 `阻断`；`一般` 3 条（R1～R3），`记录` 4 条（R4～R7）。根因：执行 5 条，规划 1 条，环境 1 条。复审者重跑 `scripts/check.sh`：退出码 0，409 项 0 失败，52 项前台未执行。

| 编号 | 问题 | 证据 | 根因 | 去向 | 用户决定 | 级别 |
|---|---|---|---|---|---|---|
| R1 | 两处设计稿要求被记为异议未实现：拖动时四角落点框（设计稿拖动态，D1 按方案 A）；悬停 0.6 秒提示（条目 3 改法）用了系统默认延迟。SPEC 也随实现删去了这两项。 | `mini-window.html:59`、`:209`；`DesktopCatView.swift:171`；diff `docs/design/SPEC.md` | 执行 | 待用户决策 | 用户 2026-10-25：补做落点框；悬停提示用系统默认延迟（plan D14）。本轮内修 | 一般 |
| R2 | 应用不在前台时悬停提示可能不显示：nonactivating panel 未设 `allowsToolTipsWhenApplicationIsInactive`。推断，未实测。 | `DesktopCatWindow.swift:65-80` | 执行 | 复审者修 | | 一般 |
| R3 | 左侧的角时猫与气泡没有左对齐：猫图在 120 pt 格子里靠右画，可见左缘偏 20 pt 以上；result 未记录。 | `DesktopCatImage.swift:35,53`；`DesktopCatLayout.swift:43-51`；`preview/desktop-cat-leftCorner-light.png` | 执行 | 复审者修 | | 一般 |
| R4 | 其余异议可接受，交用户实机看：速度线沿用共用 `CatRenderer`；`↑128.0K` 复用总览口径；尾巴差在 2 pt 内；严重态去附注符合 D7。plan D9 未写设计稿目录表与总览口径冲突时的优先级。 | `preview/desktop-cat-longSpeed-dark.png`；`DesktopCatConfigTests.swift:260` | 规划 | 待用户决策（并入第 2 轮实机验收；D9 补“冲突时以总览口径为准”） | 规划者已补 plan D15；格式偏差留第 2 轮用户实机验收 | 记录 |
| R5 | 代理流量 `1.20 GB`（设计稿 `1.2 G`）、DeepSeek 余额 `¥23.40`（设计稿 `¥23.4`）复用现有格式，result 漏记。 | `DesktopCat.swift:485`、`:453` | 执行 | 复审者修（补记到「技术更正与异议」） | | 记录 |
| R6 | `mouseDown` 未复核命中：从猫移到透明处、mouseMoved 未到时按下会误开面板。 | `DesktopCatWindow.swift:181-184`、`:226-232` | 执行 | 复审者修 | | 记录 |
| R7 | 点击穿透、全屏显示、程序坞变化后的重新落位只有离线证据；`didChangeScreenParametersNotification` 在程序坞自动隐藏或改尺寸时是否触发未知。 | `DesktopCatWindow.swift:83-86` | 环境 | 并入第 2 轮用户实机验收 | | 记录 |

重点核对：六条状态路径齐全，坏配置不改写文件（`DesktopCatConfigTests.swift:31-152`）；D10 无新增计时器，关闭时不建窗口、不渲染，有计数器断言；D11 采用退路方案（命中函数 + `ignoresMouseEvents`），坐标与 alpha 掩码正确；D13 找不到屏时只读不写标识；分层、受保护文件、TunCanary、虚构夹具、真实 `config.json` 未被写入均核对通过。
