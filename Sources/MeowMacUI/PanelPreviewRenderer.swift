import AppKit
import SwiftUI
import MeowMacCore
import TunCanaryUI

@MainActor
public enum PanelPreviewRenderer {
    public static func syntheticState(alert: Bool = false, quotaAlert: Bool = false) -> PanelState {
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        state.quotaProxyStatus = .ready
        let now = ISO8601DateFormatter().date(from: "2026-09-30T06:35:00Z")!
        state.now = { now }
        state.chartMinutes = 15
        for index in 0...360 {
            let pointTime = now.addingTimeInterval(Double(index - 360) * 10)
            let cpu = index == 360 ? (alert ? 0.71 : 0.24) : 0.25 + 0.15 * sin(Double(index) / 30)
            let snapshot = SystemSnapshot(timestamp: pointTime, cpuUsage: cpu, memoryPressure: .normal,
                                          swapUsedBytes: 1024 * 1024 * 1024,
                                          diskAvailableBytes: 116_000_000_000 - Int64(index) * 5_000_000 + (index >= 240 ? 6_000_000_000 : 0), diskTotalBytes: 500_000_000_000,
                                          networkReceivedBytesPerSecond: 2.4 * 1024 * 1024, networkSentBytesPerSecond: 128 * 1024,
                                          battery: BatteryMetrics(temperatureCelsius: 34 + cpu * 5,
                                                                  systemPowerWatts: 7 + cpu * 12),
                                          thermal: alert && index >= 150 || (150...180).contains(index) ? .fair : .nominal,
                                          memoryUsedBytes: 11 * 1_073_741_824, memoryTotalBytes: 16 * 1_073_741_824, memoryPressurePercent: 55,
                                          sensors: syntheticSensors(.idle, cpu: cpu))
            state.chartHistory.append(snapshot)
            state.snapshot = snapshot
        }
        let names = ["WindowServer", "ExampleSync", "Finder", "kernel_task", "ExampleWorker"]
        let processes = names.enumerated().map { index, name in ProcessEnergy(pid: Int32(index + 42), name: name, cpuPercent: [12.4, 5.8, 2.1, 1.4, 0.2][index], impact: [18.2, 9.1, 3.4, 2.8, 0.4][index]) }
        let runaway = ProcessEnergy(pid: 50, name: "ExampleWorker", cpuPercent: 98, impact: 87.6)
        state.energy = EnergyDiagnosis(topFive: alert ? [runaway] + Array(processes.prefix(4)) : processes,
            runaway: alert ? [runaway] : [], longAssertions: [], prolongedMemoryPressure: false,
            runawayDurations: alert ? [50: 2100] : [:])
        if alert { state.fairSince = now.addingTimeInterval(-2100) }
        for provider in QuotaProvider.defaults where provider != .deepseek {
            let short = QuotaWindow(usedPercent: provider == .claude ? 28 : 40, windowMinutes: 300,
                resetsAt: now.addingTimeInterval(9900), resetDescription: nil)
            let long = QuotaWindow(usedPercent: provider == .codex && quotaAlert ? 70 : 38, windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(0.49 * 604800), resetDescription: nil, identifier: "secondary", name: provider == .codex ? "每周" : "7 天")
            state.quotas[provider] = QuotaSnapshot(provider: provider, source: "oauth", updatedAt: now.addingTimeInterval(-180),
                windows: [.codex, .claude].contains(provider) ? [short, long] : [short], paceSummary: "示例",
                credits: nil, accountEmail: [.codex, .claude].contains(provider) ? "demo@example.com" : nil,
                planName: provider == .codex ? "Plus" : provider == .claude ? "Max" : nil,
                codexResetCredits: provider == .codex ? QuotaResetCredits(availableCount: 2, expiresAt: [now.addingTimeInterval(864000), now.addingTimeInterval(1728000)]) : nil)
            var rows = (0..<28).map { index in
                let sampled = now.addingTimeInterval(Double(index - 27) * 18000)
                return QuotaHistoryLine(sampledAt: sampled, provider: provider, windowMinutes: 300,
                    usedPercent: Double(20 + (index * 17) % 76), resetsAt: sampled.addingTimeInterval(9900), windowID: "primary")
            }
            let start = long.resetsAt!.addingTimeInterval(-604800)
            rows += (0..<12).map { index in
                QuotaHistoryLine(sampledAt: start.addingTimeInterval(now.timeIntervalSince(start) * Double(index) / 11), provider: provider,
                    windowMinutes: 10080, usedPercent: long.usedPercent * pow(Double(index) / 11, 0.8), resetsAt: long.resetsAt, windowID: "secondary")
            }
            state.quotaHistory[provider] = rows
        }
        // DeepSeek 是余额型渠道：没有额度窗口和历史，只有余额。
        state.quotas[.deepseek] = QuotaSnapshot(provider: .deepseek, source: "api", updatedAt: now.addingTimeInterval(-180), windows: [], paceSummary: nil,
            credits: nil, balance: QuotaBalance(amount: "¥88.00", detail: "充值 ¥80.00 · 赠送 ¥8.00"))
        for provider in [QuotaProvider.claude, .codex] {
            state.costs[provider] = (0..<30).map { index in
                let date = Calendar.current.date(byAdding: .day, value: index - 29, to: now)!
                let tokens = 160000 + index * 19000
                return DailyCost(date: DisplayDate.format(date, pattern: "yyyy-MM-dd"), totalCost: Double((index * 7) % 15 + 1) * 0.4,
                    totalTokens: tokens, models: [CostModel(name: provider == .codex ? "example-coder" : "example-assistant", tokens: tokens)])
            }
            state.localStorage[provider] = LocalStorageSnapshot(sampledAt: now, sessionsBytes: 6300000000, cacheBytes: 2100000000, otherBytes: 700000000, sessionFileCount: 1284)
        }
        state.networkModel = networkModel(failure: false, now: now)
        state.networkTone = .green
        state.lastCleaning = CleaningRecord(startedAt: now.addingTimeInterval(-172800), sizeDescription: "8.4 GB")
        state.lastRefreshedAt = now.addingTimeInterval(-60)
        return state
    }

