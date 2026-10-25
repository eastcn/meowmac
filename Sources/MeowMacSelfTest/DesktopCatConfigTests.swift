import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

/// 桌面猫配置与指标目录（plan 条目 1）。夹具全部虚构。
@MainActor
enum DesktopCatConfigTests {
    static var tests: [(String, @MainActor () async -> Bool)] {
        [
            ("Core.DesktopCat/新建：默认值与只新增 desktopCat 字段", { created() }),
            ("Core.DesktopCat/编辑：增减重排、角与屏、上下限", { edited() }),
            ("Core.DesktopCat/停用再启用保留指标和位置", { toggled() }),
            ("Core.DesktopCat/坏配置回退且不改写文件", { broken() }),
            ("Core.DesktopCat/整个配置无效时拒绝保存", { invalidFile() }),
            ("Core.DesktopCat/目录按渠道、电池与传感器生成", { catalog() }),
            ("Core.DesktopCat/每类数值、单位与颜色角色", { values() }),
            ("UI.DesktopCat/即时写入与失败不改界面", { stateUpdate() }),
            ("UI.DesktopCat/外观恢复默认不改动桌面猫", { await appearanceReset() }),
        ]
    }

    static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("meowmac-desktopcat-" + UUID().uuidString + ".json")
    }

    static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func created() -> Bool {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let empty = ConfigStore.load(from: url).config.desktopCat
        guard empty == DesktopCatConfig(), !empty.enabled, empty.metrics == ["system.cpu", "system.memory", "quota.claude.minutes:300", "network.speed"],
              empty.placement == DesktopCatPlacement(display: nil, corner: .bottomRight), empty.diagnostics.isEmpty else { return false }
        let original = #"{"schemaVersion":1,"quotaRemainingWarn":0.15,"futureField":{"nested":[1,2,"示例"]},"alertRules":{"builtin":{},"custom":[]}}"#
        do {
            try Data(original.utf8).write(to: url)
            guard let before = json(url) else { return false }
            try ConfigStore.saveDesktopCat(empty.with(enabled: true), to: url)
            guard var after = json(url), let desktop = after.removeValue(forKey: "desktopCat") as? [String: Any] else { return false }
            guard NSDictionary(dictionary: before).isEqual(to: after), desktop["enabled"] as? Bool == true,
                  desktop["metrics"] as? [String] == DesktopCatConfig.defaultMetrics,
                  (desktop["placement"] as? [String: Any])?["corner"] as? String == "bottomRight",
                  (desktop["placement"] as? [String: Any])?["display"] == nil else { return false }
            let reloaded = ConfigStore.load(from: url)
            guard reloaded.error == nil, reloaded.config.desktopCat.enabled, reloaded.config.quotaRemainingWarn == 0.15 else { return false }
            // 文件不存在时只写 schemaVersion 和 desktopCat。
            try FileManager.default.removeItem(at: url)
            try ConfigStore.saveDesktopCat(empty.with(enabled: true), to: url)
            return Set((json(url) ?? [:]).keys) == ["schemaVersion", "desktopCat"]
        } catch { print("桌面猫新建用例失败：\(error)"); return false }
    }

    static func edited() -> Bool {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            var config = DesktopCatConfig(enabled: true)
            // 第 5 项拒绝；重复拒绝；未知拒绝。
            guard (try? config.adding("system.power")) == nil, (try? config.adding("system.cpu")) == nil else { return false }
            config = try config.removing("network.speed").adding("system.power")
            guard config.metrics == ["system.cpu", "system.memory", "quota.claude.minutes:300", "system.power"] else { return false }
            guard (try? config.removing("network.speed")) == nil, (try? DesktopCatConfig().adding("example.unknown")) == nil else { return false }
            config = try config.moving("system.power", to: 0)
            guard config.metrics == ["system.power", "system.cpu", "system.memory", "quota.claude.minutes:300"] else { return false }
            config = try config.moving("system.power", to: 99)
            guard config.metrics.last == "system.power" else { return false }
            config = config.with(placement: DesktopCatPlacement(display: "00000000-0000-0000-0000-00000000A001", corner: .topLeft))
            try ConfigStore.saveDesktopCat(config, to: url)
            let loaded = ConfigStore.load(from: url).config.desktopCat
            guard loaded == config, loaded.placement.corner == .topLeft, loaded.placement.display == "00000000-0000-0000-0000-00000000A001" else { return false }
            // 减到 1 项后拒绝再减。
            var single = config
            for id in config.metrics.dropLast() { single = try single.removing(id) }
            guard single.metrics == ["system.power"] else { return false }
            do { _ = try single.removing("system.power"); return false } catch DesktopCatError.lastMetric {} catch { return false }
            do { _ = try DesktopCatConfig().adding("system.disk"); return false } catch DesktopCatError.full {} catch { return false }
            do { _ = try single.toggling("system.power"); return false } catch DesktopCatError.lastMetric {} catch { return false }
            guard try single.toggling("system.disk").metrics == ["system.power", "system.disk"] else { return false }
            // 校验拒绝 0 项和 5 项。
            guard (try? DesktopCatConfig(metrics: []).validated()) == nil,
                  (try? DesktopCatConfig(metrics: DesktopCatConfig.defaultMetrics + ["system.disk"]).validated()) == nil else { return false }
            return true
        } catch { print("桌面猫编辑用例失败：\(error)"); return false }
    }

    static func toggled() -> Bool {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            let config = DesktopCatConfig(enabled: true, metrics: ["network.speed", "system.cpu"],
                                          placement: DesktopCatPlacement(display: "00000000-0000-0000-0000-00000000B002", corner: .topRight))
            try ConfigStore.saveDesktopCat(config, to: url)
            try ConfigStore.saveDesktopCat(ConfigStore.load(from: url).config.desktopCat.with(enabled: false), to: url)
            let off = ConfigStore.load(from: url).config.desktopCat
            guard !off.enabled, off.metrics == config.metrics, off.placement == config.placement else { return false }
            try ConfigStore.saveDesktopCat(off.with(enabled: true), to: url)
            return ConfigStore.load(from: url).config.desktopCat == config
        } catch { print("桌面猫停用用例失败：\(error)"); return false }
    }

    static func load(_ text: String, check: (DesktopCatConfig, Data, URL) -> Bool) -> Bool {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(text.utf8)
        do { try data.write(to: url) } catch { return false }
        let result = ConfigStore.load(from: url)
        guard result.error == nil else { print("桌面猫坏配置被当成整个文件无效：\(text)"); return false }
        // 读取不改写文件。
        guard (try? Data(contentsOf: url)) == data else { return false }
        return check(result.config.desktopCat, data, url)
    }

    static func broken() -> Bool {
        let base = #"{"schemaVersion":1,"quotaRemainingWarn":0.15,"#
        let cases: [(String, (DesktopCatConfig) -> Bool)] = [
            (#""desktopCat":"yes"}"#, { $0 == DesktopCatConfig() && !$0.diagnostics.isEmpty }),
            (#""desktopCat":{"enabled":"true","metrics":["system.cpu"]}}"#, { $0 == DesktopCatConfig() && !$0.diagnostics.isEmpty }),
            (#""desktopCat":{"enabled":true,"metrics":"system.cpu"}}"#, { $0 == DesktopCatConfig() && !$0.enabled && !$0.diagnostics.isEmpty }),
            (#""desktopCat":{"enabled":true,"metrics":["system.cpu",3]}}"#, { $0 == DesktopCatConfig() && !$0.diagnostics.isEmpty }),
            (#""desktopCat":{"enabled":true,"placement":{"corner":7}}}"#, { $0 == DesktopCatConfig() && !$0.diagnostics.isEmpty }),
            (#""desktopCat":{"enabled":true,"metrics":["system.cpu","system.cpu","network.speed","system.cpu"]}}"#,
             { $0.enabled && $0.metrics == ["system.cpu", "network.speed"] && !$0.diagnostics.isEmpty }),
            (#""desktopCat":{"enabled":true,"metrics":["system.cpu","system.memory","system.power","system.disk","network.speed","network.status"]}}"#,
             { $0.metrics == ["system.cpu", "system.memory", "system.power", "system.disk"] && !$0.diagnostics.isEmpty }),
            (#""desktopCat":{"enabled":true,"metrics":["example.one","quota..x","quota.claude.minutes:0"]}}"#,
             { $0.enabled && $0.metrics == DesktopCatConfig.defaultMetrics && !$0.diagnostics.isEmpty }),
            (#""desktopCat":{"enabled":true,"metrics":[]}}"#, { $0.metrics == DesktopCatConfig.defaultMetrics }),
            (#""desktopCat":{"enabled":true,"metrics":["example.future","network.status"],"placement":{"display":"00000000-0000-0000-0000-00000000C003","corner":"middle"}}}"#,
             { $0.enabled && $0.metrics == ["network.status"] && $0.placement == DesktopCatPlacement(display: "00000000-0000-0000-0000-00000000C003", corner: .bottomRight) && $0.diagnostics.count == 2 }),
        ]
        for (index, (suffix, check)) in cases.enumerated() {
            guard load(base + suffix, check: { config, _, _ in check(config) }) else { print("桌面猫坏配置第 \(index + 1) 例未通过"); return false }
        }
        // 未知 id 只在界面修改后按有效列表写回；其他字段保留。
        return load(base + #""desktopCat":{"enabled":true,"metrics":["example.future","network.status"]}}"#) { config, _, url in
            guard (json(url)?["desktopCat"] as? [String: Any])?["metrics"] as? [String] == ["example.future", "network.status"] else { return false }
            do { try ConfigStore.saveDesktopCat(config.adding("system.cpu"), to: url) } catch { return false }
            let object = json(url)
            return (object?["desktopCat"] as? [String: Any])?["metrics"] as? [String] == ["network.status", "system.cpu"]
                && object?["quotaRemainingWarn"] as? Double == 0.15
        }
    }

    static func invalidFile() -> Bool {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        for text in ["{broken", #"{"schemaVersion":2}"#, #"{"schemaVersion":1,"quotaRemainingWarn":"x"}"#] {
            let data = Data(text.utf8)
            do { try data.write(to: url) } catch { return false }
            do { try ConfigStore.saveDesktopCat(DesktopCatConfig(enabled: true), to: url); return false } catch {}
            guard (try? Data(contentsOf: url)) == data else { return false }
        }
        return true
    }

    // MARK: - 目录与数值

    nonisolated static let now = Date(timeIntervalSince1970: 1_790_000_000)

    nonisolated static func snapshot(cpu: Double? = 0.24, pressure: MemoryPressure = .normal, pressurePercent: Double? = 55,
                         down: Double? = 2.4 * 1024 * 1024, up: Double? = 128 * 1024,
                         available: Int64? = 196_000_000_000, total: Int64? = 500_000_000_000, power: Double? = 8.6,
                         battery: BatteryStatus? = BatteryStatus(state: .battery, percent: 62),
                         sensors: SensorReadings? = SensorReadings(cpuAverageCelsius: 42, cpuMaxCelsius: 50, cpuSource: .smc,
                                                                   gpuAverageCelsius: nil, fans: [FanReading(rpm: 0, maxRPM: 6000)])) -> SystemSnapshot {
        SystemSnapshot(timestamp: now, cpuUsage: cpu, memoryPressure: pressure, swapUsedBytes: nil,
                       diskAvailableBytes: available, diskTotalBytes: total, networkReceivedBytesPerSecond: down,
                       networkSentBytesPerSecond: up, battery: BatteryMetrics(temperatureCelsius: 30, systemPowerWatts: power, status: battery),
                       thermal: .nominal, memoryPressurePercent: pressurePercent, sensors: sensors)
    }

    nonisolated static func inputs(providers: [QuotaProvider] = [.claude, .codex, .deepseek], claudeUsed: Double = 28,
                       balance: String = "¥23.40", snapshot: SystemSnapshot? = snapshot()) -> DesktopCatInputs {
        var inputs = DesktopCatInputs()
        inputs.snapshot = snapshot
        inputs.quotaProviders = providers
        func windows(_ used: Double) -> [QuotaWindow] {
            [QuotaWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
             QuotaWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil, identifier: "secondary", name: "7 天")]
        }
        inputs.quotas[.claude] = QuotaSnapshot(provider: .claude, source: "oauth", updatedAt: now, windows: windows(claudeUsed), paceSummary: nil, credits: nil)
        inputs.quotas[.codex] = QuotaSnapshot(provider: .codex, source: "oauth", updatedAt: now, windows: windows(60), paceSummary: nil, credits: nil)
        inputs.quotas[.deepseek] = QuotaSnapshot(provider: .deepseek, source: "api", updatedAt: now, windows: [], paceSummary: nil, credits: nil,
                                                 balance: QuotaBalance(amount: balance, detail: nil))
        inputs.balanceThresholds = [.deepseek: 10]
        inputs.costAvailable = true; inputs.costToday = 3.42
        inputs.networkAvailable = true; inputs.networkTone = .green; inputs.networkCheckedAt = now
        inputs.proxyEnabled = true; inputs.proxyTodayBytes = 1.2 * 1_073_741_824; inputs.proxyUpdatedAt = now
        return inputs
    }

    static func catalog() -> Bool {
        let full = DesktopCatCatalog.entries(inputs())
        let expected = ["system.cpu", "system.memory", "system.power", "system.disk",
                        "sensor.temperature", "sensor.fan", "battery.level",
                        "quota.claude.minutes:300", "quota.claude.minutes:10080", "quota.codex.minutes:300", "quota.codex.minutes:10080",
                        "quota.deepseek.balance", "quota.cost.today",
                        "network.speed", "network.status", "network.proxy.today"]
        guard full.map(\.id) == expected,
              full.first(where: { $0.id == "quota.claude.minutes:300" })?.title == "Claude · 5 小时",
              full.first(where: { $0.id == "quota.codex.minutes:10080" })?.title == "Codex · 7 天",
              full.first(where: { $0.id == "quota.deepseek.balance" })?.title == "DeepSeek · 余额",
              full.map(\.category) == [.system, .system, .system, .system, .sensor, .sensor, .sensor,
                                       .quota, .quota, .quota, .quota, .quota, .quota, .network, .network, .network] else { return false }
        // 余额型渠道只有余额，没有窗口。
        guard !full.contains(where: { $0.id.hasPrefix("quota.deepseek.") && $0.id != "quota.deepseek.balance" }) else { return false }
        // 移除 Codex：窗口不在目录，已选项显示“—”且 id 保留。
        var removed = inputs(providers: [.claude, .deepseek])
        removed.costAvailable = false
        let ids = DesktopCatCatalog.entries(removed).map(\.id)
        guard !ids.contains(where: { $0.hasPrefix("quota.codex.") }), !ids.contains("quota.cost.today") else { return false }
        let selected = ["quota.codex.minutes:300", "system.cpu"]
        let items = DesktopCatCatalog.items(selected: selected, inputs: removed)
        guard items.map(\.id) == selected, items[0].missing, items[0].value == "—", items[0].bar == nil,
              items[0].label == "Codex", items[0].note == "5h", !items[1].missing,
              DesktopCatCatalog.title(for: "quota.codex.minutes:300", inputs: removed) == "Codex · 5 小时" else { return false }
        // 无电池、读不到风扇和 SoC 温度、关闭代理统计时不列。
        var bare = inputs(snapshot: snapshot(battery: .noBattery, sensors: SensorReadings(cpuAverageCelsius: nil, cpuMaxCelsius: nil, cpuSource: nil, gpuAverageCelsius: nil, fans: nil)))
        bare.proxyEnabled = false
        let bareIDs = DesktopCatCatalog.entries(bare).map(\.id)
        guard !bareIDs.contains("battery.level"), !bareIDs.contains("sensor.fan"), !bareIDs.contains("sensor.temperature"),
              !bareIDs.contains("network.proxy.today") else { return false }
        let noFans = DesktopCatCatalog.entries(inputs(snapshot: snapshot(sensors: SensorReadings(cpuAverageCelsius: 40, cpuMaxCelsius: nil, cpuSource: .smc, gpuAverageCelsius: nil, fans: []))))
        guard !noFans.map(\.id).contains("sensor.fan"), noFans.map(\.id).contains("sensor.temperature") else { return false }
        // 已选的电量在无电池机器上显示“—”。
        let battery = DesktopCatCatalog.items(selected: ["battery.level"], inputs: bare)
        return battery.count == 1 && battery[0].missing && battery[0].value == "—"
    }

    static func values() -> Bool {
        func item(_ id: String, _ inputs: DesktopCatInputs = inputs()) -> DesktopCatItem? { DesktopCatCatalog.items(selected: [id], inputs: inputs).first }
        guard let cpu = item("system.cpu"), cpu.label == "CPU", cpu.value == "24%", cpu.bar == 0.24, cpu.color == .blue, cpu.valueLevel == nil,
              cpu.tooltip(timeZone: TimeZone(identifier: "Asia/Shanghai")!).hasPrefix("CPU 使用率 24% · ") else { return false }
        guard let zero = item("system.cpu", inputs(snapshot: snapshot(cpu: 0))), zero.value == "0%", zero.bar == 0, !zero.missing else { return false }
        guard let unknown = item("system.cpu", inputs(snapshot: nil)), unknown.missing, unknown.value == "—", unknown.bar == nil,
              unknown.tooltip() == "CPU 使用率 · 暂无数据" else { return false }
        guard let memory = item("system.memory"), memory.label == "内存", memory.value == "55%", memory.color == .state(.normal), memory.valueLevel == nil,
              let high = item("system.memory", inputs(snapshot: snapshot(pressure: .warn, pressurePercent: 78))),
              high.value == "78%", high.color == .state(.warn), high.valueLevel == .warn else { return false }
        guard let power = item("system.power"), power.label == "功耗", power.value == "8.6 W", power.color == .teal,
              abs((power.bar ?? 0) - 8.6 / 40) < 0.0001 else { return false }
        guard let disk = item("system.disk"), disk.label == "磁盘", disk.note == "可用", disk.value == "196 G", disk.color == .gray,
              abs((disk.bar ?? 0) - 304.0 / 500) < 0.0001,
              let low = item("system.disk", inputs(snapshot: snapshot(available: 40_000_000_000))), low.color == .orange, low.value == "40 G" else { return false }
        guard let temperature = item("sensor.temperature"), temperature.label == "温度", temperature.value == "42 °C", temperature.color == .indigo,
              abs((temperature.bar ?? 0) - 12.0 / 70) < 0.0001 else { return false }
        guard let fan = item("sensor.fan"), fan.label == "风扇", fan.value == "0 rpm", fan.color == .brown, fan.bar == 0 else { return false }
        guard let battery = item("battery.level"), battery.label == "电池", battery.note == "放电", battery.value == "62%", battery.color == .gray,
              let charging = item("battery.level", inputs(snapshot: snapshot(battery: BatteryStatus(state: .charging, percent: 18)))),
              charging.note == "⚡", charging.color == .orange,
              item("battery.level", inputs(snapshot: snapshot(battery: BatteryStatus(state: .acNotCharging, percent: 80))))?.note == "接电源" else { return false }
        guard let claude = item("quota.claude.minutes:300"), claude.label == "Claude", claude.note == "5h", claude.value == "72%",
              claude.color == .state(.normal), claude.valueLevel == nil, claude.fullName == "Claude 5 小时窗口剩余",
              let lowQuota = item("quota.claude.minutes:300", inputs(claudeUsed: 86)), lowQuota.value == "14%",
              lowQuota.color == .state(.severe), lowQuota.valueLevel == .severe,
              item("quota.claude.minutes:10080")?.note == "7d" else { return false }
        var used = inputs(); used.quotaBasis = .used
        guard item("quota.claude.minutes:300", used)?.value == "28%", item("quota.claude.minutes:300", used)?.color == .state(.normal) else { return false }
        guard let balance = item("quota.deepseek.balance"), balance.label == "DeepSeek", balance.value == "¥23.40", balance.bar == nil, balance.valueLevel == nil,
              item("quota.deepseek.balance", inputs(balance: "¥8.20"))?.valueLevel == .warn else { return false }
        guard let cost = item("quota.cost.today"), cost.label == "花费", cost.note == "今日", cost.value == "$3.42", cost.bar == nil else { return false }
        guard let net = item("network.speed"), net.label == "网络", net.value == "↓2.4M", net.note == "↑128.0K", net.bar == 1, net.color == .state(.normal),
              item("network.speed", inputs(snapshot: snapshot(down: 128.6 * 1024 * 1024)))?.value == "↓128.6M" else { return false }
        var bad = inputs(); bad.networkTone = .red; bad.networkReason = "代理 DNS"
        guard let status = item("network.status", bad), status.value == "异常", status.note == "代理 DNS", status.valueLevel == .severe,
              status.color == .state(.severe), item("network.status")?.value == "正常", item("network.status")?.note == nil,
              item("network.speed", bad)?.color == .state(.severe) else { return false }
        var offline = inputs(); offline.networkAvailable = false
        guard item("network.status", offline)?.missing == true else { return false }
        guard let proxy = item("network.proxy.today"), proxy.label == "代理", proxy.note == "今日", proxy.value == "1.20 GB", proxy.bar == nil else { return false }
        var unavailable = inputs(); unavailable.proxyTodayBytes = nil
        return item("network.proxy.today", unavailable)?.missing == true
    }

    // MARK: - 界面写入

    static func stateUpdate() -> Bool {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        state.desktopCatConfigURL = url
        var changes: [DesktopCatConfig] = []
        state.onDesktopCatChanged = { changes.append($0) }
        guard state.updateDesktopCat({ $0.with(enabled: true) }), state.desktopCat.enabled,
              ConfigStore.load(from: url).config.desktopCat.enabled, changes.count == 1 else { return false }
        // 第 5 项被拒：界面、文件都不变，显示原因。
        let before = try? Data(contentsOf: url)
        guard !state.updateDesktopCat({ try $0.adding("system.disk") }), state.desktopCat.metrics.count == 4,
              state.desktopCatError != nil, (try? Data(contentsOf: url)) == before, changes.count == 1 else { return false }
        // 文件损坏时保存失败，不覆盖。
        try? Data("{broken".utf8).write(to: url)
        guard !state.updateDesktopCat({ $0.with(enabled: false) }), state.desktopCat.enabled, state.desktopCatError != nil,
              (try? Data(contentsOf: url)) == Data("{broken".utf8) else { return false }
        return changes.count == 1
    }

    static func appearanceReset() async -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meowmac-desktopcat-root-" + UUID().uuidString, isDirectory: true)
        let url = root.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let state = PanelPreviewRenderer.syntheticState()
            CatRuntime.initialize(state: state, store: CatStore(rootURL: root))
            state.desktopCatConfigURL = url
            guard state.updateDesktopCat({ try $0.with(enabled: true).removing("network.speed") }) else { return false }
            let bytes = try Data(contentsOf: url), current = state.desktopCat
            let model = AppearanceSettingsModel(state: state)
            model.style.restoreDefault(); model.layout?.restoreDefault()
            guard await model.save() else { return false }
            return (try? Data(contentsOf: url)) == bytes && state.desktopCat == current && !model.isDirty
        } catch { print("外观恢复默认用例失败：\(error)"); return false }
    }
}
