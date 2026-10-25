import AppKit
import SwiftUI
import MeowMacCore

/// 桌面猫的合成预览：真实的内容视图和猫图缓存，数据全部虚构。玻璃用设计稿的半透明底色代替，不作材质验收。
@MainActor
public enum DesktopCatPreview {
    public enum Case: String, CaseIterable {
        case normal, alert, severe, missing, single, longSpeed, leftCorner
        /// D47：8 项、6 项、左上角 8 项。
        case eight, six, topLeftEight
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
            case .eight: return "8 项"
            case .six: return "6 项"
            case .topLeftEight: return "左上角 8 项"
            }
        }
    }

    /// 设计稿「8 项」的顺序：CPU、内存、功耗、磁盘、Claude、Codex、花费、网络。
    public static let eightMetrics = ["system.cpu", "system.memory", "system.power", "system.disk",
                                      "quota.claude.minutes:300", "quota.codex.minutes:300", "quota.cost.today", "network.speed"]

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
        case .eight, .topLeftEight:
            metrics = Self.eightMetrics
            state.catLevelOverride = .normal
        case .six:
            metrics = ["system.cpu", "system.memory", "system.power", "system.disk", "quota.claude.minutes:300", "network.speed"]
            state.catLevelOverride = .normal
        }
        let corner: DesktopCatCorner = kind == .leftCorner ? .bottomLeft : kind == .topLeftEight ? .topLeft : .bottomRight
        state.desktopCat = DesktopCatConfig(enabled: true, metrics: metrics, placement: DesktopCatPlacement(corner: corner))
        return state
    }

    /// 与窗口相同的视图模型路径：目录取值、猫图缓存和内容视图。
    public static func model(state: PanelState, cache: DesktopCatImage, dark: Bool, frame: Int = 2, scale: CGFloat = 2) -> DesktopCatViewModel {
        let model = DesktopCatViewModel()
        model.items = state.desktopCatItems
        model.corner = state.desktopCat.placement.corner
        model.catHeight = DesktopCatSize.rendered(state.desktopCat.catHeight)
        model.frame.dark = dark
        let display = state.catDisplay(reducedMotion: false)
        let size = model.layout.catSize
        model.frame.image = cache.image(cat: state.selectedCat, display: display, frame: frame, dark: dark, scale: scale, size: size)
        model.frame.shadow = cache.shadow(pet: nil, size: size)
        model.catTrim = cache.leadingTrim(cat: state.selectedCat, display: display, dark: dark, scale: scale, size: size)
        return model
    }

    /// 设计稿「更多指标与猫的大小（D47）」的大小预览：36、52 pt 配 4 项，104 pt 配 2 项（CPU、Claude）。
    public static let previewHeights: [CGFloat] = [36, 52, 104]
    public static func sizePNG(height: CGFloat, handle: Bool, dark: Bool, cache: DesktopCatImage? = nil) -> Data? {
        let cache = cache ?? DesktopCatImage()
        let state = state(.normal)
        let metrics = height >= 104 ? ["system.cpu", "quota.claude.minutes:300"] : DesktopCatConfig.defaultMetrics
        state.desktopCat = DesktopCatConfig(enabled: true, metrics: metrics, catHeight: Double(height))
        let model = model(state: state, cache: cache, dark: dark)
        model.handleVisible = handle
        return render(dark: dark, size: model.layout.windowSize) { DesktopCatContentView(model: model) }
    }

    /// 拖动态：一块 720 × 420 pt 的虚构屏幕，猫拎在右下区域，四角落点框中右下高亮（plan D14）。
    public static func dragPNG(dark: Bool, cache: DesktopCatImage? = nil) -> Data? {
        let cache = cache ?? DesktopCatImage()
        let state = state(.normal)
        let model = model(state: state, cache: cache, dark: dark, frame: 0)
        model.dragging = true
        let visible = CGRect(x: 0, y: 0, width: 720, height: 420)
        let screen = DesktopCatScreen(id: "preview", visibleFrame: visible, isMain: true)
        let window = CGRect(origin: CGPoint(x: 400, y: 70), size: model.layout.windowSize)
        guard let result = DesktopCatGeometry.dropTargets(windowFrame: window, count: model.items.count, catTrim: model.catTrim, screens: [screen]) else { return nil }
        let drop = DesktopCatDropModel()
        drop.update(result.targets, visibleFrame: visible)
        return render(dark: dark, size: visible.size) {
            ZStack(alignment: .topLeading) {
                DesktopCatDropTargetsView(model: drop)
                DesktopCatContentView(model: model).offset(x: window.minX, y: visible.maxY - window.maxY)
            }
        }
    }

    /// 把内容视图放在设计稿同款的渐变壁纸上渲染。
    public static func png(_ kind: Case, dark: Bool, cache: DesktopCatImage? = nil) -> Data? {
        let cache = cache ?? DesktopCatImage()
        let state = state(kind)
        let model = model(state: state, cache: cache, dark: dark)
        return render(dark: dark, size: model.layout.windowSize) { DesktopCatContentView(model: model) }
    }

    private static func render<Content: View>(dark: Bool, size: CGSize, @ViewBuilder content: () -> Content) -> Data? {
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
            let renderer = ImageRenderer(content: content()
                .frame(width: size.width, height: size.height, alignment: .topLeading)
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
