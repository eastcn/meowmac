import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum PanelLayoutUITests {
    private static let root = URL(fileURLWithPath: "build/acceptance/v0-2-layout/tests/panel-app", isDirectory: true)

    private static func prepare(alert: Bool = false) throws -> PanelState {
        let manager = FileManager.default
        try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
        let state = PanelPreviewRenderer.syntheticState(alert: alert)
        CatRuntime.initialize(state: state, store: CatStore(rootURL: root))
        state.readLastTab = { .network }
        state.writeLastTab = { _ in }
        return state
    }

    static func renderingAndSnapshot() -> Bool {
        do {
            let state = try prepare()
            guard Set(PanelCardRegistry.cards.keys) == Set(PanelLayoutCatalog.definitions.values.flatMap { $0.map(\.id) }),
                  state.renderedCardIDs(for: .system) == ["system.chart", "system.energy", "system.disk"],
                  state.renderedCardIDs(for: .quota) == ["quota.trend", "quota.cost", "quota.storage"],
                  state.renderedCardIDs(for: .network) == ["network.checks", "network.sites", "network.traffic", "network.proxy", "network.egress"] else { return false }
            var changed = PanelLayout.default
            changed.tabs = [.network, .system, .quota]
            for tab in PanelTab.allCases { changed.cards[tab.rawValue]?.reverse() }
            // 反转后系统页依次是电池、磁盘、能耗、趋势。隐藏电池和磁盘；合成状态没有电池读数，电池本来也不渲染。
            changed.cards["system"]?[0].visible = false
            changed.cards["system"]?[1].visible = false
            changed.cards["quota"]?[0].visible = false
            changed.cards["network"]?[0].visible = false
            try state.saveLayout(changed, for: "builtin.slim")
            guard state.renderedCardIDs(for: .system) == ["system.energy", "system.chart"],
                  state.renderedCardIDs(for: .quota) == ["quota.cost", "quota.trend"],
                  state.renderedCardIDs(for: .network) == ["network.proxy", "network.traffic", "network.sites", "network.checks"] else { return false }
            let snapshot = PanelSnapshot(state: state)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
            let saved = object["layout"] as! [String: Any]
            guard saved["fallback"] as? Bool == false,
                  try PanelLayout.parse(JSONSerialization.data(withJSONObject: saved["effective"]!)) == changed else { return false }
            state.open()
            guard state.selectedTab == .network else { return false }
            state.networkTone = .red
            state.networkModel = PanelPreviewRenderer.networkModel(failure: true, now: state.now())
            state.open()
            guard state.selectedTab == .network, state.level(for: .network) == .severe,
                  state.health.worst?.tab == .network else { return false }
            for tab in PanelTab.allCases { changed.cards[tab.rawValue] = changed.placements(for: tab).map {
                PanelCardPlacement(id: $0.id, visible: $0.id == "system.chart")
            } }
            try state.saveLayout(changed, for: "builtin.slim")
            guard state.renderedCardIDs(for: .network).isEmpty, state.renderedCardIDs(for: .quota).isEmpty,
                  state.health.worst?.tab == .network else { return false }
            let alert = try prepare(alert: true)
            var hidden = PanelLayout.default
            hidden.cards["system"]?[1].visible = false
            try alert.saveLayout(hidden, for: "builtin.slim")
            return alert.renderedCardIDs(for: .system) == ["system.chart", "system.disk"] && !alert.diagnosisRows.isEmpty
        } catch { print("面板布局渲染测试失败：\(error)"); return false }
    }

    static func sizes() async -> Bool {
        do {
            let state = try prepare()
            let (controller, measurements) = PanelHosting.make(state: state)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = controller
            defer { window.contentViewController = nil }
            state.selectedTab = .system
            let normal = try await PanelPreviewRenderer.settleLayout(controller)
            guard abs(normal.width - 360) < 0.5, normal.height <= 820,
                  abs(normal.height - measurements.fixedHeight - measurements.contentHeight) < 0.5 else { return false }
            var extreme = PanelLayout.default
            extreme.tabs.reverse()
            extreme.cards["system"] = [extreme.placements(for: .system)[2],
                                      extreme.placements(for: .system)[0],
                                      PanelCardPlacement(id: "system.energy", visible: false),
                                      PanelCardPlacement(id: "system.battery", visible: false)]
            extreme.cards["quota"] = extreme.placements(for: .quota).map { PanelCardPlacement(id: $0.id, visible: false) }
            extreme.cards["network"] = extreme.placements(for: .network).map { PanelCardPlacement(id: $0.id, visible: false) }
            try state.saveLayout(extreme, for: "builtin.slim")
            let compact = try await PanelPreviewRenderer.settleLayout(controller)
            guard abs(compact.width - 360) < 0.5, compact.height < normal.height else { return false }
            state.selectedTab = .quota
            let quota = try await PanelPreviewRenderer.settleLayout(controller)
            state.selectedTab = .network
            let network = try await PanelPreviewRenderer.settleLayout(controller)
            print("布局容器尺寸：默认系统 \(normal)，紧凑系统 \(compact)，全隐藏额度 \(quota)，全隐藏网络 \(network)")
            return quota.height <= 820 && network.height <= 820 && quota.width == 360 && network.width == 360
        } catch { print("面板布局尺寸测试失败：\(error)"); return false }
    }

    static func hiddenNetworkIssueClick() async -> Bool {
        do {
            let state = try prepare()
            var layout = PanelLayout.default
            layout.cards["network"]?[0].visible = false
            try state.saveLayout(layout, for: "builtin.slim")
            state.networkModel = PanelPreviewRenderer.networkModel(failure: true, now: state.now())
            state.networkTone = .red
            state.selectedTab = .system
            guard state.health.worst?.tab == .network,
                  !state.renderedCardIDs(for: .network).contains("network.checks") else { return false }
            let hosting = PanelHosting.make(state: state)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = hosting.controller
            defer { window.contentViewController = nil; window.close() }
            let size = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let point = NSPoint(x: 170, y: size.height - 24)
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
                window.sendEvent(event)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            if state.selectedTab != .network {
                print("隐藏网络告警未跳转：当前 \(state.selectedTab)，hit \(String(describing: window.contentView?.hitTest(point)))")
            }
            return state.selectedTab == .network && state.health.worst?.tab == .network
        } catch { print("隐藏网络告警点击失败：\(error)"); return false }
    }
}
