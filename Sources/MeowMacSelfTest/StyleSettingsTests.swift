import AppKit
import MeowMacCore
import MeowMacUI

@MainActor
enum StyleSettingsTests {
    private static let root = URL(fileURLWithPath: "build/acceptance/style-tests/window-app", isDirectory: true)
    private static func prepare() throws -> (PanelState, CatStore, SettingsWindowController) {
        let manager = FileManager.default
        try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
        let state = PanelPreviewRenderer.syntheticState()
        let cats = CatStore(rootURL: root)
        CatRuntime.initialize(state: state, store: cats)
        state.styleStore = StyleStore(rootURL: root)
        let controller = SettingsWindowController(state: state)
        state.onOpenSettings = { controller.open(section: $0) }
        state.onCatChanged = { controller.catDidChange() }
        return (state, cats, controller)
    }
    private static func resetFromMenu(_ window: NSWindow, title: String) -> Bool {
        SettingsControlTestSupport.settle(window)
        guard let button = SettingsControlTestSupport.element(window, id: "appearance.reset") as? NSButton,
              button.action != nil, let item = button.menu?.item(withTitle: title), item.isEnabled,
              let action = item.action, let target = item.target else { return false }
        let sent = NSApplication.shared.sendAction(action, to: target, from: item)
        SettingsControlTestSupport.settle(window)
        return sent
    }
    static func resetMenu() -> Bool {
        do {
            let (state, _, controller) = try prepare()
            controller.open(section: .appearance, load: false)
            defer { controller.closeWithoutConfirmation() }
            guard let window = controller.window, let layout = controller.appearance.layout else { return false }
            let style = controller.appearance.style
            style.setBasis(.used); layout.moveTab(.network, to: .system)
            let layoutDraft = layout.draft
            guard resetFromMenu(window, title: "恢复默认样式"), style.draft == .default,
                  layout.draft == layoutDraft, layout.isDirty else { print("默认样式菜单动作或独立草稿断言失败"); return false }
            style.setEmail(.hidden)
            let styleDraft = style.draft
            guard resetFromMenu(window, title: "恢复默认布局"), layout.draft == layout.packageDefault,
                  style.draft == styleDraft, style.isDirty, state.style == .default, state.panelLayout == .default else { print("默认布局菜单动作或独立草稿断言失败"); return false }
            controller.appearance.discard()
            state.selectedCat = nil; controller.catDidChange()
            SettingsControlTestSupport.settle(window)
            guard let button = SettingsControlTestSupport.element(window, id: "appearance.reset") as? NSButton,
                  let menu = button.menu, menu.items.map(\.title) == ["恢复默认样式", "恢复默认布局"],
                  menu.autoenablesItems == false, menu.items[0].isEnabled, !menu.items[1].isEnabled,
                  controller.appearance.layout == nil else { print("无猫菜单未禁用布局：\(controller.appearance.layout == nil)，\((SettingsControlTestSupport.element(window, id: "appearance.reset") as? NSButton)?.menu?.items.map { $0.isEnabled } ?? [])"); return false }
            style.setBasis(.used)
            return resetFromMenu(window, title: "恢复默认样式") && style.draft == .default
        } catch { print("恢复默认生产菜单测试失败：\(error)"); return false }
    }
    private static func clickControl(_ window: NSWindow, id: String) -> Bool {
        SettingsControlTestSupport.settle(window)
        guard let button = SettingsControlTestSupport.element(window, id: id) as? NSButton,
              button.isEnabled else { return false }
        button.performClick(nil)
        SettingsControlTestSupport.settle(window)
        return true
    }
    static func combinedSave() async -> Bool {
        do {
            let (state, _, controller) = try prepare()
            defer { controller.closeWithoutConfirmation() }
            controller.open(section: .appearance)
            let model = controller.appearance
            guard let layout = model.layout else { return false }
            model.style.setBasis(.used)
            guard await model.save(), state.style.quotaBasis == .used, !model.isDirty,
                  state.panelLayout == .default else { return false }
            layout.setVisible(false, id: "quota.cost", in: .quota)
            guard await model.save(), !model.isDirty, state.style.quotaBasis == .used,
                  !state.panelLayout.placements(for: .quota).first(where: { $0.id == "quota.cost" })!.visible else { return false }
            model.style.setEmail(.masked)
            layout.moveTab(.network, to: .system)
            guard await model.save(), !model.isDirty, state.style.email == .masked,
                  state.panelLayout.tabs.first == .network else { return false }
            let savedStyle = model.style.saved
            let savedLayout = layout.saved
            model.style.setChartMinutes(15)
            layout.moveTab(.quota, to: .network)
            model.discard()
            guard model.style.draft == savedStyle, layout.draft == savedLayout, !model.isDirty else { return false }
            state.layoutStore = PanelLayoutStore(rootURL: root, beforePublish: { throw PanelLayoutError.invalid("合成布局失败") })
            model.style.setEmail(.hidden)
            layout.moveTab(.quota, to: .network)
            let styleDraft = model.style.draft
            let layoutDraft = layout.draft
            guard !(await model.save()), model.statusText.contains("样式已保存"),
                  model.statusText.contains("布局保存失败"), model.statusText.contains("合成布局失败"),
                  model.style.draft == styleDraft, layout.draft == layoutDraft,
                  !model.style.isDirty, layout.isDirty, state.style == styleDraft,
                  state.panelLayout == savedLayout else { return false }
            layout.selectedTab = .network
            guard model.statusText.contains("样式已保存"), model.statusText.contains("布局保存失败") else { return false }
            model.discard()
            guard model.style.draft == styleDraft, layout.draft == savedLayout, !model.isDirty else { return false }
            // 反向失败同样保留草稿，已成功的布局不回滚。
            state.layoutStore = PanelLayoutStore(rootURL: root)
            state.styleStore = StyleStore(rootURL: root, beforePublish: { throw StyleError.invalid("合成样式失败") })
            model.style.setChartMinutes(15)
            layout.moveTab(.quota, to: .network)
            let nextLayout = layout.draft
            guard !(await model.save()), model.statusText.contains("样式保存失败"),
                  model.statusText.contains("布局已保存"), model.style.isDirty, !layout.isDirty,
                  state.panelLayout == nextLayout else { return false }
            let noCat = PanelState()
            noCat.selectedCat = nil
            noCat.styleStore = StyleStore(rootURL: root.appendingPathComponent("no-cat"))
            let noCatModel = AppearanceSettingsModel(state: noCat)
            noCatModel.style.setEmail(.hidden)
            let noCatSaved = await noCatModel.save()
            return noCatModel.layout == nil && noCatSaved && noCat.style.email == .hidden
        } catch { print("外观联合保存测试失败：\(error)"); return false }
    }
    static func lifecycle() -> Bool {
        do {
            let (state, cats, controller) = try prepare()
            defer { controller.closeWithoutConfirmation() }
            controller.open(section: .appearance)
            guard let window = controller.window, let model = Optional(controller.appearance.style), window.title == "设置",
                  window.contentRect(forFrameRect: window.frame).width == 760 else { return false }
            controller.open(section: .appearance)
            guard controller.window === window, controller.appearance.style === model else { return false }
            model.setBasis(.used); model.setEmail(.masked); model.setChartMinutes(15); model.setColor(.teal, for: .claude)
            guard state.style == .default, model.isDirty, model.emailExample == "账号邮箱示例：n***@e***" else { return false }
            model.setEmail(.hidden)
            guard model.emailExample == "账号邮箱示例：（不显示）" else { return false }
            model.restoreDefault()
            guard !model.isDirty, state.style == .default else { return false }
            model.setBasis(.used); let changed = model.draft; model.save()
            guard controller.window != nil, state.style == changed,
                  StyleStore(rootURL: root).load().settings == changed else { return false }
            let file = root.appendingPathComponent("style.json")
            let bytes = try Data(contentsOf: file)
            state.styleStore = StyleStore(rootURL: root, beforePublish: { throw StyleError.invalid("合成保存失败") })
            controller.open(section: .appearance)
            guard let failed = Optional(controller.appearance.style) else { return false }
            failed.setEmail(.hidden); failed.save()
            guard controller.window != nil, failed.isDirty, failed.error != nil, state.style == changed,
                  (try Data(contentsOf: file)) == bytes else { return false }
            failed.cancel()
            guard controller.window != nil, !failed.isDirty, failed.draft == changed else { return false }
            controller.open(section: .appearance); controller.appearance.style.setChartMinutes(15); controller.appearance.discard(); controller.closeWithoutConfirmation()
            guard state.style == changed, (try Data(contentsOf: file)) == bytes else { return false }
            controller.open(section: .appearance); controller.appearance.style.setEmail(.masked)
            let draft = controller.appearance.style.draft
            let failingCats = CatStore(rootURL: root, beforeSelectionSave: { throw StyleError.invalid("合成切猫失败") })
            guard (try? failingCats.select("builtin.round", state: state)) == nil,
                  controller.appearance.style.draft == draft, controller.window != nil else { return false }
            try cats.select("builtin.round", state: state)
            return controller.window != nil && state.style == changed && (try? Data(contentsOf: file)) == bytes
        } catch { print("样式窗口生命周期失败：\(error)"); return false }
    }
    static func controls() async -> Bool {
        do {
            let (state, _, controller) = try prepare()
            controller.open(section: .appearance)
            defer { controller.closeWithoutConfirmation() }
            guard let window = controller.window, let model = Optional(controller.appearance.style) else { return false }
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
                  clickControl(window, id: "style.color.claude.pink"), model.draft.color(for: .claude) == .pink,
                  let pick = support.element(window, id: "style.color.claude.pink") as? NSButton, pick.state == .on,
                  resetFromMenu(window, title: "恢复默认样式"), !model.isDirty,
                  clickControl(window, id: "style.color.codex.blue"),
                  clickControl(window, id: "settings.save") else { return false }
            for _ in 0..<50 where controller.appearance.isDirty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard controller.window != nil, !controller.appearance.isDirty,
                  state.style.color(for: .codex) == .blue else { return false }
            controller.open(section: .appearance)
            guard let cancelWindow = controller.window else { return false }
            controller.appearance.style.setEmail(.hidden)
            guard clickControl(cancelWindow, id: "settings.cancel") else { return false }
            support.settle(cancelWindow)
            return controller.window != nil && !model.isDirty && state.style.email == .full
        } catch { print("样式真实控件失败：\(error)"); return false }
    }

