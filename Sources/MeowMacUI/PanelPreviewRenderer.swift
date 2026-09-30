import AppKit
import SwiftUI
import MeowMacCore
import TunCanaryUI

@MainActor
public enum PanelPreviewRenderer {
    public static func syntheticState(alert: Bool = false) -> PanelState {
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
            state.quotas[provider] = QuotaSnapshot(provider: provider, source: "示例", updatedAt: now,
                windows: [QuotaWindow(usedPercent: provider == .claude ? 28 : 40, windowMinutes: 300,
                                      resetsAt: now.addingTimeInterval(9900), resetDescription: "1 小时后")],
                paceSummary: "用量正常", credits: provider == .codex ? 12.5 : nil)
            state.quotaHistory[provider] = (0..<7).map { index in
                QuotaHistoryLine(sampledAt: now.addingTimeInterval(Double(index - 6) * 86400),
                                 provider: provider, windowMinutes: 300,
                                 usedPercent: Double(20 + index * 8), resetsAt: nil)
            }
        }
        state.costs[.claude] = (0..<7).map { DailyCost(date: "9-\(20 + $0)", totalCost: Double($0 + 1) * 0.4) }
        state.costs[.codex] = (0..<7).map { DailyCost(date: "9-\(20 + $0)", totalCost: Double($0 + 1) * 0.2) }
        state.networkModel = AppModel.preview(.firstLaunch)
        state.networkTone = .green
        state.lastRefreshedAt = now
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
        _ = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = PanelView(state: state)
            .frame(width: 380)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hosting
        let size = CGSize(width: 380, height: min(600, max(300, hosting.fittingSize.height)))
        hosting.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        window.close()
        return rep.representation(using: .png, properties: [:])
    }
}
