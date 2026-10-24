import Foundation
import MeowMacCore
import MeowMacSystem
import MeowMacUI
import MeowMacQuota
import Darwin
import AppKit

@main
enum SelfTestMain {
    @MainActor static func main() {
        if let status = AIAgentTerminalLauncher.handleCommandLine(Array(CommandLine.arguments.dropFirst())) { exit(status) }
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--profile" {
            let arguments = Array(CommandLine.arguments.dropFirst(2))
            NSApplication.shared.setActivationPolicy(arguments.first == "live" ? .prohibited : .accessory)
            Task { @MainActor in exit(await SelfPerformanceRunner.run(arguments)) }
            NSApplication.shared.run()
            return
        }
        // 原生控件会泵送 RunLoop；由 AppKit 托管主循环，避免 async-main 提前结束。
        NSApplication.shared.setActivationPolicy(TestPresentationPolicy.allowsForeground(environment: ProcessInfo.processInfo.environment) ? .accessory : .prohibited)
        Task { @MainActor in await runTests() }
        NSApplication.shared.run()
    }
    @MainActor static func runTests() async {
        var tests: [(String, @MainActor () async -> Bool)] = [
            ("Core.TestRunner/前台验收必须显式开启", { TestPresentationPolicy.regression() }),
            ("UI.Performance/生产定时器生命周期", { await ApplicationCadenceTests.lifecycle() }),
            ("UI.Performance/系统更新与失败语义", { ApplicationCadenceTests.systemUpdate() }),
            ("Core.Performance/固定比较门槛与负控", { SelfPerformanceMetricsTests.comparator() }),
            ("Core.Performance/差分与缺测拒绝", { SelfPerformanceMetricsTests.readings() }),
            ("Core.Smoke/版本号", { AppIdentity.version == "0.1.0" }),
            ("Core.Config/文件不存在", { SelfTestMain.missingConfig() }),
            ("Core.Config/部分字段", { SelfTestMain.partialConfig() }),
            ("Core.Config/JSON 无效", { SelfTestMain.invalidConfig() }),
            ("Core.Config/完整文件", { SelfTestMain.completeConfig() }),
            ("System.Metrics/CPU 差分", { CPUTicks.usage(previous: CPUTicks(user: 10, system: 10, idle: 10, nice: 0), current: CPUTicks(user: 20, system: 20, idle: 40, nice: 0)) == 0.4 }),
            ("System.Metrics/网络速率", {
                let old = ByteCounters(received: 100, sent: 200)
                let new = ByteCounters(received: 300, sent: 250)
                let rates = ByteCounters.rates(previous: old, current: new, seconds: 2)
                return rates?.received == 100 && rates?.sent == 25
            }),
            ("System.Metrics/内存压力", {
                let config = LocalConfig()
                return MemoryPressure.normal.load(config: config) == 0 && MemoryPressure.warn.load(config: config) == 0.6 && MemoryPressure.critical.load(config: config) == 0.9
            }),
            ("System.Metrics/电池换算", {
                BatteryMetrics.parse(temperature: 3051, systemLoad: 7082) == BatteryMetrics(temperatureCelsius: 30.51, systemPowerWatts: 7.082)
            }),
            ("System.Live/系统采样", { SelfTestMain.liveSystem() }),
            ("Core.Energy/top 第二次采样", { SelfTestMain.topParser() }),
            ("Core.Energy/持续高占用到 10 分钟告警", { EnergyTrackerTests.sustainedAlerts() }),
            ("Core.Energy/每分钟短峰不告警", { EnergyTrackerTests.periodicSpikeIgnored() }),
            ("Core.Energy/回落、消失后重新计时", { EnergyTrackerTests.dropResetsStreak() }),
            ("Core.Energy/采样断档后重新计时", { EnergyTrackerTests.gapResetsStreak() }),
            ("Core.Energy/短窗口样本不改变持续时长", { EnergyTrackerTests.shortSampleKeepsStreak() }),
            ("Core.Energy/内存压力断档后重新计时", { EnergyTrackerTests.pressureGapResets() }),
            ("Core.Energy/短样本沿用失控进程结论", { EnergyTrackerTests.shortSampleKeepsRunaway() }),
            ("Core.Energy/断档阈值边界", { EnergyTrackerTests.gapBoundary() }),
            ("System.Energy/采样间隔校验与 top 参数", { EnergyTrackerTests.sampleSecondsValidation() }),
            ("Quota.Activity/120 秒窗口与渠道独立", { AgentActivityTests.window() }),
            ("Quota.Proxy/无代理证据时不发起查询", { await QuotaProxyProtectionTests.missingEvidence() }),
            ("Quota.Proxy/TUN 判定及仅本机采集", { QuotaProxyProtectionTests.statuses() }),
            ("Quota.Proxy/失效未知过期均阻断旧绿灯", { await QuotaProxyProtectionTests.blockedStates() }),
            ("Quota.Proxy/其他渠道继续并保留缓存", { await QuotaProxyProtectionTests.otherProvidersAndCache() }),
            ("Quota.Proxy/恢复合并及五分钟限频", { await QuotaProxyProtectionTests.recoveryAndCooldown() }),
            ("Quota.Proxy/启动手动和停用渠道测试", { await QuotaProxyProtectionTests.startupAndTest() }),
            ("Quota.Proxy/检查中代理失效", { await QuotaProxyProtectionTests.changedDuringCheck(0) }),
            ("Quota.Proxy/检查中移除渠道", { await QuotaProxyProtectionTests.changedDuringCheck(1) }),
            ("Quota.Proxy/检查中停用渠道", { await QuotaProxyProtectionTests.changedDuringCheck(2) }),
            ("Quota.Proxy/检查中停止调度", { await QuotaProxyProtectionTests.changedDuringCheck(3) }),
            ("Quota.Proxy/休眠唤醒及网络切换恢复", { await QuotaProxyProtectionTests.sleepAndNetworkSwitch() }),
            ("Quota.Proxy/暂停及最后成功时间展示", { QuotaProxyProtectionTests.display() }),
            ("Quota.Proxy/快照入口及浅深合成预览", { await QuotaProxyProtectionTests.snapshotAndPreviews() }),
            ("Quota.Process/连续退出后可继续采集", { await CodexBarProcessTests.repeatedExit() }),
            ("Quota.Process/启动失败后释放采集锁", { await CodexBarProcessTests.failedLaunch() }),
            ("Quota.Process/大输出与非零退出后恢复", { await CodexBarProcessTests.largeOutputAndFailure() }),
            ("Quota.Process/超时保护与自然退出后恢复", { await CodexBarProcessTests.timeoutRecovery() }),
            ("Quota.Process/配置 stdin 与输出保密", { await CodexBarProcessTests.configInputPrivacy() }),
            ("Quota.Process.Live/本机启用渠道采集", { await CodexBarProcessTests.liveUsage() }),
            ("Quota.Activity/Claude 子 Agent 记录", { AgentActivityTests.claudeSubagents() }),
            ("Quota.Activity/Codex 最近三个日期目录", { AgentActivityTests.codexRecentDates() }),
            ("Quota.Activity/未安装与结构异常", { AgentActivityTests.availability() }),
            ("Quota.Activity/符号链接", { AgentActivityTests.symbolicLinks() }),
            ("Quota.Activity/CLI 兜底间隔", { AgentActivityTests.pollerFallback() }),
            ("Quota.Activity/调度保留未更新的渠道", { AgentActivityTests.scheduleKeepsUnupdatedProvider() }),
            ("Core.Energy/忽略三小时休眠断言", { MemoryTests.ignoredAssertions() }),
            ("System.Metrics/活动监视器内存口径", { MemoryTests.usage() }),
            ("UI.System/内存压力百分比", { MemoryTests.pressure() }),
            ("System.Live.Energy/进程", { SelfTestMain.liveEnergy() }),
            ("System.Live.Energy.Rusage/跨用户读取", { SelfTestMain.liveRusage() }),
            ("Quota.Live/四渠道刷新", { SelfTestMain.liveQuota() }),
            ("Quota.Live.Activity/本机扫描与 sessions 对照", { SelfTestMain.liveActivity() }),
            ("Quota.Live.Cost/Codex 花费", { SelfTestMain.liveCodexCost() }),
            ("Quota.Live.Cost/Claude 花费", { SelfTestMain.liveClaudeCost() }),
            ("Core.Health/信号与排序", { SelfTestMain.healthSignals() }),
            ("Core.Health/降温与诊断文案", { SelfTestMain.healthMessages() }),
            ("Core.Health/系统与能耗信号", { SelfTestMain.healthSystemSignals() }),
            ("Core.Panel/默认标签页", { SelfTestMain.openingTab() }),
            ("Core.PanelLayout/完整排列与严格校验", { PanelLayoutCoreTests.validation() }),
            ("Core.PanelLayout/v1 v2 包兼容", { PanelLayoutCoreTests.packageCompatibility() }),
            ("Core.Style/默认与色板", { StyleTests.core() }),
            ("Core.Style/总览 v2 与选择器", { StyleTests.layout() }),
            ("UI.StyleStore/文件边界与恢复", { StyleStoreTests.boundaries() }),
            ("UI.Style/总览与额度显示", { StyleUITests.rendering() }),
            ("UI.PanelLayoutStore/四猫独立保存与重载", { PanelLayoutStoreTests.lifecycle() }),
            ("UI.PanelLayoutStore/坏文件与链接恢复", { PanelLayoutStoreTests.recovery() }),
            ("UI.PanelLayoutStore/发布前后与迟到保存", { PanelLayoutStoreTests.transactions() }),
            ("Core.Cat/速度映射", { SelfTestMain.catMotion() }),
            ("Core.CatPackage/严格清单", { CatPackageTests.core() }),
            ("UI.CatPackage/内置资源与文件边界", { CatPackageTests.ui() }),
            ("Core.CatPackage/独立清单负例", { CatBoundaryTests.manifestCases() }),
            ("UI.CatPackage/独立 PNG 限额与透明度", { CatBoundaryTests.boundaries() }),
            ("UI.Cat/四版状态与静止", { CatRenderTests.states() }),
            ("UI.Cat/非对称源坐标方向", { CatRenderTests.orientation() }),
            ("UI.Cat/真实负载速度线阈值", { CatRenderTests.threshold() }),
            ("UI.Cat/极端几何不溢出", { CatRenderTests.extremeGeometry() }),
            ("UI.Cat/睡姿与速度线定位", { CatRenderTests.positions() }),
            ("UI.Cat/深浅色汇总预览", { CatRenderTests.previewSheets() }),
            ("UI.CatStore/导入选择与持久化", { CatStoreTests.lifecycle() }),
            ("UI.CatStore/坏选择和坏包恢复", { CatStoreTests.recovery() }),
            ("UI.CatStore/目标符号链接", { CatStoreTests.links() }),
            ("UI.CatStore/发布与写入失败", { CatStoreTests.transactions() }),
            ("UI.RenderCat/三档帧图", { SelfTestMain.renderCat() }),
            ("UI.Cat/帧图透明区域", { SelfTestMain.catPixels() }),
            ("Network.Settings/首次安装默认值与独立保存", { NetworkSettingsTests.freshInstall() }),
            ("UI.NetworkSettings/内存存储与保存回调", { NetworkSettingsTests.roundTrip() }),
            ("UI.NetworkSettings/URL 与三个间隔边界", { NetworkSettingsTests.boundaries() }),
            ("UI.NetworkSettings/新轮次与出口独立调度", { NetworkSettingsTests.status() }),
            ("UI.NetworkSettings/真实控件与合成预览", { NetworkSettingsTests.controlsAndPreviews() }),
            ("UI.QuotaSettings/命令顺序与 stdin 凭据", { await QuotaSourceSettingsTests.commands() }),
            ("UI.QuotaSettings/部分失败保留草稿", { await QuotaSourceSettingsTests.partialFailure() }),
            ("UI.QuotaSettings/停用后重启先读取启停", { await QuotaSourceSettingsTests.disabledRestart() }),
            ("UI.QuotaSettings/启停读取失败不采集", { await QuotaSourceSettingsTests.startupStatusFailure() }),
            ("UI.QuotaSettings/定时后测试限频", { await QuotaSourceSettingsTests.throttles(0) }),
            ("UI.QuotaSettings/保存后测试限频", { await QuotaSourceSettingsTests.throttles(1) }),
            ("UI.QuotaSettings/测试后保存限频", { await QuotaSourceSettingsTests.throttles(2) }),
            ("UI.QuotaSettings/凭据与采集组合", { await QuotaSourceSettingsTests.credentials() }),
            ("UI.Quota/余额渠道普通材质预览", { QuotaSourceTests.balancePreview() }),
            ("UI.QuotaSettings/余额提醒阈值", { await QuotaSourceSettingsTests.balanceWarn() }),
            ("UI.QuotaSettings/移除保存后可再添加与搜索", { await QuotaSourceSettingsTests.addAfterRemoveAndSearch() }),
            ("UI.QuotaSettings/真实控件与合成预览", { await QuotaSourceSettingsTests.controlsAndPreviews() }),
            ("QuotaSettings.Live/临时 CLI 添加停用移除", { await QuotaSourceSettingsTests.liveConfig() }),
            ("Core.QuotaSources/目录、凭据、坏清单与 CLI 错误", { QuotaSourceTests.core() }),
            ("UI.QuotaSources/通用卡片、通知、历史和颜色", { QuotaSourceTests.display() }),
            ("UI.QuotaSources/空清单", { QuotaSourceTests.empty() }),
            ("UI.QuotaSources/移除选中渠道", { QuotaSourceTests.selectionRemoval() }),
            ("UI.QuotaSources/移除总览引用", { QuotaSourceTests.overviewRemoval() }),
            ("UI.QuotaSources/异 ID 总览回退与重启", { QuotaSourceTests.overviewRestart() }),
            ("UI.QuotaSources/移除在途结果", { await QuotaSourceTests.inFlightRemoval() }),
            ("UI.QuotaSources/真实面板预览", { await QuotaSourceTests.previews() }),
            ("Core.Quota/渠道标识旧格式往返", { QuotaProviderTests.legacyRoundTrip() }),
            ("Core.Quota/四渠道解析", { SelfTestMain.quotaParsing() }),
            ("Core.Quota/dashboard 解析", { SelfTestMain.dashboardParsing() }),
            ("Core.Quota/花费与会话", { SelfTestMain.costAndSessions() }),
            ("Core.Quota/调度", { SelfTestMain.quotaSchedule() }),
            ("Core.Quota/历史保留", { SelfTestMain.quotaHistory() }),
            ("System.Cleaning/路径优先与自定义失败", { CleaningTests.paths() }),
            ("System.Cleaning/可执行检查与缺失历史", { CleaningTests.filesAndHistory() }),
            ("Core.System/mo 清理历史", { SelfTestMain.moHistory() }),
        ]
        tests.append(("UI.Settings.AlertRules/关闭通知的新规则不会抢先通知", { (try? AlertSettingsTests.notificationOrder()) ?? false }))
        tests.append(("UI.Settings.AlertRules/全部开关、字段和表单写盘", { (try? AlertSettingsTests.controls()) ?? false }))
        tests.append(("UI.Settings.AlertRules/越界覆盖下保存保留生效值与未知字段", { (try? AlertSettingsTests.invalidOverrides(restoring: false)) ?? false }))
        tests.append(("UI.Settings.AlertRules/越界覆盖下恢复默认去除坏字段", { (try? AlertSettingsTests.invalidOverrides(restoring: true)) ?? false }))
        tests.append(("UI.Settings.AlertRules/校验失败不写通知或配置", { (try? AlertSettingsTests.failedValidationKeepsNotifications()) ?? false }))
        tests.append(("UI.Settings.AlertRules/真实数字框、启用和新建入口", { (try? AlertSettingsTests.nativeFields()) ?? false }))
        tests.append(("UI.Settings.AlertRules/上限和坏文件保留", { (try? AlertSettingsTests.limitsAndBroken()) ?? false }))
        tests.append(("UI.Settings.AlertRules/合成真实窗口预览", { await AlertSettingsTests.previews() }))
        for test in CustomRuleTests.tests { tests.append((test.0, { (try? test.1()) ?? false })) }
        for test in QuotaAlertChannelTests.tests { tests.append((test.0, { (try? test.1()) ?? false })) }
        tests += NetworkPowerBacklogTests.tests
        for test in BatteryStatusTests.tests { tests.append((test.0, { test.1() })) }
        for test in BatteryHistoryTests.tests { tests.append((test.0, { test.1() })) }
        tests.append(contentsOf: BatteryCardTests.tests)
        tests += CodexResetRecoveryTests.tests
        tests.append(("UI.AppIcon/年糕图标尺寸透明边界与对比度", { AppIconTests.sizes() }))
        for test in RuleClockTests.tests { tests.append((test.0, { (try? test.1()) ?? false })) }
        for test in AlertRuleTests.tests { tests.append((test.0, { (try? test.1()) ?? false })) }
        for test in DataTests.tests { tests.append((test.0, { test.1() })) }
        for test in SensorTests.tests { tests.append((test.0, { test.1() })) }
        for test in SensorUITests.tests { tests.append((test.0, { test.1() })) }
        for test in SensorRuleTests.tests { tests.append((test.0, { test.1() })) }
        for test in ReminderTests.tests { tests.append((test.0, { (try? test.1()) ?? false })) }
        tests.append(("UI.ReminderStore/重载坏文件与安全写入", { (try? ReminderTests.storage()) ?? false }))
        tests.append(("UI.Reminders/动作重载到期与详情定位", { ReminderUITests.lifecycle() }))
        tests.append(("UI.Reminders/恢复渠道身份与系统负例", { ReminderUITests.providerRecovery() }))
        tests.append(("UI.Reminders/原生入口暂缓恢复与容器", { await ReminderUITests.nativeControls() }))
        tests.append(("UI.Reminders/启动到期切猫与快照", { ReminderIntegrationTests.runtime() }))
        tests.append(("UI.Reminders/真实弹出面板与超高筛选", { await ReminderIntegrationTests.popover() }))
        tests.append(("System.AIAgent/固定目录与可执行检测", { AIAgentLaunchTests.detection() }))
        tests.append(("UI.AIAgent/CLI 启动失败与复制入口", { await AIAgentStartupTests.failures() }))
        tests.append(("UI.AIAgent/CLI 执行确认与关闭预览", { await AIAgentStartupTests.success() }))
        tests.append(("UI.AIAgent/终端成功但未回传超时", { await AIAgentStartupTests.timeout() }))
        tests.append(("UI.AIAgent/关闭预览后启动成功仍记住", { AIAgentLaunchTests.completionAfterClose() }))
        tests.append(("UI.AIAgent/八种启动与失败反馈", { AIAgentLaunchTests.controller() }))
        tests.append(("Core.AIAgent/实际 shell 参数与工作目录", { AIAgentLaunchTests.shell() }))
        tests.append(("UI.AIAgent.Live/Ghostty 假 agent", { await AIAgentLaunchTests.liveGhostty() }))
        tests.append(("Core.AIAgent/提示词字段与缺失值", { AIAgentCoreTests.prompt() }))
        tests.append(("Core.AIAgent/目录选择与编码", { AIAgentCoreTests.catalog() }))
        tests.append(("Core.AIAgent/配置保留与旧格式", { AIAgentCoreTests.config() }))
        tests.append(("Core.Cleaning/终端顺序与配置保留", { CleanTerminalTests.preferences() }))
        tests.append(("Core.Cleaning/实际 shell 转义与退出状态", { CleanTerminalTests.script() }))
        tests.append(("UI.Cleaning/缺失失败与重复启动", { CleanTerminalTests.controller() }))
        tests.append(("UI.Cleaning/原生菜单和提示按钮", { CleanTerminalTests.menu() }))
        tests.append(("UI.Cleaning.Live/实际 Ghostty 启动假工具", { await CleanTerminalTests.liveGhostty() }))
        tests.append(("UI.Cleaning/原生缺失状态容器", { await CleanTerminalTests.nativeLayout() }))
        tests.append(contentsOf: SystemTrendTests.tests)
        tests.append(contentsOf: DiskTrendTests.tests)
        tests.append(("UI.SystemTrend/真实弹出面板鼠标与首屏", { await SystemTrendNativeTests.popover() }))
        tests.append(("UI.SystemTrend/全状态及三页浅深色预览", { SystemTrendNativeTests.previews() }))
        tests.append(contentsOf: NotificationTests.tests)
        tests.append(contentsOf: BalanceAlertTests.tests)
        tests.append(contentsOf: NotificationUITests.tests)
        tests.append(contentsOf: NotificationTransactionTests.tests)
        tests.append(contentsOf: MenuBarCatImageTests.tests)
        tests.append(contentsOf: CodexResetTests.tests)
        tests.append(contentsOf: CodexResetUITests.tests)
        for test in HistoryTests.tests { tests.append((test.0, { test.1() })) }
        for test in NetworkHistoryTests.tests { tests.append((test.0, { test.1() })) }
        for test in NetworkLayoutTests.tests { tests.append((test.0, { test.1() })) }
        tests.append(contentsOf: NetworkUITests.tests)
        for test in CodexBarImportTests.tests { tests.append((test.0, { test.1() })) }
        tests.append(("UI.System/两类诊断与持续时间", { DiagnosisTests.rows() }))
        tests.append(("UI.Snapshot/八部分与关键字段编码", { @MainActor in
            let state = PanelPreviewRenderer.syntheticState(quotaAlert: true)
            do {
                let data = try JSONEncoder().encode(PanelSnapshot(state: state))
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object.count == 8,
                    let quota = object["quota"] as? [[String: Any]], let codex = quota.first(where: { $0["provider"] as? String == "codex" }),
                    let windows = codex["windows"] as? [[String: Any]] else { return false }
                return Set(object.keys) == Set(["overview", "tabs", "system", "quota", "network", "cat", "layout", "reminders"]) && windows.count == 2
                    && windows[1]["remainingPercent"] as? Double == 30 && windows[1]["pace"] != nil && codex["resetCredits"] != nil && codex["storage"] != nil && codex["cost"] != nil
            } catch { print("快照编码失败：\(error)"); return false }
        }))
        tests.append(("UI.Cat/减少动态与速度线", { @MainActor in
            let state = PanelPreviewRenderer.syntheticState(alert: true)
            let cat = state.catDisplay(reducedMotion: true)
            return cat.frame(3) == 0 && cat.speedLines && abs(cat.frameInterval - CatMotion.frameInterval(load: cat.load, config: state.configResult.config)) < 0.000001
                && CatRenderer.image(frame: 2, level: .normal).isTemplate
                && !CatRenderer.image(frame: 2, level: .warn).isTemplate
                && CatRenderer.png(frame: 0, level: .normal, reducedMotion: true) == CatRenderer.png(frame: 3, level: .normal, reducedMotion: true)
        }))
        tests.append(("UI.Network/分组与失败状态", { @MainActor in
            let model = PanelPreviewRenderer.networkModel(failure: true, now: Date())
            let value = model.meowMacDisplay
            guard value.tone == .red && value.checks.count == 5 && value.passed == 4,
                  value.groups.map(\.name) == ["国内", "海外", "子网目标"],
                  value.groups.map(\.passed) == [3, 2, 2], value.groups.map(\.total) == [3, 3, 2],
                  value.groups.map(\.medianMilliseconds) == [25, 184, 35], value.egress.count == 3 else { return false }
            let normal = PanelPreviewRenderer.networkModel(failure: false, now: Date()).meowMacDisplay
            guard normal.groups.map(\.passed) == [3, 3, 2], normal.groups.map(\.medianMilliseconds) == [25, 184, 35] else { return false }
            model.settings.egressTargets = [.claude]
            return model.meowMacDisplay.egress.count == 1 && model.meowMacDisplay.egress[0].target == model.settings.effectiveEgressTargets[0].displayName
        }))
        tests.append(("UI.Network.Live/CLI同轮对照", { @MainActor in
            do {
                let value = try await NetworkBridge.collectOnce()
                let dir = URL(fileURLWithPath: "build/acceptance")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(value.raw.utf8).write(to: dir.appendingPathComponent("network-meowmac.json"))
                try JSONEncoder().encode(value.model.meowMacDisplay).write(to: dir.appendingPathComponent("network-display.json"))
                let p = Process(); p.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/tuncanary")
                p.arguments = ["--check", "--json"]; let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe(); try p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                try data.write(to: dir.appendingPathComponent("network-cli.json"))
                let own = try JSONSerialization.jsonObject(with: Data(value.raw.utf8)) as? [String: Any]
                let other = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let ownChecks = (own?["items"] as? [[String: Any]])?.compactMap { $0["severity"] as? String }
                let otherChecks = (other?["items"] as? [[String: Any]])?.compactMap { $0["severity"] as? String }
                return own?["status"] as? String == other?["status"] as? String && ownChecks == otherChecks
            } catch { print("网络对照失败：\(error)"); return false }
        }))
        tests.append(("Network.History.Live/真实一轮写入与读回", { @MainActor in
            do {
                let dir = URL(fileURLWithPath: "build/acceptance/network")
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("history"))
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let value = try await NetworkBridge.collectOnce(historyFile: dir.appendingPathComponent("egress-history.json"))
                let rows = NetworkRoundBuilder.rows(from: value.model.siteHistory)
                let store = NetworkHistoryStore(directory: dir.appendingPathComponent("history"))
                try store.append(sites: rows)
                let loaded = store.load(now: Date())
                print("分组：" + loaded.sites.map { "\($0.group.title) \($0.passed)/\($0.total) \($0.medianMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—")" }.joined(separator: "，"))
                return rows.count == 3 && loaded.sites == rows && rows.contains { $0.total > 0 }
            } catch { print("网络历史实测失败：\(error)"); return false }
        }))
        tests.append(("UI.Network/等待总超时与完成", { @MainActor in
            do {
                var elapsed = 0.0
                let timedOut = try await SnapshotWait.waitWhile(uptime: { elapsed }, sleep: { elapsed += $0 }, pending: { true })
                guard !timedOut, abs(elapsed - 30) < 0.000001 else { return false }
                elapsed = 0
                let completed = try await SnapshotWait.waitWhile(uptime: { elapsed }, sleep: { elapsed += $0 }, pending: { elapsed < 0.1 })
                let immediate = try await SnapshotWait.waitWhile(timeout: 0, pending: { false })
                return completed && immediate && elapsed <= 0.15
            } catch { print("等待用例失败：\(error)"); return false }
        }))
        tests.append(("UI.Quota/花费窗口与模型汇总", { @MainActor in
            let state = PanelPreviewRenderer.syntheticState()
            let data = Data(#"[{"daily":[{"date":"2026-09-30","totalCost":2.5,"totalTokens":100,"modelBreakdowns":[{"modelName":"example-a","totalTokens":100}]},{"date":"2026-09-29","totalCost":3,"totalTokens":200,"modelBreakdowns":[{"modelName":"example-b","totalTokens":200}]},{"date":"2026-08-01","totalCost":999,"totalTokens":9999}]}]"#.utf8)
            guard let days = try? CodexBarParser.cost(data) else { return false }
            state.costs[.codex] = days
            guard let value = state.costDisplay(.codex) else { return false }
            return value.todayCost == 2.5 && value.totalCost == 5.5 && value.todayTokens == 100 && value.totalTokens == 300 && value.mostUsedModel == "example-b" && state.costDisplay(.deepseek) == nil
        }))
        tests.append(("UI.Quota/渠道色与峰值透明度", { QuotaColorTests.palette() }))
        tests.append(("UI.Quota/花费三列与日期边界", { CostTests.totals() }))
        tests.append(("UI.Quota/花费点击与渠道切换", { CostTests.selection() }))
        tests.append(("UI.Quota/近七天花费快照", { CostTests.snapshot() }))
        tests.append(("UI.Settings/原生菜单", { @MainActor in
            let state = PanelPreviewRenderer.syntheticState()
            var opened = false, config = false, folder = false, quit = false
            state.onOpenSettings = { opened = $0 == nil }
            state.onOpenConfig = { config = true }; state.onShowConfigFolder = { folder = true }; state.onQuit = { quit = true }
            let menu = SettingsMenu.make(state: state)
            guard menu.items.map(\.title) == ["设置…", "", "打开配置文件…", "在访达中显示配置目录", "", "关于 MeowMac", "退出 MeowMac"],
                  menu.items[0].keyEquivalent == ",", menu.items[6].keyEquivalent == "q", menu.items.allSatisfy({ $0.submenu == nil }),
                  menu.items[1].isSeparatorItem, menu.items[4].isSeparatorItem else { return false }
            for index in [0, 2, 3, 6] {
                let item = menu.items[index]
                guard let action = item.action, NSApplication.shared.sendAction(action, to: item.target, from: item) else { return false }
            }
            return opened && config && folder && quit && SettingsMenu.configurationFile.deletingLastPathComponent() == SettingsMenu.configurationDirectory
        }))
        tests.append(("UI.AIDiagnosis/只读预览与取消复制启动", { AIDiagnosisUITests.preview() }))
        tests.append(("UI.AIDiagnosis/生产面板入口与热提醒", { await AIDiagnosisUITests.entry() }))
        tests.append(("UI.AIDiagnosis/360pt 原生浅深预览", { await AIDiagnosisUITests.screenshots() }))
        tests.append(("UI.AIAgentSettings/生产控件与保存失败回读", { AIAgentSettingsTests.controls() }))
        tests.append(("UI.AIAgentSettings/通用栏合成截图", { AIAgentSettingsTests.previews() }))
        tests.append(("UI.Settings/即时设置回调与条件", { ImmediateSettingsTests.callbacks() }))
        tests.append(("UI.Settings/六栏合成窗口预览", { await ImmediateSettingsTests.previews() }))
        tests.append(("UI.Settings/空渠道入口", { ImmediateSettingsTests.quotaLink() }))
        tests.append(("UI.Cat/真实初始化与诊断快照", { CatIntegrationTests.snapshotAndSwitch() }))
        tests.append(("UI.Cat/同名导入菜单", { CatIntegrationTests.menuDuplicates() }))
        tests.append(("UI.Panel/真实容器的自然高度与切换", { await PanelLayoutTests.heights() }))
        tests.append(("UI.PanelLayout/渲染顺序固定区与快照", { PanelLayoutUITests.renderingAndSnapshot() }))
        tests.append(("UI.PanelLayout/默认与极端容器尺寸", { await PanelLayoutUITests.sizes() }))
        tests.append(("UI.PanelLayout/隐藏网络检查后点击总览告警", { await PanelLayoutUITests.hiddenNetworkIssueClick() }))
        tests.append(("UI.StyleIntegration/启动切猫包默认与坏文件", { StyleIntegrationTests.lifecycle() }))
        tests.append(("UI.AppearanceSettings/联合保存与部分失败及无猫", { await StyleSettingsTests.combinedSave() }))
        tests.append(("UI.AppearanceSettings/恢复默认生产菜单与无猫禁用", { StyleSettingsTests.resetMenu() }))
        tests.append(("UI.SettingsWindow/切栏与关闭三选确认", { await SettingsWindowTests.navigation() }))
        tests.append(("UI.SettingsWindow/单例定位与记忆", { SettingsWindowTests.window() }))
        tests.append(("UI.SettingsWindow/固定侧栏与移除切换按钮", { SettingsWindowTests.fixedSidebar() }))
        tests.append(("UI.SettingsWindow/快捷键窗口与修饰键", { SettingsWindowTests.shortcut() }))
        tests.append(("UI.StyleSettings/原生菜单与保存生命周期", { StyleSettingsTests.lifecycle() }))
        tests.append(("UI.StyleSettings/真实控件与色板", { await StyleSettingsTests.controls() }))
        tests.append(("UI.StyleSettings/渠道预览条与草稿颜色", { await StyleSettingsTests.colorPreviews() }))
        tests.append(("UI.LayoutSettings/原生菜单与草稿", { LayoutSettingsTests.menuAndDraft() }))
        tests.append(("UI.LayoutSettings/保存失败与切猫", { LayoutSettingsTests.saveAndFailure() }))
        tests.append(("UI.LayoutSettings/拖动回调与坏文件提示", { await LayoutSettingsTests.dropAndRecovery() }))
        tests.append(("UI.LayoutSettings/总览拖动与缺失窗口", { await LayoutSettingsTests.overview() }))
        tests.append(("UI.LayoutSettings/真实控件操作", { await LayoutSettingsTests.actualControls() }))
        tests.append(("UI.LayoutSettings/快照到达刷新与选择保留", { LayoutSettingsTests.snapshotArrival() }))
        tests.append(("UI.LayoutSettings/总览指标共用颜色", { LayoutSettingsTests.overviewColors() }))
        if ProcessInfo.processInfo.environment["MEOWMAC_RENDER_DIR"] != nil {
            tests.append(("UI.LayoutAcceptance/真实容器合成对照", { await LayoutAcceptanceTests.render() }))
            tests.append(("UI.RenderPreview/三个标签页", { await SelfTestMain.renderPanel() }))
            tests.append(("UI.RenderComponents/基础组件", { SelfTestMain.renderComponents() }))
            tests.append(("UI.RenderOverview/总览与设置", { SelfTestMain.renderOverview() }))
        }
        tests.append(contentsOf: ProxyTrafficCoreTests.tests())
        tests.append(contentsOf: ProxyTrafficSummaryTests.tests.map { name, run in (name, { @MainActor in run() }) })
        tests.append(("ProxyTraffic.Preview/补充全页浅深合成布局", { ProxyTrafficNativeTests.supplementalPreviews() }))
        tests.append(("ProxyTraffic.Native/真实面板浅深六种状态", { await ProxyTrafficNativeTests.previews() }))
        tests.append(contentsOf: proxyTrafficClientTests().map { name, run in (name, { @MainActor in run() }) })
        tests.append(contentsOf: ProxyTrafficStoreTests.tests.map { name, run in (name, { @MainActor in run() }) })
        tests.append(contentsOf: ProxyTrafficSessionTests.tests.map { name, run in (name, { @MainActor in run() }) })
        tests.append(contentsOf: ProxyTrafficExportTests.tests.map { name, run in (name, { @MainActor in run() }) })
        let filters = CommandLine.arguments.dropFirst().map { $0.lowercased() }
        if filters.contains("--list") {
            tests.forEach { print($0.0 + (TestPresentationPolicy.requiresForeground($0.0) ? " [需 MEOWMAC_UI_TESTS=1]" : "")) }
            exit(0)
        }
        let foregroundAllowed = TestPresentationPolicy.allowsForeground(environment: ProcessInfo.processInfo.environment)
        var failed = 0, executed = 0, skipped = 0
        for (name, run) in tests where (filters.isEmpty || filters.contains(where: { name.lowercased().contains($0) })) && (!name.contains(".Live") || ProcessInfo.processInfo.environment["MEOWMAC_LIVE"] == "1") {
            if !foregroundAllowed && TestPresentationPolicy.requiresForeground(name) {
                print("SKIP \(name)（可见 UI 验收需 MEOWMAC_UI_TESTS=1）"); skipped += 1; continue
            }
            if ProcessInfo.processInfo.environment["MEOWMAC_TEST_TRACE"] == "1" { print("START \(name)"); fflush(stdout) }
            executed += 1
            if await run() { print("PASS \(name)") }
            else { print("FAIL \(name)"); failed += 1 }
            if !foregroundAllowed && NSApplication.shared.windows.contains(where: \.isVisible) {
                print("FAIL 后台测试出现可见窗口：\(name)"); failed += 1
            }
        }
        if !foregroundAllowed && NSApplication.shared.isActive {
            print("FAIL 后台测试激活了自测应用"); failed += 1
        }
        print("自测完成：\(executed) 项，\(failed) 项失败，\(skipped) 项前台验收未执行")
        exit(failed > 0 ? 1 : 0)
    }

    private static func temporaryConfig(_ contents: String?, check: (URL) -> Bool) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        if let contents {
            do { try Data(contents.utf8).write(to: url) }
            catch { print("测试夹具写入失败：\(error)"); return false }
        }
        return check(url)
    }

    private static func missingConfig() -> Bool {
        temporaryConfig(nil) { url in
            let result = ConfigStore.load(from: url)
            return result.error == nil && result.config == LocalConfig() && !FileManager.default.fileExists(atPath: url.path)
        }
    }

    private static func partialConfig() -> Bool {
        temporaryConfig(#"{"schemaVersion":1,"quotaRemainingWarn":0.15}"#) { url in
            let result = ConfigStore.load(from: url)
            return result.error == nil && result.config.quotaRemainingWarn == 0.15 && result.config.diskRemainingWarn == 0.10
        }
    }

    private static func invalidConfig() -> Bool {
        temporaryConfig("{broken") { url in
            let result = ConfigStore.load(from: url)
            return result.config == LocalConfig() && result.error?.contains("配置文件无效") == true
        }
    }

    private static func completeConfig() -> Bool {
        var expected = LocalConfig()
        expected.quotaRemainingWarn = 0.12
        expected.processSampleSeconds = 42
        guard let data = try? JSONEncoder().encode(expected), let text = String(data: data, encoding: .utf8) else { return false }
        return temporaryConfig(text) { url in
            let result = ConfigStore.load(from: url)
            return result.error == nil && result.config == expected
        }
    }

    private static func liveSystem() -> Bool {
        let collector = SystemCollector()
        _ = collector.sample()
        Thread.sleep(forTimeInterval: 2)
        let snapshot = collector.sample()
        let cpu = snapshot.cpuUsage.map { String(format: "%.3f", $0) } ?? "不可用"
        let swap = snapshot.swapUsedBytes.map { String($0) } ?? "不可用"
        let disk = snapshot.diskAvailableBytes.map { String($0) } ?? "不可用"
        let total = snapshot.diskTotalBytes.map { String($0) } ?? "不可用"
        let power = snapshot.battery.systemPowerWatts.map { String($0) } ?? "不可用"
        let temperature = snapshot.battery.temperatureCelsius.map { String($0) } ?? "不可用"
        print("CPU=\(cpu) pressure=\(snapshot.memoryPressure.rawValue) swap=\(swap) disk=\(disk)/\(total) power=\(power) temperature=\(temperature) thermal=\(snapshot.thermal.rawValue)")
        return snapshot.cpuUsage != nil && snapshot.diskAvailableBytes != nil && snapshot.battery.temperatureCelsius != nil
    }

    private static func topParser() -> Bool {
        let text = "PID    COMMAND          %CPU POWER\n1 First 99.0 99.0\n\nPID    COMMAND          %CPU POWER\n42 VeryLongProcessN 91.0 12.0\n43 Example Helper 10.0 5.0\n"
        let values = TopParser.secondSample(text)
        return values?.count == 2 && values?[0].pid == 42 && values?[0].name == "VeryLongProcessN" && values?[1].name == "Example Helper"
    }

    private static func liveEnergy() -> Bool {
        do {
            let values = try EnergySampler.processes()
            print("能耗排行条目数=\(values.count)")
            return !values.isEmpty
        } catch {
            print("能耗采样失败：\(error)")
            return false
        }
    }

    private static func liveRusage() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,uid="]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() }
        catch { print("ps 不可用：\(error)"); return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let rows = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        let otherPID: Int32? = rows.compactMap { row in
            let fields = row.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), let uid = Int32(fields[1]),
                  uid != Int32(getuid()), uid != 0 else { return nil }
            return pid
        }.first
        for (label, pid) in [("当前用户", getpid()), ("root", Int32(1)), ("其他用户", otherPID ?? -1)] {
            guard pid > 0 else { print("ri_energy_nj \(label)：无进程样本"); continue }
            var usage = rusage_info_v6()
            let code = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, Int32(RUSAGE_INFO_V6), $0)
                }
            }
            print("ri_energy_nj \(label)：\(code == 0 ? "可读" : "不可读")，errno=\(code == 0 ? 0 : errno)")
        }
        return true
    }

    /// 本机扫描：记录耗时，并和 `sessions --json-v2` 的 active/idle 对照。两者语义不同（见 D8），差异只打印不判失败。
    private static func liveActivity() -> Bool {
        let scanner = AgentActivityScanner()
        var scan: [QuotaProvider: AgentActivity] = [:]
        let started = Date()
        for _ in 0..<5 { scan = scanner.scan(now: Date()) }
        let milliseconds = Date().timeIntervalSince(started) * 200
        print("会话扫描：claude=\(scan[.claude] ?? .unavailable) codex=\(scan[.codex] ?? .unavailable)，单次约 \(Int(milliseconds)) ms")
        do {
            let sessions = try CodexBarClient(path: LocalConfig().codexBarCLIPath).sessions()
            for provider in SessionPoller.providers {
                print("  CLI \(provider.rawValue) active=\(sessions.contains { $0.provider == provider && $0.active })")
            }
        } catch { print("  CLI 对照失败：\(error)") }
        return scan.values.allSatisfy { $0 != .unavailable } && milliseconds < 50
    }

    private static func liveQuota() -> Bool {
        do {
            let client = CodexBarClient(path: LocalConfig().codexBarCLIPath)
            let result = try client.dashboard()
            guard Set(result.snapshots.keys) == Set(QuotaProvider.defaults) else {
                print("额度采集：成功 \(result.snapshots.count) 个，错误 \(result.errors.count) 个")
                return false
            }
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/acceptance/quota-live-history/\(UUID().uuidString)", isDirectory: true)
            let history = QuotaHistoryStore(directory: directory)
            for snapshot in result.snapshots.values { try history.append(snapshot) }
            let counts = try QuotaProvider.defaults.map { try history.read($0).count }
            print("额度采集：4 个渠道，历史新增；各渠道行数 \(counts)")
            return counts.allSatisfy { $0 > 0 }
        } catch { print("额度实测失败：\(error)"); return false }
    }

    private static func liveCodexCost() -> Bool {
        do {
            let values = try CodexBarClient(path: LocalConfig().codexBarCLIPath).cost(.codex)
            print("Codex 花费日数：\(values.count)")
            return !values.isEmpty
        } catch { print("Codex 花费解析失败：\(error)"); return false }
    }

    private static func liveClaudeCost() -> Bool {
        do {
            let values = try CodexBarClient(path: LocalConfig().codexBarCLIPath).cost(.claude)
            print("Claude 花费日数：\(values.count)")
            return !values.isEmpty
        } catch { print("Claude 花费解析失败：\(error)"); return false }
    }

    private static func healthSignals() -> Bool {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let config = LocalConfig()
        let cases: [(NetworkTone, [Double], HealthLevel, PanelTab?)] = [
            (.green, [], .normal, nil),
            (.yellow, [], .warn, .network),
            (.red, [90], .severe, .network),
            (.green, [81], .warn, .quota),
        ]
        for (network, quota, level, tab) in cases {
            let input = HealthInputs(system: nil, energy: nil, quotaUsedPercent: quota, network: network,
                                     failedSources: [:], fairSince: nil, now: now)
            let result = HealthEvaluator.evaluate(input, config: config)
            if result.level != level || result.worst?.tab != tab { return false }
        }
        let failure = HealthInputs(system: nil, energy: nil, quotaUsedPercent: [], network: .gray,
                                   failedSources: ["system": 2], fairSince: nil, now: now)
        return HealthEvaluator.evaluate(failure, config: config).level == .warn
    }

    private static func healthMessages() -> Bool {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let config = LocalConfig()
        let snapshot = SystemSnapshot(timestamp: now, cpuUsage: 0.2, memoryPressure: .normal, swapUsedBytes: 0,
                                      diskAvailableBytes: 50, diskTotalBytes: 100, networkReceivedBytesPerSecond: 0,
                                      networkSentBytesPerSecond: 0, battery: BatteryMetrics(temperatureCelsius: 35, systemPowerWatts: 6), thermal: .serious)
        let noProcess = HealthInputs(system: snapshot, energy: nil, quotaUsedPercent: [], network: .green,
                                     failedSources: [:], fairSince: nil, now: now)
        guard HealthEvaluator.evaluate(noProcess, config: config).worst?.message.contains("未发现异常进程") == true else { return false }
        let process = ProcessEnergy(pid: 42, name: "Example", cpuPercent: 95, impact: 5)
        let diagnosis = EnergyDiagnosis(topFive: [process], runaway: [process], longAssertions: [], prolongedMemoryPressure: false)
        let withProcess = HealthInputs(system: snapshot, energy: diagnosis, quotaUsedPercent: [], network: .green,
                                       failedSources: [:], fairSince: nil, now: now)
        return HealthEvaluator.evaluate(withProcess, config: config).issues.contains { $0.message.contains("进程 CPU") }
    }

    private static func healthSystemSignals() -> Bool {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = SystemSnapshot(timestamp: now, cpuUsage: 0.3, memoryPressure: .warn, swapUsedBytes: 0,
            diskAvailableBytes: 5, diskTotalBytes: 100, networkReceivedBytesPerSecond: nil,
            networkSentBytesPerSecond: nil, battery: BatteryMetrics(temperatureCelsius: 40, systemPowerWatts: 8), thermal: .fair, memoryPressurePercent: 80)
        let process = ProcessEnergy(pid: 42, name: "Example", cpuPercent: 95, impact: 12)
        let assertion = SleepAssertion(pid: 43, type: "PreventSystemSleep", startedAt: now.addingTimeInterval(-7200))
        let energy = EnergyDiagnosis(topFive: [process], runaway: [process], longAssertions: [assertion], prolongedMemoryPressure: true)
        let input = HealthInputs(system: snapshot, energy: energy, quotaUsedPercent: [], network: .green,
            failedSources: [:], fairSince: now.addingTimeInterval(-300), now: now,
            ruleEvaluations: [RuleClockTests.memoryEvaluation(endingAt: now)])
        let result = HealthEvaluator.evaluate(input, config: LocalConfig())
        return result.level == .warn && result.issues.count == 3 && result.coolingHint
            && result.issues.contains { $0.message.contains("磁盘") }
            && !result.issues.contains { $0.message.contains("休眠") }
            && result.issues.contains { $0.message.contains("内存") }
    }

    private static func openingTab() -> Bool {
        let normal = HealthSummary(level: .normal, issues: [], coolingHint: false)
        let warning = HealthSummary(level: .warn, issues: [HealthIssue(level: .warn, tab: .quota, message: "额度")], coolingHint: false)
        return DefaultPanelLayout.openingTab(summary: normal, lastViewed: .network) == .network
            && DefaultPanelLayout.openingTab(summary: warning, lastViewed: .system) == .quota
    }

    private static func catMotion() -> Bool {
        let config = LocalConfig()
        guard abs(CatMotion.frameInterval(load: 0, config: config) - 0.5) < 0.000001,
              abs(CatMotion.frameInterval(load: 0.5, config: config) - 0.185) < 0.000001,
              abs(CatMotion.frameInterval(load: 0.7, config: config) - 0.131) < 0.000001,
              abs(CatMotion.frameInterval(load: 1, config: config) - 0.05) < 0.000001 else { return false }
        let samples = (0...100).map { CatMotion.frameInterval(load: Double($0) / 100, config: config) }
        guard zip(samples, samples.dropFirst()).allSatisfy({ $0 >= $1 }),
              CatMotion.frameInterval(load: .nan, config: config) == 0.5 else { return false }
        var custom = config; custom.idleFrameSeconds = 0.8; custom.fullFrameSeconds = 0.1
        guard abs(CatMotion.frameInterval(load: 0.5, config: custom) - 0.31) < 0.000001 else { return false }
        custom.fullFrameSeconds = .nan
        guard CatMotion.frameInterval(load: 0.5, config: custom) == 0.185 else { return false }
        var motion = CatMotion(alpha: 0.5)
        let first = motion.update(cpu: 1, pressure: .normal, config: config)
        let second = motion.update(cpu: 1, pressure: .normal, config: config)
        return first < 0.5 && second < first && second > 0.05
    }

    @MainActor private static func renderCat() -> Bool {
        let directory = ProcessInfo.processInfo.environment["MEOWMAC_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        do {
            if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            for (name, level, frame) in [("normal", HealthLevel.normal, 0), ("warn", .warn, 2), ("severe", .severe, 0)] {
                let data = directory != nil ? PanelPreviewRenderer.catPreviewPNG(frame: frame, level: level)! : CatRenderer.png(frame: frame, level: level)
                guard !data.isEmpty else { return false }
                if let directory { try data.write(to: directory.appendingPathComponent("cat-\(name).png"), options: .atomic) }
            }
            if let directory {
                for index in 0..<5 { try PanelPreviewRenderer.catPreviewPNG(frame: index, level: .normal)!.write(to: directory.appendingPathComponent("cat-frame-\(index + 1).png")) }
                try PanelPreviewRenderer.catPreviewPNG(frame: 2, level: .normal, load: 0.7)!.write(to: directory.appendingPathComponent("cat-speed.png"))
            }
            return true
        } catch { print("猫图预览失败：\(error)"); return false }
    }

    private static func catPixels() -> Bool {
        guard let image = NSBitmapImageRep(data: CatRenderer.png(frame: 0, level: .normal, pixelSize: 180)),
              let corner = image.colorAt(x: 0, y: 0),
              let center = image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2) else { return false }
        return corner.alphaComponent < 0.1 && center.alphaComponent > 0.9
    }

    private static func quotaParsing() -> Bool {
        for provider in QuotaProvider.defaults {
            let text = "[{\"provider\":\"\(provider.rawValue)\",\"source\":\"fixture\",\"usage\":{\"primary\":{\"usedPercent\":42,\"windowMinutes\":300,\"resetDescription\":\"稍后重置\"},\"pace\":{\"summary\":\"正常\"}}}]"
            guard let snapshot = try? CodexBarParser.usage(Data(text.utf8), at: Date(timeIntervalSince1970: 1_000_000)),
                  snapshot.provider == provider, snapshot.windows.count == 1, snapshot.windows[0].usedPercent == 42 else { return false }
        }
        return (try? CodexBarParser.usage(Data("[{\"provider\":\"codex\",\"usage\":{}}]".utf8), at: Date())) == nil
    }

    private static func dashboardParsing() -> Bool {
        let text = #"{"providers":[{"id":"codex","source":"fixture","windows":[{"usedPercent":70,"remainingPercent":30,"label":"5 小时","kind":"primary","resetAt":"2026-01-01T12:00:00Z"}],"credits":{"remaining":12.5},"error":null},{"id":"claude","error":{"message":"示例错误"},"windows":[]},{"id":"other","windows":[]}] }"#
        guard let result = try? CodexBarParser.dashboard(Data(text.utf8), at: Date(timeIntervalSince1970: 1_000_000)),
              let codex = result.snapshots[.codex] else { return false }
        return codex.windows.count == 1 && codex.windows[0].usedPercent == 70 && codex.windows[0].resetsAt != nil && codex.credits == 12.5 && result.errors[.claude] == "示例错误"
    }

    private static func costAndSessions() -> Bool {
        let cost = Data(#"[{"provider":"codex","daily":[{"date":"2026-01-01","totalCost":1.25},{"date":"2026-01-02","totalCost":2.5}]}]"#.utf8)
        let sessions = Data(#"[{"provider":"claude","state":"active"},{"provider":"codex","state":"idle"},{"provider":"pi","state":"active"}]"#.utf8)
        guard let daily = try? CodexBarParser.cost(cost), daily.count == 2, daily[1].totalCost == 2.5,
              let parsed = try? CodexBarParser.sessions(sessions), parsed.count == 2 else { return false }
        return parsed[0].provider == .claude && parsed[0].active && parsed[1].provider == .codex && !parsed[1].active
    }

    private static func quotaSchedule() -> Bool {
        var schedule = QuotaSchedule()
        let config = LocalConfig()
        let start = Date(timeIntervalSince1970: 1_000_000)
        guard schedule.dueFullRefresh(at: start, config: config) else { return false }
        schedule.markFullRefresh(at: start)
        guard !schedule.dueFullRefresh(at: start.addingTimeInterval(1799), config: config),
              schedule.dueFullRefresh(at: start.addingTimeInterval(1800), config: config),
              schedule.manualRefresh(at: start, config: config),
              !schedule.manualRefresh(at: start.addingTimeInterval(59), config: config),
              schedule.manualRefresh(at: start.addingTimeInterval(60), config: config) else { return false }
        schedule.sessionUpdate([SessionActivity(provider: .claude, active: true)], at: start, config: config)
        schedule.sessionUpdate([], at: start.addingTimeInterval(60), config: config)
        guard schedule.dueFinishRefresh(at: start.addingTimeInterval(359)).isEmpty else { return false }
        schedule.sessionUpdate([SessionActivity(provider: .claude, active: true)], at: start.addingTimeInterval(360), config: config)
        guard schedule.dueFinishRefresh(at: start.addingTimeInterval(361)).isEmpty else { return false }
        schedule.sessionUpdate([], at: start.addingTimeInterval(420), config: config)
        guard schedule.dueFinishRefresh(at: start.addingTimeInterval(720)) == [.claude] else { return false }
        schedule.sleep()
        guard !schedule.dueFullRefresh(at: start.addingTimeInterval(1800), config: config) else { return false }
        return schedule.wake(at: start.addingTimeInterval(1800), config: config)
    }

    private static func quotaHistory() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QuotaHistoryStore(directory: directory)
        let old = Date(timeIntervalSince1970: 1_000_000)
        let recent = old.addingTimeInterval(91 * 86400)
        let window = QuotaWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        do {
            try store.append(QuotaSnapshot(provider: .codex, source: "fixture", updatedAt: old, windows: [window], paceSummary: nil, credits: nil))
            try store.append(QuotaSnapshot(provider: .codex, source: "fixture", updatedAt: recent, windows: [window], paceSummary: nil, credits: nil))
            guard try store.read(.codex).count == 2 else { return false }
            try store.prune(before: recent.addingTimeInterval(-90 * 86400))
            return try store.read(.codex).count == 1
        } catch { print("历史测试失败：\(error)"); return false }
    }

    private static func moHistory() -> Bool {
        let fixture = #"{"logs":{},"sessions":[{"command":"mo clean","started_at":"2026-01-01T12:00:00Z","size":1024},{"command":"mo clean","started_at":"2026-01-02T12:00:00Z","size":2048}],"deletions":[]}"#
        guard let latest = try? MoHistoryParser.latest(Data(fixture.utf8)), latest.startedAt == ISO8601DateFormatter().date(from: "2026-01-02T12:00:00Z") else { return false }
        let local = #"{"sessions":[{"command":"mo clean","started_at":"2026-01-01T12:00:00Z","size":1024},{"command":"mo clean","started_at":"2026-01-02 12:00:00","size":"2KB"}]}"#
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        guard let localLatest = try? MoHistoryParser.latest(Data(local.utf8), timeZone: zone),
              localLatest.startedAt == ISO8601DateFormatter().date(from: "2026-01-02T04:00:00Z"), localLatest.sizeDescription == "2KB" else { return false }
        let localT = #"{"sessions":[{"command":"mo clean","started_at":"2026-01-03T12:00:00","size":"3KB"},{"command":"mo clean","started_at":"invalid-date","size":"4KB"},{"command":"mo status","started_at":"2026-01-04 12:00:00","size":"5KB"}]}"#
        guard let localTLatest = try? MoHistoryParser.latest(Data(localT.utf8), timeZone: zone),
              localTLatest.startedAt == ISO8601DateFormatter().date(from: "2026-01-03T04:00:00Z") else { return false }
        return (try? MoHistoryParser.latest(Data(#"{"sessions":[]}"#.utf8))) == nil
    }

    @MainActor private static func renderComponents() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MEOWMAC_RENDER_DIR"] else { return false }
        do {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                guard let data = PanelPreviewRenderer.componentPNG(dark: dark), !data.isEmpty else { return false }
                try data.write(to: directory.appendingPathComponent("components-\(dark ? "dark" : "light").png"))
            }
            return true
        } catch { print("组件渲染失败：\(error)"); return false }
    }

    @MainActor private static func renderOverview() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MEOWMAC_RENDER_DIR"] else { return false }
        do {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for dark in [false, true] {
                for alert in [false, true] {
                    guard let data = PanelPreviewRenderer.overviewPNG(alert: alert, dark: dark) else { return false }
                    try data.write(to: directory.appendingPathComponent("overview-\(alert ? "alert" : "normal")-\(dark ? "dark" : "light").png"))
                }
                guard let data = PanelPreviewRenderer.settingsPNG(dark: dark) else { return false }
                try data.write(to: directory.appendingPathComponent("settings-\(dark ? "dark" : "light").png"))
            }
            return true
        } catch { print("总览渲染失败：\(error)"); return false }
    }

    @MainActor private static func renderPanel() async -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MEOWMAC_RENDER_DIR"] else { return false }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let state = PanelPreviewRenderer.syntheticState()
        state.networkModel?.checkEgressIP()
        while state.networkModel?.isCheckingEgress == true { await Task.yield() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for tab in PanelTab.allCases {
                state.selectedTab = tab
                for dark in [false, true] {
                    guard let data = PanelPreviewRenderer.png(state: state, dark: dark), !data.isEmpty else { return false }
                    let name = "panel-\(tab.rawValue)-\(dark ? "dark" : "light").png"
                    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                }
            }
            for provider in [QuotaProvider.claude, .codex] {
                let state = PanelPreviewRenderer.syntheticState(quotaAlert: provider == .codex)
                state.selectedTab = .quota; state.selectedProvider = provider
                for dark in [false, true] {
                    guard let data = PanelPreviewRenderer.png(state: state, dark: dark) else { return false }
                    try data.write(to: directory.appendingPathComponent("panel-quota-\(provider.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
            let networkFailure = PanelPreviewRenderer.syntheticState()
            networkFailure.selectedTab = .network
            networkFailure.networkModel = PanelPreviewRenderer.networkModel(failure: true, now: networkFailure.now())
            networkFailure.networkTone = .red
            networkFailure.networkModel?.checkEgressIP()
            while networkFailure.networkModel?.isCheckingEgress == true { await Task.yield() }
            for dark in [false, true] {
                guard let data = PanelPreviewRenderer.png(state: networkFailure, dark: dark) else { return false }
                try data.write(to: directory.appendingPathComponent("panel-network-failure-\(dark ? "dark" : "light").png"))
            }
            let alert = PanelPreviewRenderer.syntheticState(alert: true)
            for dark in [false, true] {
                guard let data = PanelPreviewRenderer.png(state: alert, dark: dark) else { return false }
                try data.write(to: directory.appendingPathComponent("panel-system-alert-\(dark ? "dark" : "light").png"))
            }
            state.selectedTab = .quota
            state.selectedProvider = .deepseek
            state.quotas.removeValue(forKey: .deepseek)
            state.quotaErrors[.deepseek] = "示例：服务暂时不可用"
            for dark in [false, true] {
                guard let data = PanelPreviewRenderer.png(state: state, dark: dark), !data.isEmpty else { return false }
                try data.write(to: directory.appendingPathComponent("panel-quota-error-\(dark ? "dark" : "light").png"), options: .atomic)
            }
            return true
        } catch { print("面板预览失败：\(error)"); return false }
    }
}