    /// 电池卡片的四种状态（设计稿 battery.html），全部为虚构数据。
    public enum BatteryPreview: String, CaseIterable {
        case discharge, charging, ac, sparse
    }

    public static func batteryState(_ kind: BatteryPreview) -> PanelState {
        let state = syntheticState()
        guard let latest = state.snapshot else { return state }
        let now = latest.timestamp
        let status: BatteryStatus
        switch kind {
        case .discharge:
            status = BatteryStatus(state: .battery, percent: 62, maxCapacityPercent: 100, rawMaxCapacity: 4620, designCapacity: 4500,
                                   cycleCount: 77, designCycleCount: 1000, powerWatts: 9.3, minutesToEmpty: 260, adapterWatts: nil)
        case .charging:
            status = BatteryStatus(state: .charging, percent: 68, maxCapacityPercent: 100, rawMaxCapacity: 4620, designCapacity: 4500,
                                   cycleCount: 77, designCycleCount: 1000, powerWatts: 24.6, minutesToFull: 35, adapterWatts: 65)
        case .ac:
            status = BatteryStatus(state: .acNotCharging, percent: 80, maxCapacityPercent: 100, rawMaxCapacity: 4620, designCapacity: 4500,
                                   cycleCount: 77, designCycleCount: 1000, powerWatts: 0, adapterWatts: 65)
        case .sparse:
            status = BatteryStatus(state: .battery, percent: 58, maxCapacityPercent: 100, rawMaxCapacity: 4620, designCapacity: 4500,
                                   cycleCount: 77, designCycleCount: 1000, powerWatts: 8.1, adapterWatts: nil)
        }
        state.snapshot = SystemSnapshot(timestamp: now, cpuUsage: latest.cpuUsage, memoryPressure: latest.memoryPressure,
            swapUsedBytes: latest.swapUsedBytes, diskAvailableBytes: latest.diskAvailableBytes, diskTotalBytes: latest.diskTotalBytes,
            networkReceivedBytesPerSecond: latest.networkReceivedBytesPerSecond, networkSentBytesPerSecond: latest.networkSentBytesPerSecond,
            battery: BatteryMetrics(temperatureCelsius: 31, systemPowerWatts: 9.3, status: status), thermal: latest.thermal,
            memoryUsedBytes: latest.memoryUsedBytes, memoryTotalBytes: latest.memoryTotalBytes,
            memoryPressurePercent: latest.memoryPressurePercent, sensors: latest.sensors)
        state.batteryHistory = BatteryHistory(records: batteryRecords(kind, now: now))
        return state
    }

