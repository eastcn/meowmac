import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum LayoutSettingsTests {
    private static let root = URL(fileURLWithPath: "build/acceptance/v0-2-layout/tests/window-app", isDirectory: true)
    private static let manager = FileManager.default

    private static func click(_ window: NSWindow, x: CGFloat, fromBottom y: CGFloat) {
        let point = NSPoint(x: x, y: y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 1, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private static func optionArrow(_ window: NSWindow, code: UInt16, character: String) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil,
                                        characters: character, charactersIgnoringModifiers: character,
                                        isARepeat: false, keyCode: code) {
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private static func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? [] + view.subviews.flatMap(buttons)
    }

    private static func prepare() throws -> (PanelState, CatStore, LayoutSettingsController) {
        try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
        let state = PanelPreviewRenderer.syntheticState()
        let store = CatStore(rootURL: root)
        CatRuntime.initialize(state: state, store: store)
        let controller = LayoutSettingsController(state: state)
        state.onShowLayoutSettings = { controller.present() }
        state.onCatChanged = { controller.catDidChange() }
        return (state, store, controller)
    }

    static func menuAndDraft() -> Bool {
        do {
            let (state, _, controller) = try prepare()
            let menu = SettingsMenu.make(state: state)
            guard let catIndex = menu.items.firstIndex(where: { $0.title == "猫配置" }),
                  menu.items.indices.contains(catIndex + 1),
                  menu.items[catIndex + 1].title == "布局与显示…",
                  menu.items[catIndex + 1].isEnabled,
                  let action = menu.items[catIndex + 1].action else { return false }
            let sent = NSApplication.shared.sendAction(action, to: menu.items[catIndex + 1].target, from: menu.items[catIndex + 1])
            guard sent,
                  let window = controller.window, let model = controller.model,
                  window.contentRect(forFrameRect: window.frame).width == 520,
                  model.catID == "builtin.slim", model.catName == state.selectedCat?.name,
                  !model.isDirty else { return false }
            controller.present()
            guard controller.window === window, controller.model === model else { return false }
            model.moveTab(.network, to: .system)
            model.moveCard("system.disk", to: "system.chart", in: .system)
            model.setVisible(false, id: "system.energy", in: .system)
            model.setVisible(false, id: "system.chart", in: .system)
            guard model.isDirty, model.draft.tabs.first == .network,
                  model.draft.placements(for: .system).map(\.id) == ["system.disk", "system.chart", "system.energy"],
                  model.draft.placements(for: .system)[1].visible,
                  !model.draft.placements(for: .system)[2].visible,
                  state.panelLayout == .default,
                  !manager.fileExists(atPath: root.path) else {
                print("布局草稿状态：\(model.draft.tabs)，\(model.draft.placements(for: .system))，根存在 \(manager.fileExists(atPath: root.path))")
                return false
            }
            model.restoreDefault()
            guard !model.isDirty, model.draft == .default else { return false }
            model.moveTab(.quota, offset: -1)
            model.moveCard("quota.storage", offset: -1, in: .quota)
            guard model.isDirty else { return false }
            model.cancel()
            return controller.window == nil && state.panelLayout == .default
                && !manager.fileExists(atPath: root.path)
        } catch { print("布局窗口草稿测试失败：\(error)"); return false }
    }

    static func saveAndFailure() -> Bool {
        do {
            let (state, store, controller) = try prepare()
            controller.present()
            guard let model = controller.model else { return false }
            model.setVisible(false, id: "quota.cost", in: .quota)
            let draft = model.draft
            model.save()
            guard controller.window == nil, state.panelLayout == draft else { return false }
            let file = root.appendingPathComponent("PanelLayouts/builtin.slim.json")
            let original = try Data(contentsOf: file)
            state.layoutStore = PanelLayoutStore(rootURL: root, beforePublish: { throw PanelLayoutError.invalid("合成保存失败") })
            controller.present()
            guard let failed = controller.model else { return false }
            failed.moveTab(.network, to: .system)
            failed.save()
            guard controller.window != nil, failed.error?.contains("合成保存失败") == true,
                  failed.isDirty, state.panelLayout == draft,
                  (try Data(contentsOf: file)) == original else { return false }
            failed.restoreDefault()
            guard failed.draft == .default, failed.isDirty else { return false }
            controller.window?.close()
            guard controller.window == nil, (try Data(contentsOf: file)) == original else { return false }
            state.layoutStore = PanelLayoutStore(rootURL: root)
            controller.present()
            let next = controller.model!
            next.moveCard("network.egress", to: "network.checks", in: .network)
            let before = next.draft
            let failing = CatStore(rootURL: root, beforeSelectionSave: { throw PanelLayoutError.invalid("合成切换失败") })
            guard (try? failing.select("builtin.round", state: state)) == nil,
                  controller.model === next, next.draft == before,
                  state.selectedCat?.id == "builtin.slim" else { return false }
            try store.select("builtin.round", state: state)
            return controller.window == nil && state.selectedCat?.id == "builtin.round"
                && state.panelLayout == .default && (try? Data(contentsOf: file)) == original
        } catch { print("布局窗口保存测试失败：\(error)"); return false }
    }

    static func dropAndRecovery() async -> Bool {
        do {
            let (state, _, controller) = try prepare()
            controller.present()
            guard let model = controller.model else { return false }
            let provider = NSItemProvider(object: NSString(string: "tab:network"))
            guard model.acceptDrop([provider], kind: "tab", target: "system") else { return false }
            for _ in 0..<50 where model.draft.tabs.first != .network {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard model.draft.tabs.first == .network else { return false }
            model.selectedTab = .network
            let card = NSItemProvider(object: NSString(string: "card:network.egress"))
            guard model.acceptDrop([card], kind: "card", target: "network.checks") else { return false }
            for _ in 0..<50 where model.draft.placements(for: .network).first?.id != "network.egress" {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard model.draft.placements(for: .network).first?.id == "network.egress" else { return false }
            controller.window?.close()
            let folder = root.appendingPathComponent("PanelLayouts", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{broken".utf8).write(to: folder.appendingPathComponent("builtin.slim.json"))
            state.loadLayoutForSelectedCat()
            controller.present()
            guard let recovered = controller.model,
                  recovered.error != nil else { return false }
            recovered.moveTab(.network, to: .system)
            recovered.save()
            return controller.window != nil && recovered.error != nil
                && (try? Data(contentsOf: folder.appendingPathComponent("builtin.slim.json"))) == Data("{broken".utf8)
        } catch { print("布局窗口拖动与恢复测试失败：\(error)"); return false }
    }

    static func actualControls() -> Bool {
        do {
            let (state, _, controller) = try prepare()
            controller.present()
            guard let window = controller.window, let model = controller.model, let view = window.contentView else { return false }
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            let checks = buttons(view)
            guard checks.count == 2 else { print("布局复选框数量：\(checks.count)"); return false }
            let height = view.bounds.height
            click(window, x: 450, fromBottom: height - 262)
            print("复选框后：\(model.draft.placements(for: .system).map(\.visible))，dirty \(model.isDirty)")
            guard model.draft.placements(for: .system)[1].visible == false, model.isDirty else { return false }
            click(window, x: 75, fromBottom: height - 413)
            print("恢复按钮后 dirty \(model.isDirty)")
            guard !model.isDirty else { print("恢复默认按钮未触发"); return false }
            click(window, x: 425, fromBottom: height - 113)
            print("标签页后 \(model.selectedTab)")
            guard model.selectedTab == .network else { print("标签页按钮未触发"); return false }
            optionArrow(window, code: 123, character: "\u{F702}")
            print("快捷键排序后 \(model.draft.tabs)")
            guard model.draft.tabs == [.system, .network, .quota] else { return false }
            let networkChecks = buttons(view)
            print("网络复选框数量 \(networkChecks.count)")
            guard networkChecks.count == 3 else { return false }
            click(window, x: 450, fromBottom: height - 209)
            print("网络显示值 \(model.draft.placements(for: .network).map(\.visible))")
            guard model.draft.placements(for: .network)[0].visible == false else { return false }
            click(window, x: 45, fromBottom: height - 209)
            optionArrow(window, code: 125, character: "\u{F701}")
            guard model.draft.placements(for: .network).map(\.id) == ["network.sites", "network.checks", "network.egress"] else {
                print("功能块快捷键排序未触发：\(model.draft.placements(for: .network).map(\.id))")
                return false
            }
            click(window, x: 475, fromBottom: height - 413)
            guard controller.window == nil, state.panelLayout.placements(for: .network).map(\.id) == ["network.sites", "network.checks", "network.egress"],
                  !state.panelLayout.placements(for: .network)[1].visible else {
                print("保存按钮未触发")
                return false
            }
            controller.present()
            guard let cancelWindow = controller.window, let cancelModel = controller.model, let cancelView = cancelWindow.contentView else { return false }
            cancelModel.setVisible(false, id: "quota.trend", in: .quota)
            click(cancelWindow, x: 420, fromBottom: cancelView.bounds.height - 413)
            return controller.window == nil && state.panelLayout.placements(for: .quota)[0].visible
        } catch { print("布局真实控件测试失败：\(error)"); return false }
    }
}
