import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

/// 桌面猫的透明度（D48，plan `2026-10-26-desktop-cat-opacity`）。夹具全部虚构。
@MainActor
enum DesktopCatOpacityTests {
    static var tests: [(String, @MainActor () async -> Bool)] {
        [
            ("Core.DesktopCatOpacity/吸附、夹取与百分比文字", { pure() }),
            ("Core.DesktopCatOpacity/新建：缺省 1.0，第一次保存只新增对应的键", { created() }),
            ("Core.DesktopCatOpacity/编辑：吸附后只改这一个键", { edited() }),
            ("Core.DesktopCatOpacity/停用再启用保留透明度", { toggled() }),
            ("Core.DesktopCatOpacity/删除键回到 1.0 且没有诊断", { deleted() }),
            ("Core.DesktopCatOpacity/恢复默认一次写两个键", { restored() }),
            ("Core.DesktopCatOpacity/坏值按 1.0 读取且不改写文件", { broken() }),
            ("UI.DesktopCatOpacity/悬停变实、0.3 秒回落与拖动缩放保持", { hover() }),
            ("UI.DesktopCatOpacity/命中与显示透明度无关", { hitIndependent() }),
            ("UI.DesktopCatOpacity/把手和落点框不随设定变化", { handleAndDrop() }),
            ("UI.DesktopCatOpacity/不新增监视器和计时器", { noNewTimers() }),
            ("UI.DesktopCatOpacity/设置滑块拖动只改显示、松手写一次与失败回滚", { settings() }),
            ("UI.DesktopCatWindow/设置里两行不透明度滑块与大小对齐", { await settingsWindow() }),
        ]
    }

    /// 带未知字段的虚构配置。
    static let original = #"{"schemaVersion":1,"quotaRemainingWarn":0.15,"futureField":{"nested":[1,"示例"]},"desktopCat":{"enabled":true,"metrics":["example.future","system.cpu"],"placement":{"corner":"topLeft","display":"00000000-0000-0000-0000-00000000D048"},"pet":"example-pet","catHeight":80,"futureKey":"保留"}}"#

    /// 读回后去掉 `keys`，返回顶层其余字段和 `desktopCat` 的其余字段。
    static func split(_ url: URL, removing keys: [String]) -> (top: [String: Any], cat: [String: Any], removed: [String: Any])? {
        guard var top = DesktopCatConfigTests.json(url), var cat = top.removeValue(forKey: "desktopCat") as? [String: Any] else { return nil }
        var removed: [String: Any] = [:]
        for key in keys { removed[key] = cat.removeValue(forKey: key) }
        return (top, cat, removed)
    }