    /// 近 24 小时的虚构电量点，每 5 分钟一个，形状参照设计稿：长时间接电源、凌晨 2 小时没有记录、两段用电池。
    static func batteryRecords(_ kind: BatteryPreview, now: Date) -> [BatteryHistoryRecord] {
        if kind == .sparse {
            // 刚启动 4 分钟，只有一个点（D10：还没有可统计的用电池区间）。
            return [BatteryHistoryRecord(sampledAt: now.addingTimeInterval(-240), percent: 58, state: .battery, dischargeWatts: 8.1, segmentStart: true)]
        }
        var rows: [BatteryHistoryRecord] = []
        var newSegment = true
        for step in 0...288 {
            let date = now.addingTimeInterval(Double(step - 288) * 300)
            let i = Double(step) / 2
            if (80..<104).contains(step) { newSegment = true; continue }
            var state: BatteryPowerState = .acNotCharging, percent = 80.0
            if i >= 90 && i < 108 { state = .battery; percent = 80 - (i - 90) * 1.65 }
            else if i >= 108 && i < 120 { state = .charging; percent = min(80, 50.3 + (i - 108) * 2.6) }
            else if i >= 120 {
                switch kind {
                case .ac: state = .acNotCharging; percent = 80
                case .charging where i >= 132: state = .charging; percent = min(80, 71 - 12 * 0.75 + (i - 132) * 0.5)
                default: state = .battery; percent = 80 - (i - 120) * 0.75
                }
            }
            if state == .charging, percent >= 80 { state = .acNotCharging }
            rows.append(BatteryHistoryRecord(sampledAt: date, percent: Int(percent.rounded()), state: state,
                                             dischargeWatts: state == .battery ? 8.6 + sin(Double(step) / 5) * 0.6 : nil, segmentStart: newSegment))
            newSegment = false
        }
        return rows
    }

    /// 传感器的六种状态（沿用 sensors.html 的状态划分，界面以 system-tab-redesign.html 方案 A 为准），全部为虚构数据。
    public enum SensorPreview: String, CaseIterable {
        case idle, spinning, cooling, gpuMissing, noFan, unavailable
    }

    public static func syntheticSensors(_ variant: SensorPreview, cpu: Double) -> SensorReadings {
        let average = 44 + cpu * 40, maxRPM = 6000.0
        let rpm: Double
        switch variant {
        case .idle, .gpuMissing, .noFan, .unavailable: rpm = 0
        case .spinning: rpm = 1500 + cpu * 2000
        case .cooling: rpm = 4600 + cpu * 700
        }
        switch variant {
        case .unavailable: return .unavailable("无法连接传感器服务")
        case .noFan:
            return SensorReadings(cpuAverageCelsius: average, cpuMaxCelsius: average + 4.3, cpuSource: .smc, gpuAverageCelsius: average - 2.9, fans: [])
        case .gpuMissing:
            return SensorReadings(cpuAverageCelsius: average, cpuMaxCelsius: average + 4.8, cpuSource: .smc, gpuAverageCelsius: nil,
                                  fans: [FanReading(rpm: rpm, maxRPM: maxRPM)])
        default:
            return SensorReadings(cpuAverageCelsius: average, cpuMaxCelsius: average + 5.3, cpuSource: .smc, gpuAverageCelsius: average - 3.4,
                                  fans: [FanReading(rpm: rpm, maxRPM: maxRPM)])
        }
    }

    /// 只替换传感器读数和对应的趋势历史，其余沿用正常合成状态。
    public static func sensorState(_ variant: SensorPreview, diagnosis: Bool = false) -> PanelState {
        let state = syntheticState()
        if diagnosis { state.energy = syntheticState(alert: true).energy }
        let now = state.now()
        var history = ChartHistory()
        var latest: SystemSnapshot?
        for index in 0...360 {
            let time = now.addingTimeInterval(Double(index - 360) * 10)
            let ramp = Double(index) / 360
            let cpu: Double
            switch variant {
            case .spinning: cpu = 0.45 + 0.4 * ramp
            case .cooling: cpu = 0.85 + 0.08 * sin(Double(index) / 24)
            default: cpu = 0.15 + 0.08 * sin(Double(index) / 30)
            }
            let snapshot = SystemSnapshot(timestamp: time, cpuUsage: cpu, memoryPressure: .normal, swapUsedBytes: 1024 * 1024 * 1024,
                                          diskAvailableBytes: 120_000_000_000, diskTotalBytes: 500_000_000_000,
                                          networkReceivedBytesPerSecond: 0, networkSentBytesPerSecond: 0,
                                          battery: BatteryMetrics(temperatureCelsius: 31 + cpu * 6, systemPowerWatts: 6 + cpu * 30),
                                          thermal: .nominal, memoryUsedBytes: 11 * 1_073_741_824, memoryTotalBytes: 16 * 1_073_741_824,
                                          memoryPressurePercent: 55, sensors: syntheticSensors(variant, cpu: cpu))
            history.append(snapshot)
            latest = snapshot
        }
        state.chartHistory = history
        state.snapshot = latest
        if variant == .cooling { state.fanHighSince = now.addingTimeInterval(-360) }
        return state
    }

