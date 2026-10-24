import AppKit
import Foundation
import SwiftUI
import MeowMacCore
import MeowMacUI

@MainActor
enum LayoutSettingsTests {
    private static let root = URL(fileURLWithPath: "build/acceptance/v0-2-layout/tests/window-app", isDirectory: true)
    private static let manager = FileManager.default

    private static func click(_ window: NSWindow, x: CGFloat, fromBottom y: CGFloat) {
        let point = NSPoint(x: x, y: y)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return }
        // 原生控件可能在 mouseDown 中等 mouseUp，先将抬起事件放入队列。
        NSApplication.shared.postEvent(up, atStart: true)
        window.sendEvent(down)
        while let event = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            window.sendEvent(event)
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

    private static func prepare() throws -> (PanelState, CatStore, SettingsWindowController) {
        try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
        let state = PanelPreviewRenderer.syntheticState()
        let store = CatStore(rootURL: root)
        CatRuntime.initialize(state: state, store: store)
        let controller = SettingsWindowController(state: state)
        state.onOpenSettings = { controller.open(section: $0) }
        state.onCatChanged = { controller.catDidChange() }
        return (state, store, controller)
    }

    static func menuAndDraft() -> Bool {
        do {
            let (state, _, controller) = try prepare()
            defer { controller.closeWithoutConfirmation() }
            controller.open(section: .appearance)
            guard let window = controller.window, let model = controller.appearance.layout,
                  window.contentRect(forFrameRect: window.frame).width == 760,
                  model.catID == "builtin.slim", model.catName == state.selectedCat?.name,
                  !model.isDirty else { return false }
            controller.open(section: .appearance)
            guard controller.window === window, controller.appearance.layout === model else { return false }
            model.moveTab(.network, to: .system)
            model.moveCard("system.disk", to: "system.chart", in: .system)
            model.setVisible(false, id: "system.energy", in: .system)
            model.setVisible(false, id: "system.chart", in: .system)
            guard model.isDirty, model.draft.tabs.first == .network,
                  model.draft.placements(for: .system).map(\.id) == ["system.disk", "system.chart", "system.energy", "system.battery"],
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
            guard !model.isDirty else { return false }
            return controller.window != nil && state.panelLayout == .default
                && !manager.fileExists(atPath: root.path)
        } catch { print("布局窗口草稿测试失败：\(error)"); return false }
    }

    static func saveAndFailure() -> Bool {
        do {
            let (state, store, controller) = try prepare()
            defer { controller.closeWithoutConfirmation() }
            controller.open(section: .appearance)
            guard let model = controller.appearance.layout else { return false }
            model.setVisible(false, id: "quota.cost", in: .quota)
            let draft = model.draft
            model.save()
            guard controller.window != nil, state.panelLayout == draft else { return false }
            let file = root.appendingPathComponent("PanelLayouts/builtin.slim.json")
            let original = try Data(contentsOf: file)
            state.layoutStore = PanelLayoutStore(rootURL: root, beforePublish: { throw PanelLayoutError.invalid("合成保存失败") })
            controller.open(section: .appearance)
            guard let failed = controller.appearance.layout else { return false }
            failed.moveTab(.network, to: .system)
            failed.save()
            guard controller.window != nil, failed.error?.contains("合成保存失败") == true,
                  failed.isDirty, state.panelLayout == draft,
                  (try Data(contentsOf: file)) == original else { return false }
            failed.restoreDefault()
            guard failed.draft == .default, failed.isDirty else { return false }
            controller.closeWithoutConfirmation()
            guard controller.window == nil, (try Data(contentsOf: file)) == original else { return false }
            state.layoutStore = PanelLayoutStore(rootURL: root)
            controller.open(section: .appearance)
            let next = controller.appearance.layout!
            next.moveCard("network.egress", to: "network.checks", in: .network)
            let before = next.draft
            let failing = CatStore(rootURL: root, beforeSelectionSave: { throw PanelLayoutError.invalid("合成切换失败") })
            guard (try? failing.select("builtin.round", state: state)) == nil,
                  controller.appearance.layout === next, next.draft == before,
                  state.selectedCat?.id == "builtin.slim" else { return false }
            try store.select("builtin.round", state: state)
            return controller.window != nil && controller.appearance.layout?.catID == "builtin.round" && state.selectedCat?.id == "builtin.round"
                && state.panelLayout == .default && (try? Data(contentsOf: file)) == original
        } catch { print("布局窗口保存测试失败：\(error)"); return false }
    }

