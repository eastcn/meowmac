import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

/// 透明窗口、拖动吸附与多屏（plan 条目 2），以及刷新与渲染计数（条目 3 的离线用例）。
@MainActor
enum DesktopCatWindowTests {
    static var tests: [(String, @MainActor () async -> Bool)] {
        [
            ("Core.DesktopCat/最近角与落位边距", { nearestCorner() }),
            ("Core.DesktopCat/4 pt 单击阈值", { clickThreshold() }),
            ("Core.DesktopCat/指标数变化时角固定", { cornerFixed() }),
            ("Core.DesktopCat/找不到屏时落主屏且接回回原屏", { missingScreen() }),
            ("Core.DesktopCat/点击判断猫像素气泡与尾巴", { hitTest() }),
            ("UI.DesktopCat/关闭时不建窗口不刷新", { await disabled() }),
            ("UI.DesktopCat/窗口属性与右下角落位", { await window() }),
            ("UI.DesktopCat/帧号与菜单栏一致且不重复光栅化", { await frameSync() }),
            ("UI.DesktopCat/拖动吸附存新屏与单击开面板", { await dragAndClick() }),
            ("UI.DesktopCat/按下点不在猫和气泡上时不拖不开面板", { await missedPress() }),
            ("UI.DesktopCatWindow/真实屏幕窗口属性与右下角", { await foregroundWindow() }),
        ]
    }

