import AppKit
import Combine
import CoreGraphics
import SwiftUI
import MeowMacCore
import os

/// 透明、置顶、不抢焦点的窗口（D3、D11）。
final class DesktopCatPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 承载内容视图并把鼠标交给控制器。拖动、单击和右键都在这里接收。
final class DesktopCatHostingView: NSHostingView<DesktopCatContentView> {
    weak var controller: DesktopCatController?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown() }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged() }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp() }
    override func rightMouseDown(with event: NSEvent) { controller?.showMenu(event: event, in: self) }
}

/// 桌面猫的窗口、拖动吸附、多屏与刷新（D45）。关闭时不建窗口、不订阅、不渲染（D10）。
@MainActor
public final class DesktopCatController {
    public let model = DesktopCatViewModel()
    public private(set) var window: NSPanel?
    /// 气泡数值实际更新的次数、猫图换帧的次数，供测试断言。
    public private(set) var bubbleUpdates = 0
    public private(set) var frameUpdates = 0
    public private(set) var lastFrame: Int?
    public let images = DesktopCatImage()
    public var onOpenPanel: () -> Void
    /// 右键菜单，由应用按目录生成。
    public var makeMenu: () -> NSMenu? = { nil }
    public var screens: () -> [DesktopCatScreen] = { DesktopCatController.systemScreens() }
    public var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    public var mouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// 测试关掉它：窗口照常建立和定位，但不放到屏幕上。
    public var ordersFront = true
    private let state: PanelState
    private var subscription: AnyCancellable?
    private var refreshPending = false
    private var observers: [NSObjectProtocol] = []
    private var monitors: [Any] = []
    private var drag: (start: CGPoint, origin: CGPoint, moved: Bool)?
    private var mask: (image: ObjectIdentifier, mask: DesktopCatAlphaMask?)?
    /// 拖动时的落点框窗口：透明、不接收鼠标，只在拖动中存在。
    public private(set) var dropWindow: NSPanel?
    public let dropModel = DesktopCatDropModel()
    /// 当前显示的落点（屏幕坐标），不在拖动时为空。供测试断言。
    public private(set) var dropTargets: [DesktopCatDropTarget] = []
    private let logger = Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "desktop-cat")

    public init(state: PanelState, onOpenPanel: @escaping () -> Void) {
        self.state = state; self.onOpenPanel = onOpenPanel
    }

    public var isShown: Bool { window != nil }

    /// 按当前配置显示或关闭。
    public func apply() {
        if state.desktopCat.enabled { show() } else { hide() }
    }

    func show() {
        model.corner = state.desktopCat.placement.corner
        if window == nil {
            let panel = DesktopCatPanel(contentRect: NSRect(origin: .zero, size: model.layout.windowSize),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovable = false
            panel.becomesKeyOnlyIfNeeded = true
            // 应用不在前台时也显示指标的悬停提示（plan D14：原生提示，系统默认延迟）。
            panel.allowsToolTipsWhenApplicationIsInactive = true
            // 透明处的点击穿过去；鼠标移到猫或气泡上时才接收（见 `updateMouseThrough`）。
            panel.ignoresMouseEvents = true
            let host = DesktopCatHostingView(rootView: DesktopCatContentView(model: model))
            host.controller = self
            panel.contentView = host
            window = panel
            subscription = state.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.position(animated: false) }
            })
            installMouseMonitors()
            refreshBubble()
            updateFrame(0, display: state.catDisplay())
        } else {
            refreshBubble()
        }
        position(animated: false)
        if ordersFront { window?.orderFrontRegardless() }
    }

    public func hide() {
        subscription = nil
        refreshPending = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors.removeAll()
        drag = nil; model.dragging = false; mask = nil
        hideDropTargets()
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
    }

    // MARK: - 刷新

    /// 面板状态的任何发布都只登记一次，等本轮主循环结束后统一取值；数值没变时不更新视图。
    private func scheduleRefresh() {
        guard window != nil, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refreshBubble()
        }
    }

    public func refreshBubble() {
        guard window != nil else { return }
        let items = state.desktopCatItems
        let corner = state.desktopCat.placement.corner
        let resized = items.count != model.items.count || corner != model.corner
        if items != model.items { model.items = items; bubbleUpdates += 1 }
        if corner != model.corner { model.corner = corner }
        if resized { position(animated: false) }
    }

    /// 跟随应用唯一的帧计时器（与菜单栏同一帧号）。拖动时定格第 1 帧。
    public func updateFrame(_ frame: Int, display: CatDisplay) {
        guard let window else { return }
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let image = images.image(cat: state.selectedCat, display: display, frame: drag?.moved == true ? 0 : frame, dark: dark,
                                 scale: window.backingScaleFactor)
        if model.frame.image !== image { model.frame.image = image }
        if model.frame.dark != dark { model.frame.dark = dark }
        let trim = images.leadingTrim(cat: state.selectedCat, display: display, dark: dark, scale: window.backingScaleFactor)
        if model.catTrim != trim {
            model.catTrim = trim
            if model.corner.isLeft { position(animated: false) }
        }
        lastFrame = frame
        frameUpdates += 1
    }

    // MARK: - 位置

    public static func systemScreens() -> [DesktopCatScreen] {
        NSScreen.screens.enumerated().map { index, screen in
            DesktopCatScreen(id: displayID(screen) ?? "screen-\(index)", visibleFrame: screen.visibleFrame, isMain: index == 0)
        }
    }

    /// `CGDisplayCreateUUIDFromDisplayID` 的 UUID，比显示器编号稳定（D8）。
    public static func displayID(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// 按已存的屏和角落位；找不到屏时放到主屏同一个角，不改写已存标识（D13）。
    public func targetFrame() -> CGRect? {
        guard let resolved = DesktopCatGeometry.resolve(state.desktopCat.placement, screens: screens()) else { return nil }
        return DesktopCatGeometry.windowFrame(layout: model.layout, corner: state.desktopCat.placement.corner,
                                              visibleFrame: resolved.screen.visibleFrame)
    }

    func position(animated: Bool) {
        guard let window, drag == nil, let frame = targetFrame() else { return }
        if animated && !reduceMotion() {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    // MARK: - 鼠标

    /// 按下时再判断一次命中：鼠标刚从猫移到透明处、mouseMoved 还没到时，不进入拖动或单击。
    public func mouseDown() {
        guard let window else { return }
        guard isMouseInside(window) else { window.ignoresMouseEvents = true; return }
        drag = (mouseLocation(), window.frame.origin, false)
    }

    public func mouseDragged() {
        guard let window, var current = drag else { return }
        let location = mouseLocation()
        if !current.moved && DesktopCatGeometry.isClick(from: current.start, to: location) { return }
        if !current.moved { current.moved = true; model.dragging = true; updateFrame(0, display: state.catDisplay()) }
        drag = current
        window.setFrameOrigin(CGPoint(x: current.origin.x + location.x - current.start.x, y: current.origin.y + location.y - current.start.y))
        showDropTargets(windowFrame: window.frame)
    }

    public func mouseUp() {
        guard let window, let current = drag else { return }
        drag = nil
        guard current.moved || !DesktopCatGeometry.isClick(from: current.start, to: mouseLocation()) else {
            onOpenPanel(); return
        }
        model.dragging = false
        hideDropTargets()
        guard let drop = DesktopCatGeometry.drop(windowFrame: window.frame, screens: screens()) else { position(animated: false); return }
        let placement = DesktopCatPlacement(display: drop.screen.id, corner: drop.corner)
        if !state.updateDesktopCat({ $0.with(placement: placement) }) {
            logger.error("桌面猫位置未保存：\(self.state.desktopCatError ?? "", privacy: .public)")
        }
        model.corner = state.desktopCat.placement.corner
        position(animated: true)
    }

    /// 拖动中：在窗口中心所在的屏幕显示四个落点，最近的高亮。只随拖动事件更新，不计时；减少动态效果时也显示。
    private func showDropTargets(windowFrame: CGRect) {
        guard let result = DesktopCatGeometry.dropTargets(windowFrame: windowFrame, count: model.items.count,
                                                          catTrim: model.catTrim, screens: screens()) else { hideDropTargets(); return }
        dropTargets = result.targets
        dropModel.update(result.targets, visibleFrame: result.screen.visibleFrame)
        let overlay = dropWindow ?? makeDropWindow()
        if overlay.frame != result.screen.visibleFrame { overlay.setFrame(result.screen.visibleFrame, display: true) }
        if ordersFront, let window, !overlay.isVisible { overlay.order(.below, relativeTo: window.windowNumber) }
    }

    private func makeDropWindow() -> NSPanel {
        let panel = DesktopCatPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: DesktopCatDropTargetsView(model: dropModel))
        dropWindow = panel
        return panel
    }

    /// 松手或关闭时立即移除落点框。
    private func hideDropTargets() {
        dropTargets = []
        dropModel.targets = []
        dropWindow?.orderOut(nil)
        dropWindow?.contentView = nil
        dropWindow?.close()
        dropWindow = nil
    }

    func showMenu(event: NSEvent, in view: NSView) {
        guard let menu = makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func installMouseMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMouseThrough() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.updateMouseThrough(); return event
        }) { monitors.append(local) }
    }

    /// 鼠标在猫的不透明像素或气泡里时接收点击，其余时候穿过去（D11 的退路，不轮询）。
    public func updateMouseThrough() {
        guard let window, drag == nil else { return }
        let inside = isMouseInside(window)
        if window.ignoresMouseEvents == inside { window.ignoresMouseEvents = !inside }
    }

    private func isMouseInside(_ window: NSWindow) -> Bool {
        let local = window.convertPoint(fromScreen: mouseLocation())
        return hitShape().contains(CGPoint(x: local.x, y: window.frame.height - local.y))
    }

    public func hitShape() -> DesktopCatHitShape {
        var catMask: DesktopCatAlphaMask?
        if let image = model.frame.image {
            let id = ObjectIdentifier(image)
            if let mask, mask.image == id { catMask = mask.mask }
            else { catMask = Self.alphaMask(image); mask = (id, catMask) }
        }
        return DesktopCatHitShape(layout: model.layout, catMask: catMask)
    }

    static func alphaMask(_ image: NSImage) -> DesktopCatAlphaMask? {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first, let data = rep.bitmapData,
              rep.bitsPerPixel == 32, rep.samplesPerPixel == 4 else { return nil }
        var alpha = [UInt8](repeating: 0, count: rep.pixelsWide * rep.pixelsHigh)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide { alpha[y * rep.pixelsWide + x] = data[y * rep.bytesPerRow + x * 4 + 3] }
        }
        return DesktopCatAlphaMask(width: rep.pixelsWide, height: rep.pixelsHigh, alpha: alpha)
    }
}