    static func dropAndRecovery() async -> Bool {
        do {
            let (state, _, controller) = try prepare()
            defer { controller.closeWithoutConfirmation() }
            controller.open(section: .appearance)
            guard let model = controller.appearance.layout else { return false }
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
            controller.appearance.discard()
            controller.closeWithoutConfirmation()
            let folder = root.appendingPathComponent("PanelLayouts", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{broken".utf8).write(to: folder.appendingPathComponent("builtin.slim.json"))
            state.loadLayoutForSelectedCat()
            controller.open(section: .appearance)
            guard let recovered = controller.appearance.layout,
                  recovered.error != nil else { return false }
            recovered.moveTab(.network, to: .system)
            recovered.save()
            return controller.window != nil && recovered.error != nil
                && (try? Data(contentsOf: folder.appendingPathComponent("builtin.slim.json"))) == Data("{broken".utf8)
        } catch { print("布局窗口拖动与恢复测试失败：\(error)"); return false }
    }

    static func actualControls() async -> Bool {
        do {
            let (state, _, controller) = try prepare()
            defer { controller.closeWithoutConfirmation() }
            controller.open(section: .appearance)
            guard let window = controller.window, let model = controller.appearance.layout, let view = window.contentView else { print("布局真实控件：统一窗口或布局模型缺失"); return false }
            func checks() -> [NSButton] { buttons(view).filter { !($0 is NSPopUpButton) && $0.accessibilityIdentifier().isEmpty } }
            func point(_ button: NSButton) -> NSPoint {
                button.scrollToVisible(button.bounds)
                SettingsControlTestSupport.settle(window)
                return button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            }
            func check(_ index: Int) {
                let p = point(checks()[index]); click(window, x: p.x, fromBottom: p.y)
            }
            SettingsControlTestSupport.settle(window)
            try SettingsControlTestSupport.capture(window, name: "layout-default")
            guard checks().count == 7 else { print("布局复选框数量：\(checks().count)"); return false }
            let pickers = buttons(view).compactMap { $0 as? NSPopUpButton }
            guard pickers.count == 2, let provider = pickers.first(where: { $0.title == "Claude" }) else { print("布局真实控件：额度下拉数量或默认渠道错误：\(pickers.map(\.title))"); return false }
            guard let providerItem = provider.item(withTitle: "Codex"), let providerAction = providerItem.action,
                  NSApplication.shared.sendAction(providerAction, to: providerItem.target, from: providerItem) else {
                print("渠道菜单动作未发送"); return false
            }
            SettingsControlTestSupport.settle(window)
            guard model.draft.overview.quota.provider == .codex, state.panelLayout.overview.quota.provider == .claude else { print("渠道未应用：\(model.draft.overview.quota.provider)"); return false }
            guard let quotaWindow = buttons(view).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.title != "Codex" }),
                  quotaWindow.itemTitles.contains("自动") else { print("布局真实控件：窗口下拉缺少自动项"); return false }
            guard let windowItem = quotaWindow.item(withTitle: "自动"), let windowAction = windowItem.action,
                  NSApplication.shared.sendAction(windowAction, to: windowItem.target, from: windowItem) else {
                print("窗口菜单动作未发送"); return false
            }
            SettingsControlTestSupport.settle(window)
            guard model.draft.overview.quota.window == "auto" else { print("窗口未应用：\(model.draft.overview.quota.window)"); return false }
            model.restoreDefault()
            SettingsControlTestSupport.settle(window)
            check(0); check(1); check(2)
            guard model.draft.overview.visible == [.network], !checks()[3].isEnabled,
                  state.panelLayout == .default else { print("布局真实控件：可见格或末格禁用错误：\(model.draft.overview.visible)，末格启用 \(checks()[3].isEnabled)"); return false }
            model.restoreDefault()
            guard !model.isDirty else { print("默认按钮未触发"); return false }
            let cpu = point(checks()[0])
            // SwiftUI 的滚动宿主 frame 不含侧栏绘制偏移，用同栏原生表单的外框定位共享左边界。
            guard let preview = SettingsControlTestSupport.element(window, id: "style.preview.claude") as? NSView else {
                print("布局真实控件：同栏样式表单定位锚点缺失"); return false
            }
            var container = preview.superview
            while container != nil && !(container is NSBox) { container = container?.superview }
            guard let formBox = container as? NSBox else {
                print("布局真实控件：同栏样式表单外框缺失"); return false
            }
            let formBounds = formBox.convert(formBox.bounds, to: nil)
            let handleCenter = formBounds.minX + 8 + 15
            click(window, x: handleCenter, fromBottom: cpu.y)
            optionArrow(window, code: 125, character: "\u{F701}")
            guard model.draft.overview.order == [.memory, .cpu, .quota, .network] else {
                print("总览快捷键未触发：\(model.draft.overview.order)"); return false
            }
            let energy = point(checks()[4])
            check(4)
            guard !model.draft.placements(for: .system)[1].visible else { print("布局真实控件：系统能耗复选框未隐藏卡片"); return false }
            let networkTabCenter = formBounds.minX + formBounds.width * 5 / 6
            click(window, x: networkTabCenter, fromBottom: energy.y + 149)
            guard model.selectedTab == .network else { print("网络标签未触发"); return false }
            optionArrow(window, code: 123, character: "\u{F702}")
            guard model.draft.tabs == [.system, .network, .quota], checks().count == 9 else { print("布局真实控件：标签快捷键或网络复选框数量错误：\(model.draft.tabs)，数量 \(checks().count)"); return false }
            check(4)
            let network = point(checks()[4])
            click(window, x: handleCenter, fromBottom: network.y)
            optionArrow(window, code: 125, character: "\u{F701}")
            guard model.draft.placements(for: .network).map(\.id) == ["network.sites", "network.checks", "network.traffic", "network.proxy", "network.egress"] else { print("布局真实控件：网络卡片快捷键未排序：\(model.draft.placements(for: .network).map(\.id))"); return false }
            guard await controller.appearance.save() else { print("布局真实控件：外观保存失败：\(controller.appearance.statusText)"); return false }
            guard controller.window != nil, state.panelLayout.overview.order == [.memory, .cpu, .quota, .network],
                  !state.panelLayout.placements(for: .network)[1].visible else { print("布局真实控件：保存后业务布局与草稿不一致"); return false }
            controller.open(section: .appearance)
            guard let cancelWindow = controller.window, let cancelModel = controller.appearance.layout else { print("布局真实控件：取消前窗口或布局模型丢失"); return false }
            cancelModel.setVisible(false, id: "quota.trend", in: .quota)
            controller.appearance.discard()
            SettingsControlTestSupport.settle(cancelWindow)
            return controller.window != nil && state.panelLayout.placements(for: .quota)[0].visible
        } catch { print("布局真实控件测试失败：\(error)"); return false }
    }

