import AppKit
import SwiftUI
import MeowMacCore
import TunCanaryUI

@MainActor
public enum PanelPreviewRenderer {
    public static func syntheticState(alert: Bool = false, quotaAlert: Bool = false) -> PanelState {
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        let now = ISO8601DateFormatter().date(from: "2026-09-30T06:35:00Z")!
        state.now = { now }
        state.chartMinutes = 15
        for index in 0..<60 {
            let pointTime = now.addingTimeInterval(Double(index - 59) * 60)
            let cpu = index == 59 ? (alert ? 0.71 : 0.24) : 0.25 + 0.15 * sin(Double(index) / 5)
            let snapshot = SystemSnapshot(timestamp: pointTime, cpuUsage: cpu, memoryPressure: .normal,
                                          swapUsedBytes: 1024 * 1024 * 1024,
                                          diskAvailableBytes: 120_000_000_000, diskTotalBytes: 500_000_000_000,
                                          networkReceivedBytesPerSecond: 10_000, networkSentBytesPerSecond: 5_000,
                                          battery: BatteryMetrics(temperatureCelsius: 34 + cpu * 5,
                                                                  systemPowerWatts: 7 + cpu * 12),
                                          thermal: alert && index >= 25 || (25...30).contains(index) ? .fair : .nominal,
                                          memoryUsedBytes: 11 * 1_073_741_824, memoryTotalBytes: 16 * 1_073_741_824)
            state.chartHistory.append(snapshot)
            state.snapshot = snapshot
        }
        let names = ["WindowServer", "ExampleSync", "Finder", "kernel_task", "ExampleWorker"]
        let processes = names.enumerated().map { index, name in ProcessEnergy(pid: Int32(index + 42), name: name, cpuPercent: [12.4, 5.8, 2.1, 1.4, 0.2][index], impact: [18.2, 9.1, 3.4, 2.8, 0.4][index]) }
        let runaway = ProcessEnergy(pid: 50, name: "ExampleWorker", cpuPercent: 98, impact: 87.6)
        let assertion = SleepAssertion(pid: 43, type: "PreventSystemSleep", startedAt: now.addingTimeInterval(-11520))
        state.energy = EnergyDiagnosis(topFive: alert ? [runaway] + Array(processes.prefix(4)) : processes,
            runaway: alert ? [runaway] : [], longAssertions: alert ? [assertion] : [], prolongedMemoryPressure: false,
            runawayDurations: alert ? [50: 2100] : [:])
        if alert { state.fairSince = now.addingTimeInterval(-2100) }
        for provider in QuotaProvider.allCases {
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

    public static func overviewPNG(alert: Bool, dark: Bool) -> Data? {
        renderPNG(OverviewView(state: syntheticState(alert: alert)), width: Design.panelWidth, height: alert ? 160 : 140, dark: dark)
    }
    public static func settingsPNG(dark: Bool) -> Data? {
        let state = syntheticState(); state.loginEnabled = true
        return renderPNG(SettingsMenuPreview(state: state), width: Design.menuWidth, height: 210, dark: dark)
    }

    public static func componentPNG(dark: Bool) -> Data? {
        renderPNG(DesignComponentPreview(), width: Design.panelWidth, height: 460, dark: dark)
    }

    // ImageRenderer 无法绘制系统玻璃合成层，预览沿用 SPEC 的普通材质退路。
    // 应用默认 previewMaterial 为 false，仍使用 macOS 26 的原生 glassEffect。
    static func renderPNG<V: View>(_ view: V, width: CGFloat, height: CGFloat, dark: Bool) -> Data? {
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
            renderer.scale = 2
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
}
