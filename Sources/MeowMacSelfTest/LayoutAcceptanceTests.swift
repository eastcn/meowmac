import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum LayoutAcceptanceTests {
    private struct Record: Codable {
        let name: String
        let dark: Bool
        let width: Double
        let height: Double
        let selectedTab: PanelTab
        let renderedIDs: [String]
        let snapshot: PanelLayoutSnapshot
        let issueTab: PanelTab?
    }

    private static func capture(_ view: NSView, to url: URL, background: NSColor? = nil) throws {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PanelLayoutError.invalid("无法捕获原生视图") }
        view.cacheDisplay(in: view.bounds, to: rep)
        let output: NSBitmapImageRep
        if let background {
            guard let flattened = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide,
                                                   pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: flattened) else {
                throw PanelLayoutError.invalid("截图像素格式无效")
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let rect = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
            background.setFill()
            rect.fill()
            rep.draw(in: rect, from: NSRect(origin: .zero, size: rep.size), operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: nil)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            output = flattened
        } else {
            output = rep
        }
        guard let png = output.representation(using: .png, properties: [:]), !png.isEmpty else { throw PanelLayoutError.invalid("原生视图 PNG 为空") }
        try png.write(to: url, options: .atomic)
    }

    private static func state(root: URL, alert: Bool = false, networkFailure: Bool = false) -> PanelState {
        let state = PanelPreviewRenderer.syntheticState(alert: alert)
        CatRuntime.initialize(state: state, store: CatStore(rootURL: root))
        state.readLastTab = { .system }; state.writeLastTab = { _ in }
        if networkFailure {
            state.networkModel = PanelPreviewRenderer.networkModel(failure: true, now: state.now())
            state.networkTone = .red
        }
        return state
    }

    static func render() async -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MEOWMAC_RENDER_DIR"] else { return false }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var records: [Record] = []
            let cases: [(String, PanelTab, Bool, Bool, (inout PanelLayout) -> Void)] = [
                ("default-system", .system, false, false, { _ in }),
                ("default-quota", .quota, false, false, { _ in }),
                ("default-network", .network, false, false, { _ in }),
                ("reorder-system", .system, false, false, { $0.tabs.reverse(); $0.cards["system"]?.reverse() }),
                ("reorder-quota", .quota, false, false, { $0.tabs.reverse(); $0.cards["quota"]?.reverse() }),
                ("reorder-network", .network, false, false, { $0.tabs.reverse(); $0.cards["network"]?.reverse() }),
                ("hide-system", .system, false, false, { $0.cards["system"]?[1].visible = false }),
                ("hide-quota", .quota, false, false, { $0.cards["quota"]?[1].visible = false }),
                ("hide-network", .network, false, false, { $0.cards["network"]?[0].visible = false }),
                ("empty-quota", .quota, false, false, { $0.cards["quota"] = $0.placements(for: .quota).map { .init(id: $0.id, visible: false) } }),
                ("empty-network", .network, false, false, { $0.cards["network"] = $0.placements(for: .network).map { .init(id: $0.id, visible: false) } }),
                ("alert-hidden-energy", .system, true, false, { $0.cards["system"]?[1].visible = false }),
                ("failure-hidden-checks", .network, false, true, { $0.cards["network"]?[0].visible = false }),
            ]
            for (name, tab, alert, networkFailure, change) in cases {
                let root = directory.appendingPathComponent("test-root-" + name, isDirectory: true)
                if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
                let panel = state(root: root, alert: alert, networkFailure: networkFailure)
                var layout = PanelLayout.default; change(&layout)
                if layout != .default { try panel.saveLayout(layout, for: "builtin.slim") }
                panel.selectedTab = tab
                for dark in [false, true] {
                    let hosting = PanelHosting.make(state: panel)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentViewController = hosting.controller
                    window.appearance?.performAsCurrentDrawingAppearance {
                        window.backgroundColor = NSColor.windowBackgroundColor
                        window.contentView?.wantsLayer = true
                        window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    }
                    let size = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                    window.setContentSize(size)
                    guard abs(size.width - 360) < 0.5, size.height <= 820,
                          let view = window.contentView else { return false }
                    var backdrop = NSColor.windowBackgroundColor
                    window.appearance?.performAsCurrentDrawingAppearance {
                        backdrop = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? NSColor.windowBackgroundColor
                    }
                    try capture(view, to: directory.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")),
                                background: backdrop)
                    let snapshot = PanelSnapshot(state: panel)
                    records.append(Record(name: name, dark: dark, width: size.width, height: size.height,
                                          selectedTab: tab, renderedIDs: panel.renderedCardIDs(for: tab),
                                          snapshot: snapshot.layout, issueTab: panel.health.worst?.tab))
                    window.contentViewController = nil
                    window.close()
                }
            }
            let settingsRoot = directory.appendingPathComponent("test-root-settings", isDirectory: true)
            if FileManager.default.fileExists(atPath: settingsRoot.path) { try FileManager.default.removeItem(at: settingsRoot) }
            let settingsState = state(root: settingsRoot)
            let settings = LayoutSettingsController(state: settingsState)
            settings.present()
            guard let settingsWindow = settings.window, let model = settings.model,
                  settingsWindow.contentRect(forFrameRect: settingsWindow.frame).width == 520 else { return false }
            for tab in PanelTab.allCases {
                model.selectedTab = tab
                try capture(settingsWindow.contentView!, to: directory.appendingPathComponent("settings-" + tab.rawValue + ".png"))
            }
            model.moveTab(.network, to: .system)
            model.setVisible(false, id: "network.checks", in: .network)
            model.selectedTab = .network
            try capture(settingsWindow.contentView!, to: directory.appendingPathComponent("settings-draft.png"))
            let longError = String(repeating: "合成保存失败，草稿仍在窗口中；请检查布局目录权限。", count: 8)
            settingsState.layoutStore = PanelLayoutStore(rootURL: settingsRoot, beforePublish: { throw PanelLayoutError.invalid(longError) })
            model.save()
            guard settings.window != nil, model.error != nil else { return false }
            try await Task.sleep(nanoseconds: 200_000_000)
            settingsWindow.contentView?.layoutSubtreeIfNeeded()
            let requiredHeight = settingsWindow.contentView?.fittingSize.height ?? 0
            let actualHeight = settingsWindow.contentRect(forFrameRect: settingsWindow.frame).height
            guard requiredHeight <= 900, actualHeight + 1 >= requiredHeight else {
                print("布局长错误窗口裁切：需要 \(requiredHeight)，实际 \(actualHeight)")
                return false
            }
            try capture(settingsWindow.contentView!, to: directory.appendingPathComponent("settings-save-failure.png"))
            settingsWindow.close()
            let folder = settingsRoot.appendingPathComponent("PanelLayouts", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{broken".utf8).write(to: folder.appendingPathComponent("builtin.slim.json"))
            settingsState.loadLayoutForSelectedCat()
            settings.present()
            guard settings.model?.error != nil, let recoveryWindow = settings.window else { return false }
            try capture(recoveryWindow.contentView!, to: directory.appendingPathComponent("settings-recovery.png"))
            recoveryWindow.close()
            try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("layout-report.json"), options: .atomic)
            print("布局合成验收：\(records.count) 个真实面板容器截图，6 个原生窗口状态；输出 \(directory.path)")
            return records.count == 26
        } catch { print("布局合成验收失败：\(error)"); return false }
    }
}
