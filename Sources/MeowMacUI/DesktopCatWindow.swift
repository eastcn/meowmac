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
    /// 结束提示实际更新的次数，供测试断言（没选“AI 会话”时提示列表变化不触发渲染）。
    public private(set) var toastUpdates = 0
    public private(set) var lastFrame: Int?
    /// 上一次画的是哪只宠物，nil 表示猫。
    private var drawnPet: ObjectIdentifier?
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
    /// 拖把手缩放：按下时的鼠标位置和猫的高度（plan D15）。
    private var resize: (start: CGPoint, height: CGFloat)?
    /// 按在结束提示上：松手时关掉这一条，不拖动，不开面板（plan D3）。
    private var pressedToast: String?
    /// 鼠标离开猫和把手后 0.3 秒隐藏把手。一次性的延迟任务，不是计时器；回到猫身上即取消。
    private var handleHide: DispatchWorkItem?
    public static let handleHideDelay: TimeInterval = 0.3
    /// 鼠标离开后 0.3 秒回到设定的不透明度（D48）。同样是一次性的延迟任务；回来即取消。
    private var solidFade: DispatchWorkItem?
    private var solidFadeToken = 0
    public static let solidFadeDelay: TimeInterval = 0.3
    /// 延迟任务的投递方式，测试换成手动执行，不用真实等待。
    public var scheduleAfter: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// 上一次变实或回落是否带过渡，供测试断言“减少动态效果”时直接切换。
    public private(set) var solidAnimated = false
    /// 右键菜单开着：保持变实。
    private var menuOpen = false
    /// 已装的鼠标监视器数，供测试断言透明度没有新增监视器或计时器。
    public var monitorCount: Int { monitors.count }
    /// 当前是否换成了缩放光标。
    private var resizeCursorShown = false
    /// 正在拖把手缩放。
    public var isResizing: Bool { resize != nil }
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
        state.syncPets()
        guard state.desktopCat.enabled else { hide(); return }
        show()
        // 换宠物或换回猫时立即重画，不等下一帧。
        if drawnPet != state.desktopPet.map(ObjectIdentifier.init) { updateFrame(lastFrame ?? 0, display: state.catDisplay()) }
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
        drag = nil; model.dragging = false; mask = nil; pressedToast = nil
        if !model.toasts.isEmpty { model.toasts = [] }
        resize = nil; handleHide?.cancel(); handleHide = nil; model.handleVisible = false
        solidFade?.cancel(); solidFade = nil; menuOpen = false; model.solid = false
        if resizeCursorShown { NSCursor.arrow.set(); resizeCursorShown = false }
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
        // 拖把手时以拖动中的高度为准，松手写入配置后再跟随配置。
        let height = DesktopCatSize.rendered(state.desktopCat.catHeight)
        let sized = resize == nil && height != model.catHeight
        // 只在选了“AI 会话”时显示结束提示（D46）。
        let toasts = AgentSessionCadence.wanted(state.desktopCat) ? state.agentSessionToasts : []
        let toastsChanged = toasts != model.toasts
        let resized = items.count != model.items.count || corner != model.corner || sized || toastsChanged
        if items != model.items { model.items = items; bubbleUpdates += 1 }
        if toastsChanged {
            model.toasts = toasts; toastUpdates += 1
            // 先让内容按新版式排好再改窗口大小，避免提示出现和消失时闪一帧。
            window?.contentView?.layoutSubtreeIfNeeded()
        }
        if corner != model.corner { model.corner = corner }
        if sized { model.catHeight = height }
        // 不透明度（D48）：设置里拖滑块时先用草稿，松手写入后跟随配置。坏值按 100%。
        let catOpacity = DesktopCatOpacity.rendered(state.desktopCatOpacityDraft[.cat] ?? state.desktopCat.catOpacity)
        let bubbleOpacity = DesktopCatOpacity.rendered(state.desktopCatOpacityDraft[.bubble] ?? state.desktopCat.bubbleOpacity)
        if catOpacity != model.catOpacity { model.catOpacity = catOpacity }
        if bubbleOpacity != model.bubbleOpacity { model.bubbleOpacity = bubbleOpacity }
        if resized { position(animated: false) }
        if sized, lastFrame != nil { updateFrame(lastFrame ?? 0, display: state.catDisplay()) }
    }

    /// 跟随应用唯一的帧计时器（与菜单栏同一帧号）。拖动时定格第 1 帧。
    public func updateFrame(_ frame: Int, display: CatDisplay) {
        guard let window else { return }
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let pet = state.desktopPet
        drawnPet = pet.map(ObjectIdentifier.init)
        let size = model.layout.catSize
        let image = images.image(cat: state.selectedCat, pet: pet, display: display, frame: drag?.moved == true ? 0 : frame, dark: dark,
                                 scale: window.backingScaleFactor, size: size)
        if model.frame.image !== image { model.frame.image = image }
        if model.frame.dark != dark { model.frame.dark = dark }
        let shadow = images.shadow(pet: pet, size: size)
        if model.frame.shadow != shadow { model.frame.shadow = shadow }
        let trim = images.leadingTrim(cat: state.selectedCat, pet: pet, display: display, dark: dark, scale: window.backingScaleFactor, size: size)
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
        let shape = hitShape(), point = localPoint(window)
        // 按在结束提示上：松手关掉这一条。
        if let index = shape.toast(at: point), index < model.toasts.count {
            pressedToast = model.toasts[index].id
            return
        }
        // 按在把手上：进入缩放，不移动猫，也不算单击（plan D15）。
        if shape.inHandle(point) {
            resize = (mouseLocation(), model.catHeight)
            setSolid(true)
            return
        }
        drag = (mouseLocation(), window.frame.origin, false)
        setSolid(true)
    }

    public func mouseDragged() {
        guard pressedToast == nil else { return }
        if let current = resize {
            let location = mouseLocation()
            let height = DesktopCatSize.dragged(from: current.height, delta: CGVector(dx: location.x - current.start.x, dy: location.y - current.start.y),
                                                corner: model.corner)
            guard height != model.catHeight else { return }
            // 实时变大小，锚点按角固定（D14）：窗口按新版式重新落位，猫图按新高度重画。
            model.catHeight = height
            position(animated: false)
            updateFrame(lastFrame ?? 0, display: state.catDisplay())
            return
        }
        guard let window, var current = drag else { return }
        let location = mouseLocation()
        if !current.moved && DesktopCatGeometry.isClick(from: current.start, to: location) { return }
        if !current.moved {
            current.moved = true; model.dragging = true; model.handleVisible = false
            handleHide?.cancel(); handleHide = nil
            updateFrame(0, display: state.catDisplay())
        }
        drag = current
        window.setFrameOrigin(CGPoint(x: current.origin.x + location.x - current.start.x, y: current.origin.y + location.y - current.start.y))
        showDropTargets(windowFrame: window.frame)
    }

    public func mouseUp() {
        if let pressed = pressedToast {
            pressedToast = nil
            // 松手时还在同一条提示上才关掉；不开面板。
            guard let window, let index = hitShape().toast(at: localPoint(window)), index < model.toasts.count,
                  model.toasts[index].id == pressed else { return }
            state.onDismissAgentSessionToast(model.toasts[index].ids)
            return
        }
        if resize != nil {
            resize = nil
            finishResize()
            updateMouseThrough()
            return
        }
        guard let window, let current = drag else { return }
        drag = nil
        // 松手后按鼠标位置决定是否回落（D48）。
        defer { updateMouseThrough() }
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

    /// 松手：高度变了才写一次配置；写入失败时回到配置里的大小。
    private func finishResize() {
        let height = model.catHeight
        guard Double(height) != state.desktopCat.catHeight else { return }
        if !state.updateDesktopCatHeight(Double(height)) {
            logger.error("桌面猫大小未保存：\(self.state.desktopCatError ?? "", privacy: .public)")
            refreshBubble()
        }
    }

    /// 拖动中：在窗口中心所在的屏幕显示四个落点，最近的高亮。只随拖动事件更新，不计时；减少动态效果时也显示。
    private func showDropTargets(windowFrame: CGRect) {
        guard let result = DesktopCatGeometry.dropTargets(windowFrame: windowFrame, count: model.items.count,
                                                          catTrim: model.catTrim, catHeight: model.catHeight, screens: screens()) else { hideDropTargets(); return }
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
        // 菜单开着时保持变实（plan D8）；`popUpContextMenu` 等菜单关闭才返回，之后按鼠标位置决定是否回落。
        menuOpen = true
        setSolid(true)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        menuOpen = false
        updateMouseThrough()
    }

    private func installMouseMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateMouseThrough() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.updateMouseThrough(); return event
        }) { monitors.append(local) }
    }

    /// 鼠标在猫的不透明像素、气泡或显示中的把手里时接收点击，其余时候穿过去（D11 的退路，不轮询）。
    /// 同时管把手：停在猫身上时显示，离开猫和把手 0.3 秒后隐藏；停在把手上时换成缩放光标。
    public func updateMouseThrough() {
        guard let window, drag == nil, resize == nil else { return }
        let point = localPoint(window)
        let shape = hitShape()
        let inside = shape.contains(point)
        if window.ignoresMouseEvents == inside { window.ignoresMouseEvents = !inside }
        let onHandle = shape.inHandle(point)
        updateHandle(hovering: onHandle || shape.inCat(point))
        updateSolid(hovering: inside || menuOpen)
        if onHandle != resizeCursorShown {
            (onHandle ? Self.resizeCursor(corner: model.corner) : NSCursor.arrow).set()
            resizeCursorShown = onHandle
        }
    }

    private func updateHandle(hovering: Bool) {
        if hovering {
            handleHide?.cancel(); handleHide = nil
            if !model.handleVisible { model.handleVisible = true }
            return
        }
        guard model.handleVisible, handleHide == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.handleHide = nil
            guard self.resize == nil else { return }
            self.model.handleVisible = false
            self.updateMouseThrough()
        }
        handleHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handleHideDelay, execute: work)
    }

    /// 鼠标在猫、气泡、提示或显示中的把手上时变实；离开 0.3 秒后回落，期间回来就取消（D48）。
    private func updateSolid(hovering: Bool) {
        if hovering { setSolid(true); return }
        guard model.solid, solidFade == nil else { return }
        solidFadeToken += 1
        let token = solidFadeToken
        let work = DispatchWorkItem { [weak self] in
            guard let self, token == self.solidFadeToken, self.solidFade != nil else { return }
            self.solidFade = nil
            guard self.drag == nil, self.resize == nil, !self.menuOpen else { return }
            self.setSolid(false)
        }
        solidFade = work
        scheduleAfter(Self.solidFadeDelay, work)
    }

    /// 变实或回落：0.15 秒 easeInOut，开启“减少动态效果”时直接切换。变实时取消待回落的任务。
    private func setSolid(_ value: Bool) {
        if value { solidFade?.cancel(); solidFade = nil; solidFadeToken += 1 }
        guard model.solid != value else { return }
        let animated = !reduceMotion()
        solidAnimated = animated
        withAnimation(animated ? .easeInOut(duration: 0.15) : nil) { model.solid = value }
    }

    /// 斜向缩放光标；系统没有时（macOS 14）用十字光标。
    static func resizeCursor(corner: DesktopCatCorner) -> NSCursor {
        if #available(macOS 15, *) {
            // 把手总在猫朝屏幕内侧的上角：右边的角在左上，左边的角在右上。双向箭头沿同一条对角线。
            return NSCursor.frameResize(position: corner.isLeft ? .topRight : .topLeft, directions: .all)
        }
        return .crosshair
    }

    /// 鼠标在窗口里的位置，原点在左上角，y 向下。
    private func localPoint(_ window: NSWindow) -> CGPoint {
        let local = window.convertPoint(fromScreen: mouseLocation())
        return CGPoint(x: local.x, y: window.frame.height - local.y)
    }

    private func isMouseInside(_ window: NSWindow) -> Bool {
        hitShape().contains(localPoint(window))
    }

    public func hitShape() -> DesktopCatHitShape {
        var catMask: DesktopCatAlphaMask?
        if let image = model.frame.image {
            let id = ObjectIdentifier(image)
            if let mask, mask.image == id { catMask = mask.mask }
            else { catMask = Self.alphaMask(image); mask = (id, catMask) }
        }
        return DesktopCatHitShape(layout: model.layout, catMask: catMask, handleVisible: model.handleVisible)
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