    // 主屏 1512×982，菜单栏 33 pt、程序坞在底部 70 pt；副屏在右侧，菜单栏 24 pt、没有程序坞。
    static let main = DesktopCatScreen(id: "00000000-0000-0000-0000-0000000000A1", visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879), isMain: true)
    static let side = DesktopCatScreen(id: "00000000-0000-0000-0000-0000000000B2", visibleFrame: CGRect(x: 1512, y: -200, width: 1920, height: 1056), isMain: false)

    static func content(_ frame: CGRect) -> CGRect { frame.insetBy(dx: DesktopCatLayout.inset, dy: DesktopCatLayout.inset) }

    static func nearestCorner() -> Bool {
        let layout = DesktopCatLayout(count: 4, corner: .bottomRight)
        for screen in [main, side] {
            let visible = screen.visibleFrame
            for corner in DesktopCatCorner.allCases {
                let frame = DesktopCatGeometry.windowFrame(layout: DesktopCatLayout(count: 4, corner: corner), corner: corner, visibleFrame: visible)
                let c = content(frame)
                let sideOK = corner.isLeft ? c.minX == visible.minX + 16 : c.maxX == visible.maxX - 16
                let verticalOK = corner.isTop ? c.maxY == visible.maxY - 8 : c.minY == visible.minY + 8
                guard sideOK, verticalOK, frame.size == layout.windowSize,
                      DesktopCatGeometry.nearestCorner(windowFrame: frame, visibleFrame: visible) == corner else { return false }
            }
        }
        // 屏幕中线附近：差 1 pt 也按所在一侧；正好在中线上取右、下。
        let v = main.visibleFrame
        func at(_ x: CGFloat, _ y: CGFloat) -> DesktopCatCorner {
            DesktopCatGeometry.nearestCorner(windowFrame: CGRect(x: x - 50, y: y - 50, width: 100, height: 100), visibleFrame: v)
        }
        guard at(v.midX - 1, v.midY + 1) == .topLeft, at(v.midX + 1, v.midY + 1) == .topRight,
              at(v.midX - 1, v.midY - 1) == .bottomLeft, at(v.midX, v.midY) == .bottomRight else { return false }
        // 多屏：中心落在副屏左上区域。
        guard let drop = DesktopCatGeometry.drop(windowFrame: CGRect(x: 1700, y: 600, width: 198, height: 187), screens: [main, side]),
              drop.screen == side, drop.corner == .topLeft else { return false }
        // 中心落在所有可见区域外（例如副屏下方空白）时取最近的屏。
        guard let outside = DesktopCatGeometry.drop(windowFrame: CGRect(x: 600, y: -300, width: 198, height: 187), screens: [main, side]),
              outside.screen == main, outside.corner == .bottomLeft else { return false }
        return true
    }

    static func clickThreshold() -> Bool {
        let start = CGPoint(x: 100, y: 100)
        return DesktopCatGeometry.isClick(from: start, to: start)
            && DesktopCatGeometry.isClick(from: start, to: CGPoint(x: 103.9, y: 100))
            && DesktopCatGeometry.isClick(from: start, to: CGPoint(x: 102, y: 102))
            && !DesktopCatGeometry.isClick(from: start, to: CGPoint(x: 104, y: 100))
            && !DesktopCatGeometry.isClick(from: start, to: CGPoint(x: 103, y: 103))
    }

    static func cornerFixed() -> Bool {
        let visible = main.visibleFrame
        for corner in DesktopCatCorner.allCases {
            let frames = (1...4).map { content(DesktopCatGeometry.windowFrame(layout: DesktopCatLayout(count: $0, corner: corner), corner: corner, visibleFrame: visible)) }
            let anchors = frames.map { CGPoint(x: corner.isLeft ? $0.minX : $0.maxX, y: corner.isTop ? $0.maxY : $0.minY) }
            guard Set(anchors.map { "\($0.x),\($0.y)" }).count == 1 else { return false }
        }
        return true
    }

    static func missingScreen() -> Bool {
        let placement = DesktopCatPlacement(display: side.id, corner: .topLeft)
        guard let away = DesktopCatGeometry.resolve(placement, screens: [main]), away.screen == main, away.fallback,
              let back = DesktopCatGeometry.resolve(placement, screens: [main, side]), back.screen == side, !back.fallback,
              let primary = DesktopCatGeometry.resolve(DesktopCatPlacement(), screens: [side, main]), primary.screen == main,
              DesktopCatGeometry.resolve(placement, screens: []) == nil else { return false }
        // 控制器：屏幕不在时落到主屏同一个角，配置里的标识不变；接回后回到原屏。
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let state = PanelPreviewRenderer.syntheticState()
        state.desktopCatConfigURL = url
        guard state.updateDesktopCat({ $0.with(enabled: true).with(placement: placement) }) else { return false }
        let controller = DesktopCatController(state: state, onOpenPanel: {})
        controller.ordersFront = false
        var screens = [main]
        controller.screens = { screens }
        controller.apply(); defer { controller.hide() }
        guard let window = controller.window, content(window.frame).minX == main.visibleFrame.minX + 16,
              content(window.frame).maxY == main.visibleFrame.maxY - 8,
              ConfigStore.load(from: url).config.desktopCat.placement == placement else { return false }
        screens = [main, side]
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let expected = controller.targetFrame(), content(expected).minX == side.visibleFrame.minX + 16 else { return false }
        return true
    }

    static func hitTest() -> Bool {
        let layout = DesktopCatLayout(count: 4, corner: .bottomRight)
        let cat = layout.catRect
        // 掩码：右半边不透明，左半边透明。
        var alpha = [UInt8](repeating: 0, count: 20 * 10)
        for y in 0..<10 { for x in 10..<20 { alpha[y * 20 + x] = 255 } }
        let shape = DesktopCatHitShape(layout: layout, catMask: DesktopCatAlphaMask(width: 20, height: 10, alpha: alpha))
        let bubble = layout.bubbleRect
        let tail = layout.tail
        guard shape.contains(CGPoint(x: cat.maxX - 10, y: cat.midY)),           // 猫不透明像素
              !shape.contains(CGPoint(x: cat.minX + 10, y: cat.midY)),          // 猫透明像素
              shape.contains(CGPoint(x: bubble.midX, y: bubble.midY)),          // 气泡内
              shape.contains(CGPoint(x: bubble.minX + 1, y: bubble.midY)),      // 气泡左边缘
              !shape.contains(CGPoint(x: bubble.minX + 1, y: bubble.minY + 1)), // 气泡圆角外
              shape.contains(CGPoint(x: bubble.minX + 14, y: bubble.minY + 1)),
              shape.contains(CGPoint(x: tail[2].x, y: tail[2].y - 1)),          // 尾巴
              !shape.contains(CGPoint(x: tail[0].x - 1, y: tail[2].y - 1)),     // 尾巴旁边
              !shape.contains(CGPoint(x: 2, y: 2)),                             // 透明边距
              !shape.contains(CGPoint(x: cat.midX, y: cat.maxY + 4)) else { return false }   // 投影
        // 没有掩码时按猫的外接区域。
        let box = DesktopCatHitShape(layout: layout, catMask: nil)
        return box.contains(CGPoint(x: cat.minX + 2, y: cat.midY)) && !box.contains(CGPoint(x: cat.minX - 2, y: cat.midY))
    }

    static func controller(enabled: Bool) -> (PanelState, DesktopCatController, URL) {
        let url = DesktopCatConfigTests.temporaryURL()
        let state = PanelPreviewRenderer.syntheticState()
        state.desktopCatConfigURL = url
        if enabled { _ = state.updateDesktopCat { $0.with(enabled: true) } }
        let controller = DesktopCatController(state: state, onOpenPanel: {})
        controller.ordersFront = false
        controller.screens = { [main, side] }
        controller.reduceMotion = { true }
        return (state, controller, url)
    }

    static func touch(_ state: PanelState, cpu: Double) {
        guard let base = state.snapshot else { return }
        state.snapshot = SystemSnapshot(timestamp: base.timestamp.addingTimeInterval(2), cpuUsage: cpu, memoryPressure: base.memoryPressure,
            swapUsedBytes: base.swapUsedBytes, diskAvailableBytes: base.diskAvailableBytes, diskTotalBytes: base.diskTotalBytes,
            networkReceivedBytesPerSecond: base.networkReceivedBytesPerSecond, networkSentBytesPerSecond: base.networkSentBytesPerSecond,
            battery: base.battery, thermal: base.thermal, memoryUsedBytes: base.memoryUsedBytes, memoryTotalBytes: base.memoryTotalBytes,
            memoryPressurePercent: base.memoryPressurePercent, sensors: base.sensors)
    }

    static func disabled() async -> Bool {
        let (state, controller, url) = controller(enabled: false); defer { try? FileManager.default.removeItem(at: url) }
        controller.apply()
        for cpu in [0.3, 0.5, 0.7] { touch(state, cpu: cpu); try? await Task.sleep(nanoseconds: 20_000_000) }
        controller.updateFrame(1, display: state.catDisplay())
        guard controller.window == nil, controller.bubbleUpdates == 0, controller.frameUpdates == 0,
              controller.images.rasterizations == 0, controller.model.items.isEmpty else { return false }
        // 打开再关闭：关闭后的更新不再触发。
        guard state.updateDesktopCat({ $0.with(enabled: true) }) else { return false }
        controller.apply()
        let opened = controller.bubbleUpdates
        guard controller.window != nil, opened == 1 else { return false }
        guard state.updateDesktopCat({ $0.with(enabled: false) }) else { return false }
        controller.apply()
        touch(state, cpu: 0.9); try? await Task.sleep(nanoseconds: 30_000_000)
        controller.updateFrame(2, display: state.catDisplay())
        return controller.window == nil && controller.bubbleUpdates == opened && controller.frameUpdates == 1
    }

    static func window() async -> Bool {
        let (state, controller, url) = controller(enabled: true); defer { try? FileManager.default.removeItem(at: url) }
        controller.apply(); defer { controller.hide() }
        guard let window = controller.window, !window.isVisible, window.level == .floating,
              window.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]),
              !window.isOpaque, !window.hasShadow, !window.canBecomeKey, !window.canBecomeMain, !window.hidesOnDeactivate,
              window.styleMask.contains(.nonactivatingPanel), window.backgroundColor == .clear, window.ignoresMouseEvents else { return false }
        let c = content(window.frame)
        guard c.maxX == main.visibleFrame.maxX - 16, c.minY == main.visibleFrame.minY + 8,
              controller.model.items.map(\.id) == DesktopCatConfig.defaultMetrics else { return false }
        // 快照变化后只更新一次；数值没变不更新。
        let before = controller.bubbleUpdates
        touch(state, cpu: 0.61); touch(state, cpu: 0.62)
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard controller.bubbleUpdates == before + 1, controller.model.items.first?.value == "62%" else { return false }
        state.chartHoverDate = Date()
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard controller.bubbleUpdates == before + 1 else { return false }
        // 减到 1 项：窗口变小，右下角不动。
        guard state.updateDesktopCat({ try $0.removing("system.memory").removing("network.speed").removing("quota.claude.minutes:300") }) else { return false }
        controller.apply()
        let small = content(window.frame)
        return small.maxX == c.maxX && small.minY == c.minY && small.width == 120 && controller.model.items.count == 1
    }

    static func frameSync() async -> Bool {
        let (state, controller, url) = controller(enabled: true); defer { try? FileManager.default.removeItem(at: url) }
        controller.apply(); defer { controller.hide() }
        let menuBar = MenuBarCatImage()
        var menuFrames: [Int] = []
        var cadence: ApplicationCadence!
        cadence = ApplicationCadence(display: { state.catDisplay(reducedMotion: false) }, updateImage: { frame in
            menuFrames.append(frame)
            _ = menuBar.image(cat: state.selectedCat, display: state.catDisplay(reducedMotion: false), frame: frame, appearance: NSAppearance(named: .aqua)!, scale: 2)
            controller.updateFrame(frame, display: state.catDisplay(reducedMotion: false))
        }, sample: {})
        cadence.frameInterval = 0.02
        cadence.scheduleFrame()
        try? await Task.sleep(nanoseconds: 300_000_000)
        cadence.stop()
        guard menuFrames.count >= 5, controller.lastFrame == cadence.frame, controller.lastFrame == menuFrames.last else { return false }
        // 5 帧循环：光栅化次数不超过帧图种类（第 1 次显示 + 5 帧）。
        let rasterized = controller.images.rasterizations
        guard rasterized <= 6, rasterized < controller.frameUpdates else { return false }
        for frame in 0..<10 { controller.updateFrame(frame, display: state.catDisplay(reducedMotion: false)) }
        return controller.images.rasterizations == rasterized
    }

    static func dragAndClick() async -> Bool {
        let (state, controller, url) = controller(enabled: true); defer { try? FileManager.default.removeItem(at: url) }
        var opened = 0
        controller.onOpenPanel = { opened += 1 }
        var mouse = CGPoint(x: 1400, y: 150)
        controller.mouseLocation = { mouse }
        controller.apply(); defer { controller.hide() }
        guard let window = controller.window else { return false }
        let home = window.frame
        // 移动 3 pt 松手：单击，打开面板，不移动不保存。
        controller.mouseDown(); mouse.x += 3; controller.mouseDragged(); controller.mouseUp()
        guard opened == 1, window.frame == home, !controller.model.dragging,
              ConfigStore.load(from: url).config.desktopCat.placement == DesktopCatPlacement() else { return false }
        // 拖到副屏左上区域：拖动中定格第 1 帧并放大，松手存新屏和角。
        controller.mouseDown()
        mouse = CGPoint(x: 1800, y: 700); controller.mouseDragged()
        guard controller.model.dragging, window.frame.origin != home.origin else { return false }
        controller.mouseUp()
        let saved = ConfigStore.load(from: url).config.desktopCat.placement
        guard opened == 1, !controller.model.dragging, saved == DesktopCatPlacement(display: side.id, corner: .topLeft),
              state.desktopCat.placement == saved, controller.model.corner == .topLeft else { return false }
        let c = content(window.frame)
        return c.minX == side.visibleFrame.minX + 16 && c.maxY == side.visibleFrame.maxY - 8
    }

    static func missedPress() async -> Bool {
        let (_, controller, url) = controller(enabled: true); defer { try? FileManager.default.removeItem(at: url) }
        var opened = 0
        controller.onOpenPanel = { opened += 1 }
        controller.apply(); defer { controller.hide() }
        guard let window = controller.window else { return false }
        let home = window.frame
        // 窗口左下角的透明边距：鼠标在窗口里，但不在猫或气泡上。
        var mouse = CGPoint(x: home.minX + 3, y: home.minY + 3)
        controller.mouseLocation = { mouse }
        window.ignoresMouseEvents = false
        controller.mouseDown(); controller.mouseUp()
        guard opened == 0, window.ignoresMouseEvents else { return false }
        controller.mouseDown(); mouse.x += 200; controller.mouseDragged(); controller.mouseUp()
        guard opened == 0, !controller.model.dragging, window.frame == home else { return false }
        // 气泡中间：照常单击打开面板。
        let bubble = controller.model.layout.bubbleRect
        mouse = CGPoint(x: home.minX + bubble.midX, y: home.maxY - bubble.midY)
        controller.mouseDown(); controller.mouseUp()
        return opened == 1
    }

    /// 前台用例（第 2 轮 `MEOWMAC_UI_TESTS=1` 运行）：真实屏幕上的窗口属性和落位。
    static func foregroundWindow() async -> Bool {
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let state = PanelPreviewRenderer.syntheticState()
        state.desktopCatConfigURL = url
        guard state.updateDesktopCat({ $0.with(enabled: true) }) else { return false }
        let controller = DesktopCatController(state: state, onOpenPanel: {})
        controller.apply(); defer { controller.hide() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let window = controller.window, window.isVisible, let screen = NSScreen.screens.first,
              window.level == .floating, window.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]),
              !window.isOpaque, !window.hasShadow, !window.canBecomeKey, !window.canBecomeMain, !window.isKeyWindow else { return false }
        let c = content(window.frame), visible = screen.visibleFrame
        print("桌面猫真实窗口：内容右边距 \(visible.maxX - c.maxX)，下边距 \(c.minY - visible.minY)")
        return abs(c.maxX - (visible.maxX - 16)) < 0.5 && abs(c.minY - (visible.minY + 8)) < 0.5 && !NSApp.isActive
    }
}
