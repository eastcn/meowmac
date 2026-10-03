import AppKit
import MeowMacCore
import MeowMacUI

@MainActor
enum StyleSettingsTests {
    private static let root = URL(fileURLWithPath: "build/acceptance/style-tests/window-app", isDirectory: true)
    private static func prepare() throws -> (PanelState, CatStore, StyleSettingsController) {
        let manager = FileManager.default
        try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
        let state = PanelPreviewRenderer.syntheticState()
        let cats = CatStore(rootURL: root)
        CatRuntime.initialize(state: state, store: cats)
        state.styleStore = StyleStore(rootURL: root)
        let controller = StyleSettingsController(state: state)
        state.onShowStyleSettings = { controller.present() }
        state.onCatChanged = { controller.catDidChange() }
        return (state, cats, controller)
    }
    static func lifecycle() -> Bool {
        do {
            let (state, cats, controller) = try prepare()
            defer { controller.window?.close() }
            let menu = SettingsMenu.make(state: state)
            guard let index = menu.items.firstIndex(where: { $0.title == "布局与显示…" }),
                  menu.items[index + 1].title == "样式…", let action = menu.items[index + 1].action,
                  NSApplication.shared.sendAction(action, to: menu.items[index + 1].target, from: menu.items[index + 1]),
                  let window = controller.window, let model = controller.model, window.title == "样式",
                  window.contentRect(forFrameRect: window.frame).width == 520 else { return false }
            controller.present()
            guard controller.window === window, controller.model === model else { return false }
            model.setBasis(.used); model.setEmail(.masked); model.setChartMinutes(15); model.setColor(.teal, for: .claude)
            guard state.style == .default, model.isDirty, model.emailExample == "账号邮箱示例：n***@e***" else { return false }
            model.setEmail(.hidden)
            guard model.emailExample == "账号邮箱示例：（不显示）" else { return false }
            model.restoreDefault()
            guard !model.isDirty, state.style == .default else { return false }
            model.setBasis(.used); let changed = model.draft; model.save()
            guard controller.window == nil, state.style == changed,
                  StyleStore(rootURL: root).load().settings == changed else { return false }
            let file = root.appendingPathComponent("style.json")
            let bytes = try Data(contentsOf: file)
            state.styleStore = StyleStore(rootURL: root, beforePublish: { throw StyleError.invalid("合成保存失败") })
            controller.present()
            guard let failed = controller.model else { return false }
            failed.setEmail(.hidden); failed.save()
            guard controller.window != nil, failed.isDirty, failed.error != nil, state.style == changed,
                  (try Data(contentsOf: file)) == bytes else { return false }
            failed.cancel()
            guard controller.window == nil else { return false }
            controller.present(); controller.model?.setChartMinutes(15); controller.window?.close()
            guard state.style == changed, (try Data(contentsOf: file)) == bytes else { return false }
            controller.present(); controller.model?.setEmail(.masked)
            let draft = controller.model?.draft
            let failingCats = CatStore(rootURL: root, beforeSelectionSave: { throw StyleError.invalid("合成切猫失败") })
            guard (try? failingCats.select("builtin.round", state: state)) == nil,
                  controller.model?.draft == draft, controller.window != nil else { return false }
            try cats.select("builtin.round", state: state)
            return controller.window == nil && state.style == changed && (try? Data(contentsOf: file)) == bytes
        } catch { print("样式窗口生命周期失败：\(error)"); return false }
    }
    static func controls() -> Bool {
        do {
            let (state, _, controller) = try prepare()
            controller.present()
            defer { controller.window?.close() }
            guard let window = controller.window, let model = controller.model else { return false }
            let support = SettingsControlTestSupport.self
            support.settle(window)
            try support.capture(window, name: "style-default")
            guard let basis = support.element(window, id: "style.basis") as? NSSegmentedControl,
                  let email = support.element(window, id: "style.email") as? NSSegmentedControl,
                  let range = support.element(window, id: "style.range") as? NSSegmentedControl else { return false }
            for (control, selected) in [(basis, 1), (email, 1), (range, 0)] {
                control.selectedSegment = selected
                guard control.sendAction(control.action, to: control.target) else { return false }
            }
            guard model.draft.quotaBasis == .used, model.draft.email == .masked, model.draft.chartMinutes == 15,
                  state.style == .default,
                  support.click(window, id: "style.color.claude.pink"), model.draft.color(for: .claude) == .pink,
                  let pick = support.element(window, id: "style.color.claude.pink") as? NSButton, pick.state == .on,
                  support.click(window, id: "style.reset"), !model.isDirty,
                  support.click(window, id: "style.color.codex.blue"),
                  support.click(window, id: "style.save"), controller.window == nil,
                  state.style.color(for: .codex) == .blue else { return false }
            controller.present()
            guard let cancelWindow = controller.window else { return false }
            controller.model?.setEmail(.hidden)
            return support.click(cancelWindow, id: "style.cancel") && controller.window == nil && state.style.email == .full
        } catch { print("样式真实控件失败：\(error)"); return false }
    }

    static func colorPreviews() -> Bool {
        do {
            let (state, _, controller) = try prepare()
            controller.present()
            defer { controller.window?.close() }
            guard let window = controller.window, let model = controller.model else { return false }
            let support = SettingsControlTestSupport.self
            support.settle(window)
            func matches(_ provider: QuotaProvider, style: StyleSettings) -> Bool {
                guard let bar = support.element(window, id: "style.preview." + provider.rawValue) as? NSBox,
                      abs(bar.frame.width - 56) < 0.5, abs(bar.frame.height - 6) < 0.5 else {
                    print("渠道预览条缺失或尺寸错误：\(provider)"); return false
                }
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    var valid = false
                    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                        guard let actual = bar.fillColor.usingColorSpace(.sRGB),
                              let expected = QuotaPalette.color(provider, style: style).usingColorSpace(.sRGB) else { return }
                        valid = zip([actual.redComponent, actual.greenComponent, actual.blueComponent],
                                    [expected.redComponent, expected.greenComponent, expected.blueComponent])
                            .allSatisfy { abs($0 - $1) < 0.001 }
                    }
                    guard valid else { print("渠道预览条颜色错误：\(provider)，\(appearance)"); return false }
                }
                return true
            }
            let providers: [QuotaProvider] = [.claude, .codex, .deepseek, .opencodego]
            guard providers.allSatisfy({ matches($0, style: .default) }) else { return false }
            for (provider, color) in zip(providers, [ThemeColor.pink, .blue, .teal, .purple]) {
                guard support.click(window, id: "style.color." + provider.rawValue + "." + color.rawValue) else { return false }
                guard model.draft.color(for: provider) == color, matches(provider, style: model.draft),
                      state.style == .default else { return false }
            }
            try support.capture(window, name: "style-selected-colors")
            guard support.click(window, id: "style.reset"), !model.isDirty,
                  providers.allSatisfy({ matches($0, style: .default) }) else { return false }
            guard support.click(window, id: "style.color.claude.pink"), model.isDirty,
                  support.click(window, id: "style.cancel"), controller.window == nil else { return false }
            controller.present()
            guard let reopened = controller.window else { return false }
            support.settle(reopened)
            return state.style == .default && providers.allSatisfy { provider in
                guard let bar = support.element(reopened, id: "style.preview." + provider.rawValue) as? NSBox else { return false }
                return bar.fillColor.usingColorSpace(.sRGB) == QuotaPalette.color(provider).usingColorSpace(.sRGB)
            }
        } catch { print("渠道预览条测试失败：\(error)"); return false }
    }
}