    static func overview() async -> Bool {
        do {
            let (state, _, controller) = try prepare()
            defer { controller.closeWithoutConfirmation() }
            controller.open(section: .appearance)
            guard let model = controller.appearance.layout else { return false }
            let drop = NSItemProvider(object: NSString(string: "overview:network"))
            guard model.acceptDrop([drop], kind: "overview", target: "cpu") else { return false }
            for _ in 0..<50 where model.draft.overview.order.first != .network {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard model.draft.overview.order.first == .network else { return false }
            model.setOverviewProvider(.codex)
            guard model.quotaWindowOptions.contains(where: { $0.selector == "minutes:10080" }) else { return false }
            model.setOverviewWindow("minutes:10080")
            model.setOverviewProvider(.deepseek)
            guard model.draft.overview.quota.window == "auto" else { return false }
            model.setOverviewWindow("minutes:10080")
            model.setOverviewProvider(.deepseek)
            guard model.draft.overview.quota.window == "minutes:10080",
                  model.quotaWindowOptions.contains(where: { $0.selector == "minutes:10080" }) else { return false }
            state.quotas.removeAll()
            guard model.quotaWindowOptions.map(\.selector) == ["auto", "minutes:10080"],
                  model.overviewPreview.first(where: { $0.item == .quota })?.value == "—",
                  state.panelLayout == .default else { return false }
            model.save()
            let file = root.appendingPathComponent("PanelLayouts/builtin.slim.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            return controller.window != nil && state.panelLayout.overview.quota.window == "minutes:10080"
                && (object["layout"] as? [String: Any])?["schemaVersion"] as? Int == 2
        } catch { print("总览窗口测试失败：\(error)"); return false }
    }

    static func snapshotArrival() -> Bool {
        do {
            let (state, _, controller) = try prepare()
            defer { controller.closeWithoutConfirmation() }
            let snapshot = state.snapshot
            let quotas = state.quotas
            state.snapshot = nil; state.quotas = [:]
            var saved = PanelLayout.default
            saved.overview.quota.window = "minutes:10080"
            try state.saveLayout(saved, for: "builtin.slim")
            controller.open(section: .appearance)
            guard let window = controller.window, let model = controller.appearance.layout,
                  let view = window.contentView else { return false }
            let support = SettingsControlTestSupport.self
            support.settle(window)
            func picker() -> NSPopUpButton? {
                buttons(view).compactMap { $0 as? NSPopUpButton }.first { $0.title != "Claude" }
            }
            func renderedContent() -> Data? {
                guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
                view.cacheDisplay(in: view.bounds, to: image)
                return image.representation(using: .png, properties: [:])
            }
            guard picker()?.itemTitles == ["自动", "已保存 · minutes:10080"],
                  model.overviewPreview.first(where: { $0.item == .quota })?.value == "—" else { return false }
            model.moveOverview(.network, to: .cpu)
            model.setOverviewVisible(false, item: .memory)
            support.settle(window)
            let draft = model.draft
            if let control = buttons(view).filter({ !($0 is NSPopUpButton) && $0.accessibilityIdentifier().isEmpty }).dropFirst(3).first { control.scrollToVisible(control.bounds.insetBy(dx: 0, dy: -160)) }
            support.settle(window)
            guard let before = renderedContent() else { return false }
            // 此时下拉与草稿不变，系统快照只能改变总览预览。
            state.snapshot = snapshot
            support.settle(window)
            guard let after = renderedContent(), after != before,
                  model.overviewPreview.first(where: { $0.item == .cpu })?.value == "24%" else {
                print("系统快照到达后预览渲染未更新"); return false
            }
            state.quotas = quotas
            support.settle(window)
            guard picker()?.itemTitles == ["自动", "5 小时窗口", "7 天窗口"],
                  picker()?.title == "7 天窗口",
                  model.overviewPreview.first(where: { $0.item == .quota })?.value == "62%",
                  model.draft == draft, state.panelLayout == saved else {
                print("额度到达后未刷新：\(picker()?.itemTitles ?? [])")
                return false
            }
            state.quotas = [:]; state.snapshot = nil
            support.settle(window)
            guard picker()?.title == "已保存 · minutes:10080",
                  model.overviewPreview.first(where: { $0.item == .quota })?.value == "—",
                  model.draft == draft else { print("快照暂缺未保留：\(picker()?.title ?? "nil")"); return false }
            // 渠道切换走原生菜单动作；同渠道数据暂缺继续保留选择。
            guard let provider = buttons(view).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.title == "Claude" }),
                  let item = provider.item(withTitle: "Codex"), let action = item.action,
                  NSApplication.shared.sendAction(action, to: item.target, from: item) else { return false }
            support.settle(window)
            guard model.draft.overview.quota.provider == .codex,
                  model.draft.overview.quota.window == "auto" else { return false }
            state.quotas = quotas
            support.settle(window)
            return model.draft.overview.quota.window == "auto" && state.panelLayout == saved
        } catch { print("快照到达测试失败：\(error)"); return false }
    }