    static func colorPreviews() async -> Bool {
        do {
            let (state, _, controller) = try prepare()
            controller.open(section: .appearance)
            defer { controller.closeWithoutConfirmation() }
            guard let window = controller.window, let model = Optional(controller.appearance.style) else { return false }
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
                guard clickControl(window, id: "style.color." + provider.rawValue + "." + color.rawValue) else { return false }
                guard model.draft.color(for: provider) == color, matches(provider, style: model.draft),
                      state.style == .default else { return false }
            }
            try support.capture(window, name: "style-selected-colors")
            guard resetFromMenu(window, title: "恢复默认样式"), !model.isDirty,
                  providers.allSatisfy({ matches($0, style: .default) }) else { return false }
            guard clickControl(window, id: "style.color.claude.pink"), model.isDirty,
                  clickControl(window, id: "settings.cancel"), controller.window != nil else { return false }
            controller.open(section: .appearance)
            guard let reopened = controller.window else { return false }
            support.settle(reopened)
            return state.style == .default && providers.allSatisfy { provider in
                guard let bar = support.element(reopened, id: "style.preview." + provider.rawValue) as? NSBox else { return false }
                return bar.fillColor.usingColorSpace(.sRGB) == QuotaPalette.color(provider).usingColorSpace(.sRGB)
            }
        } catch { print("渠道预览条测试失败：\(error)"); return false }
    }
}
