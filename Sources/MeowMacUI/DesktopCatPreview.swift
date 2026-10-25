import AppKit
import SwiftUI
import MeowMacCore

/// 桌面猫的合成预览：真实的内容视图和猫图缓存，数据全部虚构。玻璃用设计稿的半透明底色代替，不作材质验收。
@MainActor
public enum DesktopCatPreview {
    public enum Case: String, CaseIterable {
        case normal, alert, severe, missing, single, longSpeed, leftCorner
        /// 设计稿“提醒 · 深色”“2 项 · 缺数据 · 深色”只出深色；预览两种外观都出。
        public var title: String {
            switch self {
            case .normal: return "正常 4 项"
            case .alert: return "提醒"
            case .severe: return "严重 3 项"
            case .missing: return "2 项含缺数据"
            case .single: return "1 项"
            case .longSpeed: return "超长网速"
            case .leftCorner: return "左下角镜像"
            }
        }
    }

    public static func state(_ kind: Case) -> PanelState {
        let state = PanelPreviewRenderer.syntheticState()
        var metrics = DesktopCatConfig.defaultMetrics
        let base = state.snapshot!
        func replace(cpu: Double? = nil, pressure: MemoryPressure? = nil, percent: Double? = nil, down: Double? = nil) {
            state.snapshot = SystemSnapshot(timestamp: base.timestamp, cpuUsage: cpu ?? base.cpuUsage, memoryPressure: pressure ?? base.memoryPressure,
                swapUsedBytes: base.swapUsedBytes, diskAvailableBytes: base.diskAvailableBytes, diskTotalBytes: base.diskTotalBytes,
                networkReceivedBytesPerSecond: down ?? base.networkReceivedBytesPerSecond, networkSentBytesPerSecond: base.networkSentBytesPerSecond,
                battery: base.battery, thermal: base.thermal, memoryUsedBytes: base.memoryUsedBytes, memoryTotalBytes: base.memoryTotalBytes,
                memoryPressurePercent: percent ?? base.memoryPressurePercent, sensors: base.sensors)
        }
        func claude(used: Double) {
            guard let quota = state.quotas[.claude] else { return }
            var windows = quota.windows
            windows[0] = QuotaWindow(usedPercent: used, windowMinutes: 300, resetsAt: windows[0].resetsAt, resetDescription: nil)
            state.quotas[.claude] = QuotaSnapshot(provider: .claude, source: quota.source, updatedAt: quota.updatedAt, windows: windows,
                                                  paceSummary: nil, credits: nil)
        }
        switch kind {
        case .normal, .leftCorner: state.catLevelOverride = .normal
        case .alert:
            replace(pressure: .warn, percent: 78); claude(used: 86)
            state.catLevelOverride = .warn
        case .severe:
            metrics = ["system.cpu", "quota.claude.minutes:300", "network.status"]
            state.networkModel = PanelPreviewRenderer.networkModel(failure: true, now: state.now())
            state.networkTone = .red
            state.catLevelOverride = .severe
        case .missing:
            metrics = ["quota.claude.minutes:300", "battery.level"]
            state.catLevelOverride = .normal
        case .single:
            metrics = ["system.cpu"]
            state.catLevelOverride = .normal
        case .longSpeed:
            replace(cpu: 0.85, down: 128.6 * 1024 * 1024)
            metrics = ["network.speed", "system.cpu", "quota.deepseek.balance", "network.proxy.today"]
            state.catLevelOverride = .normal
        }
        state.desktopCat = DesktopCatConfig(enabled: true, metrics: metrics,
            placement: DesktopCatPlacement(corner: kind == .leftCorner ? .bottomLeft : .bottomRight))
        return state
    }

    /// 与窗口相同的视图模型路径：目录取值、猫图缓存和内容视图。
    public static func model(state: PanelState, cache: DesktopCatImage, dark: Bool, frame: Int = 2, scale: CGFloat = 2) -> DesktopCatViewModel {
        let model = DesktopCatViewModel()
        model.items = state.desktopCatItems
        model.corner = state.desktopCat.placement.corner
        model.frame.dark = dark
        model.frame.image = cache.image(cat: state.selectedCat, display: state.catDisplay(reducedMotion: false), frame: frame, dark: dark, scale: scale)
        return model
    }

    /// 把内容视图放在设计稿同款的渐变壁纸上渲染。
    public static func png(_ kind: Case, dark: Bool, cache: DesktopCatImage? = nil) -> Data? {
        let cache = cache ?? DesktopCatImage()
        let state = state(kind)
        let model = model(state: state, cache: cache, dark: dark)
        let size = model.layout.windowSize
        let wall = dark
            ? [Color(red: 0x1c / 255, green: 0x2a / 255, blue: 0x44 / 255), Color(red: 0x3a / 255, green: 0x2d / 255, blue: 0x4d / 255), Color(red: 0x5a / 255, green: 0x3b / 255, blue: 0x2c / 255)]
            : [Color(red: 0x9f / 255, green: 0xc3 / 255, blue: 0xe6 / 255), Color(red: 0xd6 / 255, green: 0xc6 / 255, blue: 0xe6 / 255), Color(red: 0xf3 / 255, green: 0xc9 / 255, blue: 0xa8 / 255)]
        let app = NSApplication.shared
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let previous = app.appearance
        app.appearance = appearance
        defer { app.appearance = previous }
        var result: Data?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: DesktopCatContentView(model: model)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.previewMaterial, true)
                .background(LinearGradient(colors: wall, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size.width, height: size.height))
            renderer.proposedSize = ProposedViewSize(size)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                result = rep.representation(using: .png, properties: [:])
            }
        }
        return result
    }
}
