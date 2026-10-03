import Foundation
import MeowMacCore
import MeowMacSystem
import MeowMacUI
import MeowMacQuota
import Darwin
import AppKit

@main
enum SelfTestMain {
    @MainActor static func main() async {
        var tests: [(String, @MainActor () async -> Bool)] = [
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
            ("Core.Energy/失控进程时间线", { SelfTestMain.runawayTimeline() }),
            ("Core.Energy/忽略三小时休眠断言", { MemoryTests.ignoredAssertions() }),
            ("System.Metrics/活动监视器内存口径", { MemoryTests.usage() }),
            ("UI.System/内存压力百分比", { MemoryTests.pressure() }),
            ("System.Live.Energy/进程", { SelfTestMain.liveEnergy() }),
            ("System.Live.Energy.Rusage/跨用户读取", { SelfTestMain.liveRusage() }),
            ("Quota.Live/四渠道刷新", { SelfTestMain.liveQuota() }),
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
            ("Core.Quota/四渠道解析", { SelfTestMain.quotaParsing() }),
            ("Core.Quota/dashboard 解析", { SelfTestMain.dashboardParsing() }),
            ("Core.Quota/花费与会话", { SelfTestMain.costAndSessions() }),
            ("Core.Quota/调度", { SelfTestMain.quotaSchedule() }),
            ("Core.Quota/历史保留", { SelfTestMain.quotaHistory() }),
            ("Core.System/mo 清理历史", { SelfTestMain.moHistory() }),
        ]
        for test in DataTests.tests { tests.append((test.0, { test.1() })) }
        for test in ReminderTests.tests { tests.append((test.0, { (try? test.1()) ?? false })) }
        tests.append(("UI.ReminderStore/重载坏文件与安全写入", { (try? ReminderTests.storage()) ?? false }))
        tests.append(("UI.Reminders/动作重载到期与详情定位", { ReminderUITests.lifecycle() }))
        tests.append(("UI.Reminders/原生入口暂缓恢复与容器", { await ReminderUITests.nativeControls() }))
        tests.append(("UI.Reminders/启动到期切猫与快照", { ReminderIntegrationTests.runtime() }))
        tests.append(("UI.Reminders/真实弹出面板与超高筛选", { await ReminderIntegrationTests.popover() }))
        for test in HistoryTests.tests { tests.append((test.0, { test.1() })) }
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
            let state = PanelPreviewRenderer.syntheticState(); state.loginEnabled = true
            var selected: String?, imported = false, shown = false, importedHistory = false
            state.onImportCodexBarHistory = { importedHistory = true }
            state.onSelectCat = { selected = $0 }
            state.onImportCat = { imported = true }
            state.onShowCats = { shown = true }
            let menu = SettingsMenu.make(state: state)
            guard let cats = menu.items[3].submenu,
                  cats.items.map(\.title) == ["标准瘦身", "圆润", "圆润美短", "瘦身橘白", "", "导入猫配置…", "在访达中显示猫配置"],
                  cats.items[0].state == .on, cats.items[1].state == .off else { return false }
            for index in [1, 5, 6] {
                let item = cats.items[index]
                guard let action = item.action, NSApplication.shared.sendAction(action, to: item.target, from: item) else { return false }
            }
            let historyItem = menu.items[6]
            guard historyItem.title == "导入 CodexBar 历史…", let historyAction = historyItem.action,
                  NSApplication.shared.sendAction(historyAction, to: historyItem.target, from: historyItem) else { return false }
            return menu.items.map(\.title) == ["打开配置文件…", "在访达中显示配置目录", "", "猫配置", "布局与显示…", "样式…", "导入 CodexBar 历史…", "开机启动", "", "关于 MeowMac", "退出 MeowMac"]
                && menu.items[3].isEnabled && menu.items[4].isEnabled && menu.items[5].isEnabled && menu.items[7].state == .on
                && menu.items[2].isSeparatorItem && menu.items[8].isSeparatorItem && menu.items[10].keyEquivalent == "q"
                && selected == "builtin.round" && imported && shown && importedHistory
                && SettingsMenu.configurationFile.deletingLastPathComponent() == SettingsMenu.configurationDirectory
        }))
        tests.append(("UI.Cat/真实初始化与诊断快照", { CatIntegrationTests.snapshotAndSwitch() }))
        tests.append(("UI.Cat/同名导入菜单", { CatIntegrationTests.menuDuplicates() }))
        tests.append(("UI.Panel/真实容器的自然高度与切换", { await PanelLayoutTests.heights() }))
        tests.append(("UI.PanelLayout/渲染顺序固定区与快照", { PanelLayoutUITests.renderingAndSnapshot() }))
        tests.append(("UI.PanelLayout/默认与极端容器尺寸", { await PanelLayoutUITests.sizes() }))
        tests.append(("UI.PanelLayout/隐藏网络检查后点击总览告警", { await PanelLayoutUITests.hiddenNetworkIssueClick() }))
        tests.append(("UI.StyleIntegration/启动切猫包默认与坏文件", { StyleIntegrationTests.lifecycle() }))
        tests.append(("UI.StyleSettings/原生菜单与保存生命周期", { StyleSettingsTests.lifecycle() }))
        tests.append(("UI.StyleSettings/真实控件与色板", { StyleSettingsTests.controls() }))
        tests.append(("UI.LayoutSettings/原生菜单与草稿", { LayoutSettingsTests.menuAndDraft() }))
        tests.append(("UI.LayoutSettings/保存失败与切猫", { LayoutSettingsTests.saveAndFailure() }))
        tests.append(("UI.LayoutSettings/拖动回调与坏文件提示", { await LayoutSettingsTests.dropAndRecovery() }))
        tests.append(("UI.LayoutSettings/总览拖动与缺失窗口", { await LayoutSettingsTests.overview() }))
        tests.append(("UI.LayoutSettings/真实控件操作", { LayoutSettingsTests.actualControls() }))
        tests.append(("UI.LayoutSettings/快照到达刷新与选择保留", { LayoutSettingsTests.snapshotArrival() }))
        if ProcessInfo.processInfo.environment["MEOWMAC_RENDER_DIR"] != nil {
            tests.append(("UI.LayoutAcceptance/真实容器合成对照", { await LayoutAcceptanceTests.render() }))
            tests.append(("UI.RenderPreview/三个标签页", { await SelfTestMain.renderPanel() }))
            tests.append(("UI.RenderComponents/基础组件", { SelfTestMain.renderComponents() }))
            tests.append(("UI.RenderOverview/总览与设置", { SelfTestMain.renderOverview() }))
        }
        let filters = CommandLine.arguments.dropFirst().map { $0.lowercased() }
        if filters.contains("--list") {
            tests.forEach { print($0.0) }
            return
        }
        var failed = 0
        for (name, run) in tests where (filters.isEmpty || filters.contains(where: { name.lowercased().contains($0) })) && (!name.contains(".Live") || ProcessInfo.processInfo.environment["MEOWMAC_LIVE"] == "1") {
            if await run() { print("PASS \(name)") }
            else { print("FAIL \(name)"); failed += 1 }
        }
        if failed > 0 { exit(1) }
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

    private static func runawayTimeline() -> Bool {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let high = ProcessEnergy(pid: 42, name: "Example", cpuPercent: 95, impact: 2)
        let low = ProcessEnergy(pid: 42, name: "Example", cpuPercent: 20, impact: 1)
        let config = LocalConfig()
        var tracker = EnergyTracker()
        guard tracker.evaluate(processes: [high], assertions: [], pressure: .warn, now: start, config: config).runaway.isEmpty,
              tracker.evaluate(processes: [high], assertions: [], pressure: .warn, now: start.addingTimeInterval(600), config: config).runawayDurations[42] == 600,
              tracker.evaluate(processes: [low], assertions: [], pressure: .normal, now: start.addingTimeInterval(660), config: config).runaway.isEmpty,
              tracker.evaluate(processes: [high], assertions: [], pressure: .normal, now: start.addingTimeInterval(720), config: config).runaway.isEmpty,
              tracker.evaluate(processes: [], assertions: [], pressure: .normal, now: start.addingTimeInterval(800), config: config).runaway.isEmpty else { return false }
        return tracker.evaluate(processes: [high], assertions: [], pressure: .normal, now: start.addingTimeInterval(1_300), config: config).runaway.isEmpty
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

    private static func liveQuota() -> Bool {
        do {
            let client = CodexBarClient(path: LocalConfig().codexBarCLIPath)
            let result = try client.dashboard()
            guard Set(result.snapshots.keys) == Set(QuotaProvider.allCases) else {
                print("额度采集：成功 \(result.snapshots.count) 个，错误 \(result.errors.count) 个")
                return false
            }
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/acceptance/quota-live-history/\(UUID().uuidString)", isDirectory: true)
            let history = QuotaHistoryStore(directory: directory)
            for snapshot in result.snapshots.values { try history.append(snapshot) }
            let counts = try QuotaProvider.allCases.map { try history.read($0).count }
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
            networkSentBytesPerSecond: nil, battery: BatteryMetrics(temperatureCelsius: 40, systemPowerWatts: 8), thermal: .fair)
        let process = ProcessEnergy(pid: 42, name: "Example", cpuPercent: 95, impact: 12)
        let assertion = SleepAssertion(pid: 43, type: "PreventSystemSleep", startedAt: now.addingTimeInterval(-7200))
        let energy = EnergyDiagnosis(topFive: [process], runaway: [process], longAssertions: [assertion], prolongedMemoryPressure: true)
        let input = HealthInputs(system: snapshot, energy: energy, quotaUsedPercent: [], network: .green,
            failedSources: [:], fairSince: now.addingTimeInterval(-300), now: now)
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
        for provider in QuotaProvider.allCases {
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