    static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }

    static func pure() -> Bool {
        let resolved = [0.43, 0.12, 1.3, 0.4, 0.2, 1.0, 0.33, 0.98, -1].map(DesktopCatOpacity.resolved)
        guard resolved == [0.45, 0.2, 1.0, 0.4, 0.2, 1.0, 0.35, 1.0, 0.2], DesktopCatOpacity.resolved(.nan) == 1,
              DesktopCatOpacity.resolved(.infinity) == 1 else { print("吸附结果：\(resolved)"); return false }
        guard DesktopCatOpacity.isValid(0.2), DesktopCatOpacity.isValid(1), DesktopCatOpacity.isValid(0.33),
              !DesktopCatOpacity.isValid(0.19), !DesktopCatOpacity.isValid(1.01), !DesktopCatOpacity.isValid(.nan) else { return false }
        let texts = [0.2, 0.33, 0.4, 1.0, 0.6, 0.1, 1.5].map(DesktopCatOpacity.percentText)
        guard texts == ["20%", "35%", "40%", "100%", "60%", "100%", "100%"] else { print("百分比文字：\(texts)"); return false }
        return DesktopCatOpacity.sliderValue(0.33) == 0.35 && DesktopCatOpacity.rendered(0.33) == 0.33 && DesktopCatOpacity.rendered(5) == 1
    }

    static func created() -> Bool {
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            // 缺省都是 1.0，没有诊断。
            guard DesktopCatConfig().catOpacity == 1, DesktopCatConfig().bubbleOpacity == 1 else { return false }
            try Data(original.utf8).write(to: url)
            let loaded = ConfigStore.load(from: url).config.desktopCat
            // 夹具里的未知指标会记一条诊断；不透明度不产生诊断。
            guard loaded.catOpacity == 1, loaded.bubbleOpacity == 1, !loaded.diagnostics.contains(where: { $0.contains("不透明度") }),
                  loaded.catHeight == 80 else { return false }
            guard let before = split(url, removing: []) else { return false }
            // 第一次保存猫的不透明度：只新增 catOpacity，其他字段（含未知字段）的值不变。
            try ConfigStore.saveDesktopCatOpacity([.cat: 0.6], fallback: loaded, to: url)
            guard let after = split(url, removing: ["catOpacity"]), after.removed["catOpacity"] as? Double == 0.6,
                  after.cat["bubbleOpacity"] == nil, same(before.top, after.top), same(before.cat, after.cat) else { return false }
            let reloaded = ConfigStore.load(from: url).config.desktopCat
            guard reloaded.catOpacity == 0.6, reloaded.bubbleOpacity == 1, !reloaded.diagnostics.contains(where: { $0.contains("不透明度") }) else { return false }
            // 文件里没有 desktopCat 时整组写入界面正在用的配置。
            try Data(#"{"schemaVersion":1}"#.utf8).write(to: url)
            try ConfigStore.saveDesktopCatOpacity([.bubble: 0.5], fallback: DesktopCatConfig(enabled: true), to: url)
            let whole = ConfigStore.load(from: url).config.desktopCat
            guard whole.enabled, whole.bubbleOpacity == 0.5, whole.catOpacity == 1, whole.diagnostics.isEmpty else { return false }
            // desktopCat 不是对象时同样整组写入。
            try Data(#"{"schemaVersion":1,"desktopCat":[1]}"#.utf8).write(to: url)
            try ConfigStore.saveDesktopCatOpacity([.cat: 0.3], fallback: DesktopCatConfig(enabled: true), to: url)
            let repaired = ConfigStore.load(from: url).config.desktopCat
            return repaired.enabled && repaired.catOpacity == 0.3 && repaired.bubbleOpacity == 1 && repaired.diagnostics.isEmpty
        } catch { print("桌面猫透明度新建用例失败：\(error)"); return false }
    }

    static func edited() -> Bool {
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Data(original.utf8).write(to: url)
            let loaded = ConfigStore.load(from: url).config.desktopCat
            try ConfigStore.saveDesktopCatOpacity([.bubble: 0.4], fallback: loaded, to: url)
            guard let before = split(url, removing: ["bubbleOpacity"]), before.removed["bubbleOpacity"] as? Double == 0.4,
                  ConfigStore.load(from: url).config.desktopCat.bubbleOpacity == 0.4 else { return false }
            // 吸附再夹取：0.43 → 0.45，0.12 → 0.2，1.3 → 1.0。每次只改这一个键。
            for (input, expected) in [(0.43, 0.45), (0.12, 0.2), (1.3, 1.0)] {
                try ConfigStore.saveDesktopCatOpacity([.bubble: input], fallback: loaded, to: url)
                guard let after = split(url, removing: ["bubbleOpacity"]), after.removed["bubbleOpacity"] as? Double == expected,
                      same(before.top, after.top), same(before.cat, after.cat),
                      ConfigStore.load(from: url).config.desktopCat.bubbleOpacity == expected else { print("写入 \(input) 未得到 \(expected)"); return false }
            }
            // 整个文件无效时拒绝，不覆盖。
            try Data("{broken".utf8).write(to: url)
            guard (try? ConfigStore.saveDesktopCatOpacity([.cat: 0.5], fallback: loaded, to: url)) == nil,
                  (try? Data(contentsOf: url)) == Data("{broken".utf8) else { return false }
            // 整组校验：越界的值拒绝。
            return (try? DesktopCatConfig().with(catOpacity: 0.1).validated()) == nil
                && (try? DesktopCatConfig().with(bubbleOpacity: .nan).validated()) == nil
                && (try? DesktopCatConfig().with(bubbleOpacity: 0.33).validated()) != nil
        } catch { print("桌面猫透明度编辑用例失败：\(error)"); return false }
    }

    static func toggled() -> Bool {
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Data(original.utf8).write(to: url)
            try ConfigStore.saveDesktopCatOpacity([.cat: 0.4, .bubble: 0.6], fallback: ConfigStore.load(from: url).config.desktopCat, to: url)
            // 开关走整组保存：关掉再打开，两个透明度不变。
            try ConfigStore.saveDesktopCat(ConfigStore.load(from: url).config.desktopCat.with(enabled: false), to: url)
            let off = ConfigStore.load(from: url).config.desktopCat
            guard !off.enabled, off.catOpacity == 0.4, off.bubbleOpacity == 0.6 else { return false }
            try ConfigStore.saveDesktopCat(off.with(enabled: true), to: url)
            let on = ConfigStore.load(from: url).config.desktopCat
            return on.enabled && on.catOpacity == 0.4 && on.bubbleOpacity == 0.6 && on.diagnostics.isEmpty
        } catch { print("桌面猫透明度停用用例失败：\(error)"); return false }
    }

    static func deleted() -> Bool {
        let base = #"{"schemaVersion":1,"desktopCat":{"enabled":true,"catOpacity":0.4,"bubbleOpacity":0.6}}"#
        guard DesktopCatConfigTests.load(base, check: { config, _, _ in config.catOpacity == 0.4 && config.bubbleOpacity == 0.6 }) else { return false }
        // 手动删掉键：回到 1.0，不产生诊断。
        return DesktopCatConfigTests.load(#"{"schemaVersion":1,"desktopCat":{"enabled":true,"bubbleOpacity":0.6}}"#) { config, _, _ in
            config.catOpacity == 1 && config.bubbleOpacity == 0.6 && config.diagnostics.isEmpty
        } && DesktopCatConfigTests.load(#"{"schemaVersion":1,"desktopCat":{"enabled":true}}"#) { config, _, _ in
            config.catOpacity == 1 && config.bubbleOpacity == 1 && config.diagnostics.isEmpty
        }
    }

    static func restored() -> Bool {
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Data(original.utf8).write(to: url)
            try ConfigStore.saveDesktopCatOpacity([.cat: 0.4, .bubble: 0.6], fallback: ConfigStore.load(from: url).config.desktopCat, to: url)
            guard let before = split(url, removing: ["catOpacity", "bubbleOpacity"]) else { return false }
            // 恢复默认：一次调用（一次写盘）把两个键都写成 1.0，其他字段不变。
            try ConfigStore.saveDesktopCatOpacity([.cat: 1, .bubble: 1], fallback: ConfigStore.load(from: url).config.desktopCat, to: url)
            guard let after = split(url, removing: ["catOpacity", "bubbleOpacity"]), after.removed["catOpacity"] as? Double == 1,
                  after.removed["bubbleOpacity"] as? Double == 1, same(before.top, after.top), same(before.cat, after.cat) else { return false }
            let config = ConfigStore.load(from: url).config.desktopCat
            return config.catOpacity == 1 && config.bubbleOpacity == 1 && config.catHeight == 80 && config.pet == "example-pet"
        } catch { print("桌面猫透明度恢复默认用例失败：\(error)"); return false }
    }

    static func broken() -> Bool {
        let base = #"{"schemaVersion":1,"quotaRemainingWarn":0.15,"desktopCat":{"enabled":true,"metrics":["system.power","system.cpu"],"placement":{"corner":"topLeft"},"catHeight":80,"#
        let bad = [#""abc""#, "null", "-0.5", "0.1", "1.5", "[0.5]"]
        for (index, value) in bad.enumerated() {
            for part in DesktopCatOpacityPart.allCases {
                let text = base + "\"\(part.rawValue)\":\(value)}}"
                let note = part == .cat ? "桌面猫的猫不透明度无效，已按 100% 显示" : "桌面猫的气泡不透明度无效，已按 100% 显示"
                // `load` 断言读取不改写文件；其他字段照常读取，诊断不含路径。
                let ok = DesktopCatConfigTests.load(text) { config, _, url in
                    config.catOpacity == 1 && config.bubbleOpacity == 1 && config.diagnostics == [note]
                        && !config.diagnostics.contains { $0.contains(url.path) || $0.contains("/") }
                        && config.enabled && config.metrics == ["system.power", "system.cpu"] && config.placement.corner == .topLeft && config.catHeight == 80
                }
                guard ok else { print("桌面猫透明度坏值第 \(index + 1) 例（\(part.rawValue)）未通过"); return false }
            }
        }
        // 两项都坏：各记一条。合法但不在 5% 步长上的值原样读取。
        return DesktopCatConfigTests.load(base + #""catOpacity":"x","bubbleOpacity":9}}"#) { config, _, _ in
            config.catOpacity == 1 && config.bubbleOpacity == 1 && config.diagnostics.count == 2
        } && DesktopCatConfigTests.load(base + #""catOpacity":0.33,"bubbleOpacity":0.2}}"#) { config, _, _ in
            config.catOpacity == 0.33 && config.bubbleOpacity == 0.2 && config.diagnostics.isEmpty
        }
    }

    // MARK: - 显示与悬停（条目 2）

    /// 开着桌面猫、设定为 `cat` / `bubble` 的控制器；延迟任务改为手动执行。
    static func controller(cat: Double, bubble: Double) -> (PanelState, DesktopCatController, URL, () -> [(TimeInterval, DispatchWorkItem)]) {
        let (state, controller, url) = DesktopCatWindowTests.controller(enabled: true)
        _ = state.updateDesktopCatOpacity([.cat: cat, .bubble: bubble])
        var scheduled: [(TimeInterval, DispatchWorkItem)] = []
        controller.scheduleAfter = { scheduled.append(($0, $1)) }
        return (state, controller, url, { scheduled })
    }

    static func shown(_ controller: DesktopCatController) -> [Double] {
        [controller.model.shownCatOpacity, controller.model.shownBubbleOpacity]
    }

    static func hover() -> Bool {
        let (_, controller, url, scheduled) = controller(cat: 0.4, bubble: 0.6); defer { try? FileManager.default.removeItem(at: url) }
        let far = CGPoint(x: 10, y: 10)
        var mouse = far
        controller.mouseLocation = { mouse }
        controller.apply(); defer { controller.hide() }
        guard let window = controller.window, let onCat = DesktopCatSizeTests.catPoint(controller, window: window) else { return false }
        let bubble = controller.model.layout.bubbleRect
        let onBubble = DesktopCatSizeTests.screenPoint(CGPoint(x: bubble.midX, y: bubble.midY), frame: window.frame)
        controller.updateMouseThrough()
        // 不悬停：按设定显示。
        guard shown(controller) == [0.4, 0.6], !controller.model.solid, scheduled().isEmpty else { print("不悬停：\(shown(controller))"); return false }
        // 悬停猫：两者都到 1.0；测试开着“减少动态效果”，直接切换。
        mouse = onCat; controller.updateMouseThrough()
        guard shown(controller) == [1, 1], !controller.solidAnimated, scheduled().isEmpty else { return false }
        // 离开：0.3 秒的任务执行前仍是 1.0，执行后回到设定值。
        mouse = far; controller.updateMouseThrough()
        guard scheduled().count == 1, scheduled()[0].0 == 0.3, shown(controller) == [1, 1] else { return false }
        controller.updateMouseThrough()
        guard scheduled().count == 1 else { return false }
        scheduled()[0].1.perform()
        guard shown(controller) == [0.4, 0.6] else { return false }
        // 悬停气泡同样变实；离开后 0.3 秒内回到猫身上：取消回落。
        mouse = onBubble; controller.updateMouseThrough()
        guard shown(controller) == [1, 1] else { return false }
        mouse = far; controller.updateMouseThrough()
        guard scheduled().count == 2 else { return false }
        mouse = onCat; controller.updateMouseThrough()
        scheduled()[1].1.perform()
        guard scheduled()[1].1.isCancelled, shown(controller) == [1, 1] else { return false }
        // 悬停显示中的把手也算。
        mouse = DesktopCatSizeTests.screenPoint(controller.model.layout.handleCenter, frame: window.frame); controller.updateMouseThrough()
        guard controller.model.handleVisible, shown(controller) == [1, 1], scheduled().count == 2 else { return false }
        // 缩放期间保持 1.0：按下把手后，即使之前有待回落的任务也已取消。
        controller.mouseDown()
        guard controller.isResizing, shown(controller) == [1, 1] else { return false }
        let pressed = mouse
        mouse = CGPoint(x: pressed.x, y: pressed.y + 30); controller.mouseDragged()
        controller.updateMouseThrough()
        guard shown(controller) == [1, 1], scheduled().count == 2 else { return false }
        // 松手后按鼠标位置决定：鼠标仍在把手附近时保持；移开才回落。
        controller.mouseUp()
        mouse = far; controller.updateMouseThrough()
        guard let fade = scheduled().last, scheduled().count == 3, shown(controller) == [1, 1] else { return false }
        fade.1.perform()
        guard shown(controller) == [0.4, 0.6] else { return false }
        // 拖动期间保持 1.0；拖到左上区域松手，猫落到左上角，鼠标不在猫上，0.3 秒后回落。
        guard let onCatNow = DesktopCatSizeTests.catPoint(controller, window: window) else { return false }
        mouse = onCatNow; controller.updateMouseThrough()
        controller.mouseDown()
        mouse = CGPoint(x: 300, y: 800); controller.mouseDragged()
        guard controller.model.dragging, shown(controller) == [1, 1] else { return false }
        controller.updateMouseThrough()
        guard shown(controller) == [1, 1], scheduled().count == 3 else { return false }
        controller.mouseUp()
        guard controller.model.corner == .topLeft, scheduled().count == 4, shown(controller) == [1, 1] else { print("拖动松手：\(scheduled().count)"); return false }
        scheduled()[3].1.perform()
        guard shown(controller) == [0.4, 0.6] else { return false }
        // 关掉“减少动态效果”：变实带 0.15 秒过渡。
        controller.reduceMotion = { false }
        guard let window2 = controller.window, let onCat2 = DesktopCatSizeTests.catPoint(controller, window: window2) else { return false }
        mouse = onCat2; controller.updateMouseThrough()
        guard controller.solidAnimated, shown(controller) == [1, 1] else { return false }
        // 关闭桌面猫时清掉变实状态。
        controller.hide()
        return !controller.model.solid
    }

    static func hitIndependent() -> Bool {
        let (_, controller, url, _) = controller(cat: 1, bubble: 1); defer { try? FileManager.default.removeItem(at: url) }
        controller.mouseLocation = { CGPoint(x: 10, y: 10) }
        controller.apply(); defer { controller.hide() }
        guard let window = controller.window, let onCat = DesktopCatSizeTests.catPoint(controller, window: window) else { return false }
        let local = CGPoint(x: onCat.x - window.frame.minX, y: window.frame.maxY - onCat.y)
        let bubble = controller.model.layout.bubbleRect
        // 猫内、气泡内、透明边距各一点。
        let points = [local, CGPoint(x: bubble.midX, y: bubble.midY), CGPoint(x: 1, y: 1)]
        let full = points.map { controller.hitShape().contains($0) }
        guard full == [true, true, false] else { print("命中：\(full)"); return false }
        for (cat, bubbleOpacity) in [(0.2, 0.2), (0.2, 1.0), (1.0, 0.2)] {
            controller.model.catOpacity = cat; controller.model.bubbleOpacity = bubbleOpacity
            guard points.map({ controller.hitShape().contains($0) }) == full else { return false }
        }
        return true
    }

    /// 像素：(x, y) 为 pt，原点左上。
    static func pixel(_ data: Data, _ point: CGPoint) -> NSColor? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.deviceRGB)
    }

    static func handleAndDrop() -> Bool {
        // 把手：设定 40% 和 100% 时（合成预览的两个场景），把手中心的像素相同。
        let cache = DesktopCatImage()
        var colors: [NSColor] = []
        for (kind, opacity) in [(DesktopCatPreview.Case.opacity40, 0.4), (.opacityDefault, 1.0)] {
            let state = DesktopCatPreview.state(kind)
            let model = DesktopCatPreview.model(state: state, cache: cache, dark: false)
            model.handleVisible = true
            guard model.shownCatOpacity == opacity, let data = DesktopCatPreview.render(dark: false, size: model.layout.windowSize, content: { DesktopCatContentView(model: model) }),
                  let color = pixel(data, model.layout.handleCenter) else { return false }
            colors.append(color)
        }
        guard colors.count == 2, abs(colors[0].redComponent - colors[1].redComponent) < 0.01,
              abs(colors[0].alphaComponent - colors[1].alphaComponent) < 0.01, colors[0].redComponent > 0.95 else {
            print("把手像素：\(colors)"); return false
        }
        // 落点框在单独的窗口里，拖动时窗口和落点框都不改 alphaValue（不用整窗透明度）。
        let (_, controller, url, _) = controller(cat: 0.2, bubble: 0.2); defer { try? FileManager.default.removeItem(at: url) }
        var mouse = CGPoint(x: 1400, y: 150)
        controller.mouseLocation = { mouse }
        controller.apply(); defer { controller.hide() }
        guard let window = controller.window, window.alphaValue == 1, controller.model.catOpacity == 0.2 else { return false }
        controller.mouseDown(); mouse = CGPoint(x: 300, y: 800); controller.mouseDragged()
        guard let overlay = controller.dropWindow, overlay.alphaValue == 1, window.alphaValue == 1, controller.dropTargets.count == 4 else { return false }
        controller.mouseUp()
        return window.alphaValue == 1
    }

    static func noNewTimers() -> Bool {
        var counts: [Int] = []
        for opacity in [1.0, 0.4] {
            let (_, controller, url, scheduled) = controller(cat: opacity, bubble: opacity); defer { try? FileManager.default.removeItem(at: url) }
            var mouse = CGPoint(x: 10, y: 10)
            controller.mouseLocation = { mouse }
            controller.apply(); defer { controller.hide() }
            guard let window = controller.window, let onCat = DesktopCatSizeTests.catPoint(controller, window: window) else { return false }
            // 不动鼠标时不投递任何延迟任务；进出一次只投递一个一次性任务。
            controller.updateMouseThrough(); controller.updateMouseThrough()
            guard scheduled().isEmpty else { return false }
            mouse = onCat; controller.updateMouseThrough()
            mouse = CGPoint(x: 10, y: 10); controller.updateMouseThrough(); controller.updateMouseThrough()
            guard scheduled().count == 1 else { return false }
            counts.append(controller.monitorCount)
        }
        print("桌面猫鼠标监视器：100% 时 \(counts[0]) 个，40% 时 \(counts[1]) 个")
        return counts.count == 2 && counts[0] == counts[1]
    }

    // MARK: - 设置入口（条目 3）

    static func settings() -> Bool {
        let (state, url) = DesktopCatSettingsTests.state(); defer { try? FileManager.default.removeItem(at: url) }
        guard state.updateDesktopCat({ $0.with(enabled: true) }) else { return false }
        var changes = 0
        let controller = DesktopCatController(state: state, onOpenPanel: {})
        controller.ordersFront = false
        controller.screens = { [DesktopCatWindowTests.main] }
        controller.mouseLocation = { CGPoint(x: 10, y: 10) }
        state.onDesktopCatChanged = { _ in changes += 1; controller.apply() }
        controller.apply(); defer { controller.hide() }
        let actions = DesktopCatSettingsActions(state: state)
        guard DesktopCatSettingsActions.opacityText(0.2) == "20%", DesktopCatSettingsActions.opacityText(0.33) == "35%",
              actions.opacity(.cat) == 1, actions.opacity(.bubble) == 1, actions.isDefaultOpacity else { return false }
        // 拖动中：只改草稿和桌面猫的显示，不写配置。
        let bytes = try? Data(contentsOf: url)
        for value in [0.9, 0.62, 0.41] { actions.dragOpacity(.bubble, to: value) }
        controller.refreshBubble()
        guard actions.opacity(.bubble) == 0.4, controller.model.bubbleOpacity == 0.4, controller.model.catOpacity == 1,
              (try? Data(contentsOf: url)) == bytes, changes == 0, state.desktopCat.bubbleOpacity == 1 else { return false }
        // 松手：只写一次。
        actions.commitOpacity(.bubble)
        controller.refreshBubble()
        guard changes == 1, state.desktopCatOpacityDraft.isEmpty, ConfigStore.load(from: url).config.desktopCat.bubbleOpacity == 0.4,
              controller.model.bubbleOpacity == 0.4, !actions.isDefaultOpacity, actions.opacity(.bubble) == 0.4 else { return false }
        // 再次松手（没有拖动）不写。
        actions.commitOpacity(.bubble)
        guard changes == 1 else { return false }
        actions.dragOpacity(.cat, to: 0.2); actions.commitOpacity(.cat)
        guard changes == 2, ConfigStore.load(from: url).config.desktopCat.catOpacity == 0.2 else { return false }
        // 合法非步长值（读取路径见 `broken`）：滑块位置和文字按 5% 显示，桌面猫照原值显示。
        state.desktopCatOpacityDraft[.cat] = 0.33
        controller.refreshBubble()
        guard actions.opacity(.cat) == 0.35, DesktopCatSettingsActions.opacityText(0.33) == "35%", controller.model.catOpacity == 0.33 else { return false }
        state.desktopCatOpacityDraft = [:]
        // 恢复默认：两项都写成 1.0，界面可用状态随之变灰。
        let before = changes
        actions.resetOpacity()
        let saved = ConfigStore.load(from: url).config.desktopCat
        guard changes == before + 1, saved.catOpacity == 1, saved.bubbleOpacity == 1, saved.enabled, actions.isDefaultOpacity,
              DesktopCatConfigTests.json(url).flatMap({ ($0["desktopCat"] as? [String: Any])?["catOpacity"] as? Double }) == 1 else { return false }
        // 保存失败：显示原因，滑块和桌面猫回到原值，文件不变。
        try? Data("{broken".utf8).write(to: url)
        actions.dragOpacity(.cat, to: 0.5)
        actions.commitOpacity(.cat)
        controller.refreshBubble()
        return state.desktopCatError != nil && actions.opacity(.cat) == 1 && state.desktopCatOpacityDraft.isEmpty
            && controller.model.catOpacity == 1 && (try? Data(contentsOf: url)) == Data("{broken".utf8)
    }

    /// 前台用例（条目 4 实跑）：真实设置窗口的外观栏，“大小”下面依次是两行不透明度滑块，宽度和左缘与大小滑块一致。
    /// 设了 `MEOWMAC_RENDER_DIR` 时截浅色和深色两张图。
    static func settingsWindow() async -> Bool {
        let (state, url) = DesktopCatSettingsTests.state(); defer { try? FileManager.default.removeItem(at: url) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meowmac-desktopcat-opacity-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        CatRuntime.initialize(state: state, store: CatStore(rootURL: root))
        guard state.updateDesktopCatOpacity([.bubble: 0.6]) else { return false }
        let settings = SettingsWindowController(state: state)
        settings.openDesktopCat()
        defer { settings.closeWithoutConfirmation() }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard let window = settings.window else { return false }
        SettingsControlTestSupport.settle(window)
        // SwiftUI 滑块在 AppKit 里是 NSSlider；按真实窗口里的视图位置比较（窗口坐标，y 向上）。
        func sliders(_ view: NSView) -> [NSSlider] { ((view as? NSSlider).map { [$0] } ?? []) + view.subviews.flatMap(sliders) }
        guard let content = window.contentView else { return false }
        let frames = sliders(content).map { $0.convert($0.bounds, to: nil) }.filter { abs($0.width - 140) < 1 }.sorted { $0.midY > $1.midY }
        func buttonFrame(_ id: String) -> CGRect? {
            (SettingsControlTestSupport.element(window, id: id) as? NSView).map { $0.convert($0.bounds, to: nil) }
        }
        print("设置里宽 140 pt 的滑块（窗口坐标）：\(frames.map { "x \(Int($0.minX)) 宽 \(Int($0.width)) 中线 y \(Int($0.midY))" })")
        guard frames.count == 3, let resetSize = buttonFrame("desktop-cat.reset-size"), let resetOpacity = buttonFrame("desktop-cat.reset-opacity") else {
            print("缺少滑块或按钮"); return false
        }
        // 自上而下：大小、猫的不透明度、气泡不透明度；三者左缘和宽度一致，右侧按钮列也对齐。
        guard frames.allSatisfy({ abs($0.minX - frames[0].minX) < 0.5 && abs($0.width - frames[0].width) < 0.5 }),
              abs(resetSize.midY - frames[0].midY) < 2, abs(resetOpacity.midY - frames[2].midY) < 2,
              abs(resetSize.minX - resetOpacity.minX) < 0.5, abs(resetSize.width - resetOpacity.width) < 0.5,
              (SettingsControlTestSupport.element(window, id: "desktop-cat.reset-opacity") as? NSButton)?.isEnabled == true else {
            print("按钮：大小 \(resetSize)，不透明度 \(resetOpacity)"); return false
        }
        if let path = ProcessInfo.processInfo.environment["MEOWMAC_RENDER_DIR"], let view = window.contentView {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for dark in [false, true] {
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    SettingsControlTestSupport.settle(window)
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    // `cacheDisplay` 不带窗口底色：按当前外观的窗口底色垫底再合成，否则深色的白字落在透明底上看不见。
                    let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                    guard let output, let context = NSGraphicsContext(bitmapImageRep: output) else { return false }
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                    let bounds = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
                    (window.appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill(); bounds.fill()
                    }
                    rep.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                    NSGraphicsContext.restoreGraphicsState()
                    try output.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings-opacity-\(dark ? "dark" : "light").png"))
                }
                window.appearance = nil
            } catch { print("设置截图失败：\(error)"); return false }
        }
        return settings.navigation.section == .appearance && settings.navigation.sessions[.appearance]?.isDirty == false
    }
}