    /// 展开的系统页整页，用于逐张对照 system-tab-redesign.html；材质沿用预览退路。
    public static func quotaPagePNG(state: PanelState, dark: Bool) -> Data? {
        state.selectedTab = .quota
        return png(state: state, dark: dark)
    }
    public static func systemPagePNG(state: PanelState, dark: Bool) -> Data? {
        state.selectedTab = .system
        return png(state: state, dark: dark)
    }

    public static func overviewPNG(alert: Bool, dark: Bool) -> Data? {
        renderPNG(OverviewView(state: syntheticState(alert: alert)), width: Design.panelWidth, height: alert ? 160 : 140, dark: dark)
    }
    /// 分节自身没有材质层；仅作补充对照，原生弹出面板单独测量。
    public static func resetMonitorPNG(state: PanelState, dark: Bool) -> Data? {
        let view = CodexResetMonitorView(display: state.codexResetState.display)
            .padding(16).frame(width: Design.panelWidth)
        let measure = NSHostingView(rootView: view)
        let height = ceil(measure.fittingSize.height)
        return renderPNG(view, width: Design.panelWidth, height: height, dark: dark)
    }
    public static func settingsPNG(dark: Bool) -> Data? {
        let state = syntheticState(); state.loginEnabled = true
        return renderPNG(SettingsMenuPreview(state: state), width: Design.menuWidth, height: 210, dark: dark)
    }

    public static func catPreviewPNG(frame: Int, level: HealthLevel, load: Double = 0) -> Data? {
        renderPNG(Image(nsImage: CatRenderer.image(frame: frame, level: level, load: load, size: CGSize(width: 112, height: 72))).renderingMode(.original), width: 112, height: 72, dark: false, scale: 1)
    }
    public static func componentPNG(dark: Bool) -> Data? {
        renderPNG(DesignComponentPreview(), width: Design.panelWidth, height: 460, dark: dark)
    }

    // ImageRenderer 无法绘制系统玻璃合成层，预览沿用 SPEC 的普通材质退路。
    // 应用默认 previewMaterial 为 false，仍使用 macOS 26 的原生 glassEffect。
    static func renderPNG<V: View>(_ view: V, width: CGFloat, height: CGFloat, dark: Bool, scale: CGFloat = 2) -> Data? {
        let app = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let oldAppearance = app.appearance
        app.appearance = appearance
        defer { app.appearance = oldAppearance }
        var result: Data?
        appearance.performAsCurrentDrawingAppearance {
            let background = Color(nsColor: NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)!)
            let renderer = ImageRenderer(content: view
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.previewMaterial, true)
                .frame(width: width, height: height, alignment: .top)
                .background(background))
            renderer.proposedSize = ProposedViewSize(width: width, height: height)
            renderer.scale = scale
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) { result = rep.representation(using: .png, properties: [:]) }
        }
        return result
    }

    public static func png(state: PanelState, dark: Bool) -> Data? {
        let view = PanelView(state: state, expanded: true)
        let measure = NSHostingView(rootView: view.environment(\.previewMaterial, true))
        let height = ceil(measure.fittingSize.height)
        return renderPNG(view, width: Design.panelWidth, height: height, dark: dark)
    }

    /// 等 SwiftUI 的几何偏好和 preferredContentSize 连续稳定，再取尺寸。
    public static func settleLayout(_ controller: NSHostingController<PanelView>) async throws -> CGSize {
        var previous = CGSize.zero, stable = 0
        for _ in 0..<100 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 10_000_000)
            let size = controller.preferredContentSize
            if size.width > 0 && size.height > 0 {
                controller.view.window?.setContentSize(size)
                stable = size == previous ? stable + 1 : 0
                if stable >= 5 { return size }
            }
            previous = size
        }
        throw CocoaError(.coderInvalidValue)
    }
}
