import AppKit
import MeowMacCore
import MeowMacUI

@MainActor
enum SystemTrendNativeTests {
    static let output = URL(fileURLWithPath: "build/acceptance/system-redesign", isDirectory: true)

    static func capture(_ window: NSWindow, name: String) throws {
        guard ProcessInfo.processInfo.environment["MEOWMAC_SYSTEM_CAPTURE"] == "1" else { return }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let command = Process(); command.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        command.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent(name + ".png").path]
        command.standardOutput = Pipe(); command.standardError = Pipe()
        try command.run(); command.waitUntilExit()
        if command.terminationStatus != 0 { print("原生玻璃截图未完成：\(command.terminationStatus)，保留用户材质验收") }
    }

    static func popover() async -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        let hosting = PanelHosting.make(state: state)
        let anchorWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 100, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        let anchor = NSButton(frame: NSRect(x: 10, y: 10, width: 70, height: 20)); anchor.title = "合成预览"
        anchorWindow.contentView?.addSubview(anchor); anchorWindow.makeKeyAndOrderFront(nil)
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = hosting.controller
        defer { popover.performClose(nil); popover.contentViewController = nil; anchorWindow.close() }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        do {
            let normal = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard popover.isShown, normal.width == 360, normal.height <= 820,
                  let window = hosting.controller.view.window,
                  hosting.measurements.interactionFrames["graph.cpu"] != nil,
                  let diskBottom = hosting.measurements.cardBottoms["system.disk"], diskBottom <= hosting.measurements.viewportHeight else { return false }
            window.acceptsMouseMovedEvents = true
            func tracker(_ kind: String, in view: NSView) -> NSView? {
                if view.identifier?.rawValue == "trend." + kind { return view }
                return view.subviews.lazy.compactMap { tracker(kind, in: $0) }.first
            }
            guard let mouseView = tracker("cpu", in: hosting.controller.view) else { return false }
            for kind in ["cpu", "memory", "power", "temperature", "fan", "disk"] {
                guard let frame = hosting.measurements.interactionFrames["graph." + kind], abs(frame.width - 328) <= 2 else { print("曲线宽度不符：\(kind)"); return false }
            }
            // 向真实曲线的原生 tracking view 分发 NSEvent，不直接设置悬停状态。
            for fraction: CGFloat in [0, 0.5, 1] {
                let point = mouseView.convert(NSPoint(x: min(mouseView.bounds.width - 1, max(1, mouseView.bounds.width * fraction)), y: mouseView.bounds.midY), to: nil)
                guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0) else { return false }
                mouseView.mouseMoved(with: event)
                try await Task.sleep(nanoseconds: 80_000_000)
                guard state.chartHoverKind == "cpu", let date = state.chartHoverDate,
                      abs(date.timeIntervalSince(state.trendDomain.lowerBound) / 900 - Double(fraction)) < 0.01 else {
                    print("原生鼠标悬停未触发：\(state.chartHoverKind ?? "nil")，位置 \(point)"); return false
                }
                let size = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                guard size == normal else { print("悬停改变了面板尺寸"); return false }
            }
            for kind in ["memory", "power", "temperature", "fan", "disk"] {
                guard let view = tracker(kind, in: hosting.controller.view),
                      let event = NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0) else { return false }
                view.mouseMoved(with: event)
                try await Task.sleep(nanoseconds: 80_000_000)
                guard state.chartHoverKind == kind, state.chartHoverPoint != nil,
                      try await PanelPreviewRenderer.settleLayout(hosting.controller) == normal else { return false }
                if kind == "disk" { guard state.diskHoverText.count == 2 else { return false } }
                guard let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil) else { return false }
                view.mouseExited(with: exit)
                guard state.chartHoverDate == nil, state.chartHoverKind == nil else { return false }
            }
            for minutes in [15, 60] {
                state.chartMinutes = minutes
                guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: mouseView.convert(NSPoint(x: mouseView.bounds.width - 0.1, y: mouseView.bounds.midY), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 0, pressure: 0) else { return false }
                mouseView.mouseMoved(with: event)
                guard state.chartHoverPoint?.timestamp == state.snapshot?.timestamp else { print("范围端点选择不符：\(minutes)"); return false }
            }
            try capture(window, name: "native-hover")
            state.chartMinutes = 15
            guard state.chartHoverDate == nil, state.chartHoverKind == nil else { return false }
            for dark in [false, true] {
                popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosting.controller.view.appearance = popover.appearance
                _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                try await Task.sleep(nanoseconds: 100_000_000)
                try capture(window, name: "native-system-" + (dark ? "dark" : "light"))
            }
            let alert = PanelPreviewRenderer.syntheticState(alert: true)
            state.energy = alert.energy; state.snapshot = alert.snapshot; state.fairSince = alert.fairSince
            let warning = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard warning.width == 360, warning.height <= 820,
                  let energyBottom = hosting.measurements.cardBottoms["system.energy"], energyBottom <= hosting.measurements.viewportHeight else { return false }
            print("原生系统面板：正常 \(normal)，提醒 \(warning)；六条曲线 328 pt，原生 tracking 事件、移出、两种范围与悬停尺寸检查通过")
            return true
        } catch { print("系统趋势原生验收失败：\(error)"); return false }
    }

    static func previews() -> Bool {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var cases: [(String, PanelState)] = PanelPreviewRenderer.SensorPreview.allCases.map { ($0.rawValue, PanelPreviewRenderer.sensorState($0)) }
            cases += [("diagnosis", PanelPreviewRenderer.syntheticState(alert: true))]
            let fresh = PanelPreviewRenderer.syntheticState()
            var single = ChartHistory(); single.append(fresh.snapshot!); fresh.chartHistory = single
            cases += [("single", fresh)]
            let empty = PanelPreviewRenderer.syntheticState(); empty.chartHistory = ChartHistory(); cases += [("empty", empty)]
            let partial = PanelPreviewRenderer.syntheticState()
            var history = ChartHistory()
            history.append(SystemTrendTests.snapshot(0)); history.append(SystemTrendTests.snapshot(10, cpu: nil, temperature: nil, available: nil))
            history.append(SystemTrendTests.snapshot(80)); partial.chartHistory = history; partial.snapshot = SystemTrendTests.snapshot(80)
            cases += [("partial", partial)]
            for kind in ["cpu", "temperature", "disk"] {
                let hover = PanelPreviewRenderer.syntheticState()
                hover.chartHoverKind = kind; hover.chartHoverDate = hover.trendDomain.lowerBound.addingTimeInterval(450)
                cases += [("hover-" + kind, hover)]
            }
            for (name, state) in cases {
                for dark in [false, true] {
                    guard let png = PanelPreviewRenderer.systemPagePNG(state: state, dark: dark), let bitmap = NSBitmapImageRep(data: png), bitmap.pixelsWide == 720 else { return false }
                    try png.write(to: output.appendingPathComponent("system-" + name + (dark ? "-dark.png" : "-light.png")))
                }
            }
            let state = PanelPreviewRenderer.syntheticState()
            for (tab, provider, name) in [(PanelTab.quota, QuotaProvider.claude, "quota-claude"), (.quota, .codex, "quota-codex"), (.network, .claude, "network")] {
                state.selectedTab = tab; state.selectedProvider = provider
                for dark in [false, true] {
                    guard let png = PanelPreviewRenderer.png(state: state, dark: dark) else { return false }
                    try png.write(to: output.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
                }
            }
            return true
        } catch { print("系统页合成预览失败：\(error)"); return false }
    }
}