    static func overviewColors() -> Bool {
        do {
            let (state, _, controller) = try prepare()
            defer { controller.closeWithoutConfirmation() }
            controller.open(section: .appearance)
            guard let model = controller.appearance.layout else { return false }
            for (tone, expected) in [(NetworkTone.gray, NSColor.systemGray), (.green, .systemGreen),
                                     (.yellow, .systemOrange), (.red, .systemRed)] {
                state.networkTone = tone
                guard let metric = model.overviewPreview.first(where: { $0.item == .network }),
                      model.overviewColor(for: metric) == Color(nsColor: expected),
                      state.overviewColor(for: metric) == Color(nsColor: expected) else {
                    print("网络预览与面板色不一致：\(tone)"); return false
                }
            }
            state.networkTone = .gray
            model.moveOverview(.network, to: .cpu)
            model.setOverviewVisible(false, item: .memory)
            guard model.overviewPreview.map(\.item) == [.network, .cpu, .quota] else { return false }
            for metric in model.overviewPreview {
                let expected: NSColor = metric.item == .network ? .systemGray
                    : metric.item == .cpu ? .systemBlue : .systemGreen
                guard model.overviewColor(for: metric) == Color(nsColor: expected),
                      state.overviewColor(for: metric) == Color(nsColor: expected) else { return false }
            }
            model.setOverviewVisible(true, item: .memory)
            state.snapshot = SystemSnapshot(timestamp: state.now(), cpuUsage: 0.24, memoryPressure: .warn,
                swapUsedBytes: nil, diskAvailableBytes: nil, diskTotalBytes: nil,
                networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
                battery: BatteryMetrics(temperatureCelsius: nil, systemPowerWatts: nil), thermal: .nominal)
            guard let memory = model.overviewPreview.first(where: { $0.item == .memory }) else { return false }
            return model.overviewColor(for: memory) == Color(nsColor: .systemOrange)
                && state.overviewColor(for: memory) == Color(nsColor: .systemOrange)
                && state.panelLayout == .default
        } catch { print("总览颜色测试失败：\(error)"); return false }
    }

