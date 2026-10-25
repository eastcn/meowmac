import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

/// 桌面猫的大小（D47，plan 条目 2：D14～D16）。夹具全部虚构。
@MainActor
enum DesktopCatSizeTests {
    static var tests: [(String, @MainActor () async -> Bool)] {
        [
            ("Core.DesktopCatSize/配置缺省、边界与坏值按 52 运行", { config() }),
            ("Core.DesktopCatSize/只写 catHeight，其他字段不变", { saveOnlyHeight() }),
            ("Core.DesktopCatSize/吸附、夹取与拖动换算", { snapping() }),
            ("Core.DesktopCatSize/三种高度四个角的锚点与可见区域", { anchors() }),
            ("Core.DesktopCatSize/把手命中", { handleHit() }),
            ("UI.DesktopCatSize/拖把手缩放不移动不开面板，松手只写一次", { await dragHandle() }),
            ("UI.DesktopCatSize/悬停出把手，离开 0.3 秒后隐藏", { await hover() }),
            ("UI.DesktopCatSize/设置里的大小滑块与恢复默认", { settings() }),
        ]
    }

    // MARK: - 配置

    static func config() -> Bool {
        let base = #"{"schemaVersion":1,"quotaRemainingWarn":0.15,"#
        let cases: [(String, Double, Bool)] = [
            (#""desktopCat":{"enabled":true}}"#, 52, false),
            (#""desktopCat":{"enabled":true,"catHeight":36}}"#, 36, false),
            (#""desktopCat":{"enabled":true,"catHeight":104}}"#, 104, false),
            (#""desktopCat":{"enabled":true,"catHeight":80.5}}"#, 80.5, false),
            (#""desktopCat":{"enabled":true,"catHeight":35}}"#, 52, true),
            (#""desktopCat":{"enabled":true,"catHeight":105}}"#, 52, true),
            (#""desktopCat":{"enabled":true,"catHeight":"80"}}"#, 52, true),
            (#""desktopCat":{"enabled":true,"catHeight":-60}}"#, 52, true),
            (#""desktopCat":{"enabled":true,"catHeight":null}}"#, 52, true),
        ]
        for (index, (suffix, expected, noted)) in cases.enumerated() {
            // 读取不改写文件（`DesktopCatConfigTests.load` 断言字节不变）；大小坏了不影响其他字段。
            let ok = DesktopCatConfigTests.load(base + suffix) { config, _, _ in
                config.catHeight == expected && config.enabled && config.metrics == DesktopCatConfig.defaultMetrics
                    && config.diagnostics.contains("桌面猫的大小无效，已按 52 pt 显示") == noted && config.diagnostics.count == (noted ? 1 : 0)
            }
            guard ok else { print("桌面猫大小配置第 \(index + 1) 例未通过"); return false }
        }
        guard DesktopCatConfig().catHeight == 52, (try? DesktopCatConfig().with(catHeight: 30).validated()) == nil,
              (try? DesktopCatConfig().with(catHeight: .nan).validated()) == nil,
              (try? DesktopCatConfig().with(catHeight: 104).validated()) != nil else { return false }
        // 渲染：坏值按 52，好值取整到点。
        return DesktopCatSize.rendered(80.4) == 80 && DesktopCatSize.rendered(300) == 52 && DesktopCatSize.rendered(.infinity) == 52
    }

    static func saveOnlyHeight() -> Bool {
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let original = #"{"schemaVersion":1,"quotaRemainingWarn":0.15,"futureField":{"nested":[1,"示例"]},"desktopCat":{"enabled":true,"metrics":["example.future","system.cpu"],"placement":{"corner":"topLeft","display":"00000000-0000-0000-0000-00000000D004"},"pet":"example-pet","futureKey":"保留"}}"#
        do {
            try Data(original.utf8).write(to: url)
            guard var before = DesktopCatConfigTests.json(url), var beforeCat = before.removeValue(forKey: "desktopCat") as? [String: Any] else { return false }
            let loaded = ConfigStore.load(from: url).config.desktopCat
            try ConfigStore.saveDesktopCatHeight(80, fallback: loaded, to: url)
            guard var after = DesktopCatConfigTests.json(url), var afterCat = after.removeValue(forKey: "desktopCat") as? [String: Any],
                  afterCat.removeValue(forKey: "catHeight") as? Double == 80 else { return false }
            beforeCat.removeValue(forKey: "catHeight")
            // 其他顶层字段、desktopCat 的其他字段（含未知 id 和未知字段）都不变。
            guard NSDictionary(dictionary: before).isEqual(to: after), NSDictionary(dictionary: beforeCat).isEqual(to: afterCat),
                  ConfigStore.load(from: url).config.desktopCat.catHeight == 80 else { return false }
            // 越界拒绝，文件不变。
            let bytes = try Data(contentsOf: url)
            guard (try? ConfigStore.saveDesktopCatHeight(30, fallback: loaded, to: url)) == nil,
                  (try? ConfigStore.saveDesktopCatHeight(105, fallback: loaded, to: url)) == nil,
                  (try? Data(contentsOf: url)) == bytes else { return false }
            // desktopCat 整组无效（按默认值运行）时，整组写入界面正在用的配置。
            try Data(#"{"schemaVersion":1,"desktopCat":"yes"}"#.utf8).write(to: url)
            let fallback = ConfigStore.load(from: url).config.desktopCat
            try ConfigStore.saveDesktopCatHeight(40, fallback: fallback, to: url)
            let repaired = ConfigStore.load(from: url).config.desktopCat
            guard repaired.catHeight == 40, repaired.metrics == DesktopCatConfig.defaultMetrics, repaired.diagnostics.isEmpty else { return false }
            // 整个文件无效时拒绝，不覆盖。
            try Data("{broken".utf8).write(to: url)
            guard (try? ConfigStore.saveDesktopCatHeight(60, fallback: fallback, to: url)) == nil,
                  (try? Data(contentsOf: url)) == Data("{broken".utf8) else { return false }
            // 整组保存时一起写大小；之后改别的字段，大小保留。
            try FileManager.default.removeItem(at: url)
            try ConfigStore.saveDesktopCat(DesktopCatConfig(enabled: true, catHeight: 90), to: url)
            try ConfigStore.saveDesktopCat(ConfigStore.load(from: url).config.desktopCat.with(enabled: false), to: url)
            return ConfigStore.load(from: url).config.desktopCat.catHeight == 90
        } catch { print("桌面猫大小保存用例失败：\(error)"); return false }
    }

    // MARK: - 纯函数

    static func snapping() -> Bool {
        let resolved = [49, 52, 55, 48, 56, 36, 30, 104, 200, 52.4, 70.6].map { DesktopCatSize.resolved(CGFloat($0)) }
        guard resolved == [52, 52, 52, 48, 56, 36, 36, 104, 104, 52, 71], DesktopCatSize.resolved(.nan) == 52 else { return false }
        guard DesktopCatSize.catSize(height: 52) == CGSize(width: 120, height: 52), DesktopCatSize.catSize(height: 104) == CGSize(width: 240, height: 104),
              DesktopCatSize.catSize(height: 36) == CGSize(width: 83, height: 36) else { return false }
        // 右下角：把手在左上，往上或往左拖放大；往下拖缩小；横向按宽高比折算，取绝对值大的一个。
        func drag(_ dx: CGFloat, _ dy: CGFloat, _ corner: DesktopCatCorner) -> CGFloat {
            DesktopCatSize.dragged(from: 52, delta: CGVector(dx: dx, dy: dy), corner: corner)
        }
        guard drag(0, 30, .bottomRight) == 82, drag(-60, 0, .bottomRight) == 78, drag(0, -10, .bottomRight) == 42,
              drag(-60, 40, .bottomRight) == 92, drag(0, 300, .bottomRight) == 104, drag(0, -300, .bottomRight) == 36,
              drag(0, 2, .bottomRight) == 52 else { return false }
        // 左下角往右是放大；上方的角往下是放大。
        return drag(60, 0, .bottomLeft) == 78 && drag(0, -30, .topRight) == 82 && drag(60, 0, .topLeft) == 78 && drag(-60, 0, .topLeft) == 36
    }

    /// 窗口里的点换成屏幕坐标（y 向上）。
    static func screenPoint(_ point: CGPoint, frame: CGRect) -> CGPoint { CGPoint(x: frame.minX + point.x, y: frame.maxY - point.y) }

    static func anchors() -> Bool {
        // 一块较小的屏幕：1280 × 800，菜单栏 25 pt、程序坞 60 pt。
        let small = DesktopCatScreen(id: "00000000-0000-0000-0000-0000000000C3", visibleFrame: CGRect(x: 0, y: 60, width: 1280, height: 715), isMain: true)
        for visible in [DesktopCatWindowTests.main.visibleFrame, small.visibleFrame] {
            for corner in DesktopCatCorner.allCases {
                var anchors: [CGPoint] = []
                for height in [36, 52, 104] as [CGFloat] {
                    let layout = DesktopCatLayout(count: 4, corner: corner, catTrim: 2 * height / 52, catHeight: height)
                    let frame = DesktopCatGeometry.windowFrame(layout: layout, corner: corner, visibleFrame: visible)
                    let cat = layout.catRect, bubble = layout.bubbleRect
                    guard cat.size == DesktopCatSize.catSize(height: height), cat.minY - bubble.maxY == 10,
                          layout.bubbleSize == CGSize(width: 166, height: 93) else { return false }
                    // 下方的角固定猫的外侧下角（左边的角是猫可见左缘），上方的角固定气泡的外侧上角。
                    let anchor = corner.isTop
                        ? screenPoint(CGPoint(x: corner.isLeft ? bubble.minX : bubble.maxX, y: bubble.minY), frame: frame)
                        : screenPoint(CGPoint(x: corner.isLeft ? cat.minX + layout.catTrim : cat.maxX, y: cat.maxY), frame: frame)
                    anchors.append(anchor)
                    // 把手在窗口里，不被裁掉。
                    guard CGRect(origin: .zero, size: layout.windowSize).contains(layout.handleRect) else { return false }
                }
                guard Set(anchors.map { "\($0.x),\($0.y)" }).count == 1 else { print("桌面猫大小锚点移动：\(corner) \(anchors)"); return false }
                // 104 pt、8 项、2 条最宽（220 pt）的结束提示：按真实提示版式（第 1 轮复审 R6），全部内容在可见区域内。
                let layout = DesktopCatLayout(count: 8, corner: corner, catHeight: 104, toastWidths: [220, 220])
                let frame = DesktopCatGeometry.windowFrame(layout: layout, corner: corner, visibleFrame: visible)
                let shifted = DesktopCatWindowTests.content(frame, layout)
                guard layout.toastRects.count == 2, layout.toastRects.allSatisfy({ layout.contentRect.contains($0) }) else { return false }
                guard visible.contains(shifted) else { print("桌面猫最大尺寸超出可见区域：\(corner)"); return false }
            }
        }
        return true
    }

    /// 掩码：右半边不透明，左半边透明（与 `DesktopCatWindowTests.hitTest` 相同）。
    static let halfMask: DesktopCatAlphaMask = {
        var alpha = [UInt8](repeating: 0, count: 20 * 10)
        for y in 0..<10 { for x in 10..<20 { alpha[y * 20 + x] = 255 } }
        return DesktopCatAlphaMask(width: 20, height: 10, alpha: alpha)
    }()

    static func handleHit() -> Bool {
        for corner in DesktopCatCorner.allCases {
            for height in [36, 52, 104] as [CGFloat] {
                let layout = DesktopCatLayout(count: 4, corner: corner, catHeight: height)
                let shown = DesktopCatHitShape(layout: layout, catMask: halfMask, handleVisible: true)
                let hidden = DesktopCatHitShape(layout: layout, catMask: halfMask, handleVisible: false)
                let c = layout.handleCenter
                // 把手朝屏幕内侧：右边的角在猫左上，左边的角在猫右上。
                guard c.y == layout.catRect.minY, c.x == (corner.isLeft ? layout.catRect.maxX : layout.catRect.minX) else { return false }
                let outward: CGFloat = corner.isLeft ? 1 : -1
                let edge = CGPoint(x: c.x + outward * 5.5, y: c.y), outside = CGPoint(x: c.x + outward * 7, y: c.y)
                guard shown.contains(c), shown.inHandle(c), shown.contains(edge), !shown.contains(outside), !shown.inHandle(outside),
                      !hidden.inHandle(c), !hidden.contains(c) else { return false }
            }
        }
        return true
    }

    // MARK: - 控制器

    /// 找一个猫身上不透明的点（屏幕坐标）。
    static func catPoint(_ controller: DesktopCatController, window: NSWindow) -> CGPoint? {
        let shape = controller.hitShape(), cat = controller.model.layout.catRect
        for y in stride(from: cat.midY, to: cat.maxY, by: 2) {
            for x in stride(from: cat.maxX - 4, to: cat.minX, by: -2) where shape.inCat(CGPoint(x: x, y: y)) {
                return screenPoint(CGPoint(x: x, y: y), frame: window.frame)
            }
        }
        return nil
    }

    static func dragHandle() async -> Bool {
        let (state, controller, url) = DesktopCatWindowTests.controller(enabled: true); defer { try? FileManager.default.removeItem(at: url) }
        var opened = 0, changes = 0
        controller.onOpenPanel = { opened += 1 }
        state.onDesktopCatChanged = { _ in changes += 1; controller.apply() }
        var mouse = CGPoint(x: 1400, y: 150)
        controller.mouseLocation = { mouse }
        controller.apply(); defer { controller.hide() }
        guard let window = controller.window, let onCat = catPoint(controller, window: window) else { return false }
        let home = window.frame
        func anchor() -> CGPoint { screenPoint(CGPoint(x: controller.model.layout.catRect.maxX, y: controller.model.layout.catRect.maxY), frame: window.frame) }
        let fixed = anchor()
        // 停在猫身上出把手，再移到把手上按下。
        mouse = onCat; controller.updateMouseThrough()
        guard controller.model.handleVisible, !window.ignoresMouseEvents else { return false }
        mouse = screenPoint(controller.model.layout.handleCenter, frame: window.frame); controller.updateMouseThrough()
        guard controller.model.handleVisible else { return false }
        let bytes = try? Data(contentsOf: url)
        controller.mouseDown()
        guard controller.isResizing, !controller.model.dragging else { return false }
        // 往上拖：经过 82、92、104 pt，实时变大；窗口按新尺寸落位，猫的外侧下角不动；配置不写。
        var heights: [CGFloat] = []
        let pressed = mouse
        for dy in [30, 40, 60, 90] as [CGFloat] {
            mouse = CGPoint(x: pressed.x, y: pressed.y + dy)
            controller.mouseDragged()
            heights.append(controller.model.catHeight)
            guard anchor() == fixed, controller.model.frame.image?.size == controller.model.layout.catSize,
                  window.frame.size == controller.model.layout.windowSize else { return false }
        }
        guard heights == [82, 92, 104, 104], (try? Data(contentsOf: url)) == bytes, changes == 0, !controller.model.dragging,
              controller.dropWindow == nil else { return false }
        // 缓存只剩当前高度。
        guard controller.images.cachedHeights == [104] else { print("桌面猫缓存高度：\(controller.images.cachedHeights)"); return false }
        controller.mouseUp()
        guard opened == 0, changes == 1, !controller.isResizing, state.desktopCat.catHeight == 104,
              ConfigStore.load(from: url).config.desktopCat.catHeight == 104,
              ConfigStore.load(from: url).config.desktopCat.placement == DesktopCatPlacement(), anchor() == fixed,
              window.frame.size != home.size else { return false }
        // 往回拖到 50 pt 附近：吸附到 52 pt，松手再写一次。
        mouse = screenPoint(controller.model.layout.handleCenter, frame: window.frame); controller.updateMouseThrough()
        controller.mouseDown()
        mouse.y -= 53; controller.mouseDragged()
        guard controller.model.catHeight == 52, controller.images.cachedHeights == [52] else { return false }
        controller.mouseUp()
        guard changes == 2, ConfigStore.load(from: url).config.desktopCat.catHeight == 52, opened == 0, window.frame == home, anchor() == fixed else { return false }
        // 在把手上按下不动就松手：不写配置，不开面板。
        mouse = screenPoint(controller.model.layout.handleCenter, frame: window.frame); controller.updateMouseThrough()
        controller.mouseDown(); controller.mouseUp()
        guard changes == 2, opened == 0 else { return false }
        // 按在猫身上照常是单击。
        mouse = onCat; controller.updateMouseThrough()
        controller.mouseDown(); controller.mouseUp()
        return opened == 1 && changes == 2
    }

    static func hover() async -> Bool {
        let (_, controller, url) = DesktopCatWindowTests.controller(enabled: true); defer { try? FileManager.default.removeItem(at: url) }
        var mouse = CGPoint(x: 10, y: 10)
        controller.mouseLocation = { mouse }
        controller.apply(); defer { controller.hide() }
        guard let window = controller.window, let onCat = catPoint(controller, window: window) else { return false }
        controller.updateMouseThrough()
        guard !controller.model.handleVisible, window.ignoresMouseEvents else { return false }
        // 停在气泡上不出把手。
        let bubble = controller.model.layout.bubbleRect
        mouse = screenPoint(CGPoint(x: bubble.midX, y: bubble.midY), frame: window.frame); controller.updateMouseThrough()
        guard !controller.model.handleVisible, !window.ignoresMouseEvents else { return false }
        mouse = onCat; controller.updateMouseThrough()
        guard controller.model.handleVisible else { return false }
        // 移开：0.3 秒内仍在，之后消失，窗口恢复穿透。
        mouse = CGPoint(x: 10, y: 10); controller.updateMouseThrough()
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard controller.model.handleVisible else { return false }
        // 0.3 秒内回到把手上：取消隐藏。
        mouse = screenPoint(controller.model.layout.handleCenter, frame: window.frame); controller.updateMouseThrough()
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard controller.model.handleVisible, !window.ignoresMouseEvents else { return false }
        mouse = CGPoint(x: 10, y: 10); controller.updateMouseThrough()
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !controller.model.handleVisible, window.ignoresMouseEvents else { return false }
        // 把手隐藏后，原来把手的位置不再命中。
        return !controller.hitShape().inHandle(controller.model.layout.handleCenter)
    }

    static func settings() -> Bool {
        let (state, url) = DesktopCatSettingsTests.state(); defer { try? FileManager.default.removeItem(at: url) }
        var changes = 0
        state.onDesktopCatChanged = { _ in changes += 1 }
        let actions = DesktopCatSettingsActions(state: state)
        guard actions.catHeight == 52, actions.isDefaultSize, DesktopCatSettingsActions.sizeText(52) == "52 pt",
              DesktopCatSettingsActions.sizeText(50) == "52 pt", DesktopCatSettingsActions.sizeText(70.4) == "70 pt" else { return false }
        // 吸附到 52 pt 时不写。
        actions.setCatHeight(50)
        guard changes == 0, (try? Data(contentsOf: url)) == nil else { return false }
        actions.setCatHeight(88)
        guard changes == 1, state.desktopCat.catHeight == 88, !actions.isDefaultSize,
              ConfigStore.load(from: url).config.desktopCat.catHeight == 88 else { return false }
        // 越界的值夹到边界。
        actions.setCatHeight(500)
        guard state.desktopCat.catHeight == 104, ConfigStore.load(from: url).config.desktopCat.catHeight == 104 else { return false }
        // 恢复默认大小只改大小，开关和指标不变。
        guard state.updateDesktopCat({ $0.with(enabled: true) }) else { return false }
        let metrics = state.desktopCat.metrics
        actions.resetSize()
        let saved = ConfigStore.load(from: url).config.desktopCat
        guard saved.catHeight == 52, saved.enabled, saved.metrics == metrics, actions.isDefaultSize, state.desktopCatError == nil else { return false }
        // 文件损坏时保存失败，界面保持原值。
        try? Data("{broken".utf8).write(to: url)
        actions.setCatHeight(70)
        return state.desktopCat.catHeight == 52 && state.desktopCatError != nil && (try? Data(contentsOf: url)) == Data("{broken".utf8)
    }
}