    /// 布局设置的“本机没有电池”提示（R5）。SwiftUI 列表行的文字不在 AppKit 辅助功能树里，窗口里取不到，
    /// 所以离线断言两件事：显示条件对四种快照的结果，以及源码里文案和条件没有被改动。
    static func noBatteryNote() -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        func snapshot(_ status: BatteryStatus?) -> SystemSnapshot {
            SystemSnapshot(timestamp: state.now(), cpuUsage: 0.2, memoryPressure: .normal,
                swapUsedBytes: nil, diskAvailableBytes: nil, diskTotalBytes: nil,
                networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
                battery: BatteryMetrics(temperatureCelsius: nil, systemPowerWatts: nil, status: status), thermal: .nominal)
        }
        // 与 LayoutSettings.swift 里的条件同一个表达式。
        func showsNote(_ status: BatteryStatus?) -> Bool {
            state.snapshot = snapshot(status)
            return state.snapshot?.battery.status?.hasBattery == false
        }
        state.snapshot = nil
        let noSnapshot = state.snapshot?.battery.status?.hasBattery == false
        guard showsNote(.noBattery), !showsNote(BatteryStatus(state: .battery, percent: 62)),
              !showsNote(BatteryStatus(state: .acNotCharging, percent: 80)), !showsNote(nil), !noSnapshot else {
            print("无电池提示条件错误"); return false
        }
        guard let source = try? String(contentsOfFile: "Sources/MeowMacUI/LayoutSettings.swift", encoding: .utf8),
              source.contains("if placement.id == \"system.battery\", state.snapshot?.battery.status?.hasBattery == false {"),
              source.contains("Text(\"本机没有电池\")") else {
            print("无电池提示的文案或条件与断言不一致"); return false
        }
        return true
    }
}
