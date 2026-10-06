import AppKit
import Foundation
import MeowMacCore
import MeowMacSystem
import MeowMacUI

@MainActor
enum AIDiagnosisUITests {
    static func preview() -> Bool {
        let state = PanelPreviewRenderer.syntheticState(alert: true)
        state.aiAgentPreference = .openCode
        var detected = 0, copies: [String] = [], launches = 0
        var installed = [AIAgentInstallation(agent: .codex, location: URL(fileURLWithPath: "/example/codex")),
                         .init(agent: .claudeDesktop, location: URL(fileURLWithPath: "/example/Claude.app"))]
        let controller = AIAgentController(state: state, detect: { detected += 1; return installed },
            findTerminal: { $0 == .ghostty ? URL(fileURLWithPath: "/example/Ghostty.app") : nil },
            launchTerminal: { _, _, _, finish in launches += 1; finish(nil) },
            launchDesktop: { _, _, finish in launches += 1; finish(nil) }, copy: { copies.append($0) },
            prepareDirectory: { _ in }, readLast: { nil }, recordSuccess: { _ in })
        let preview = AIDiagnosisWindowController(controller: controller)
        preview.open(prompt: state.aiDiagnosisPrompt)
        defer { preview.close() }
        guard let window = preview.window else { return false }
        SettingsControlTestSupport.settle(window)
        guard let text = SettingsControlTestSupport.element(window, id: "ai-preview.prompt") as? NSTextView,
              !text.isEditable, text.isSelectable, text.string == state.aiDiagnosisPrompt,
              text.string.contains("ExampleWorker"), text.string.contains("PID：50"),
              let picker = SettingsControlTestSupport.element(window, id: "ai-preview.agent") as? NSPopUpButton,
              picker.itemTitles == ["Codex", "Claude 桌面版"], picker.title == "Codex",
              let cancel = SettingsControlTestSupport.element(window, id: "ai-preview.cancel") as? NSButton,
              let copy = SettingsControlTestSupport.element(window, id: "ai-preview.copy") as? NSButton,
              let launch = SettingsControlTestSupport.element(window, id: "ai-preview.launch") as? NSButton,
              launches == 0, copies.isEmpty, detected == 2 else { return false }
        copy.performClick(nil); guard copies == [text.string] else { return false }
        launch.performClick(nil); guard launches == 1, copies.count == 1 else { return false }
        copies.removeAll(); cancel.performClick(nil)
        guard preview.window == nil, copies.isEmpty, launches == 1 else { return false }
        installed = []; preview.open(prompt: "合成空检测提示词")
        guard let empty = preview.window else { return false }; SettingsControlTestSupport.settle(empty)
        guard SettingsControlTestSupport.element(empty, id: "ai-preview.launch") == nil,
              SettingsControlTestSupport.element(empty, id: "ai-preview.agent") == nil,
              SettingsControlTestSupport.element(empty, id: "ai-preview.cancel") == nil,
              let emptyCopy = SettingsControlTestSupport.element(empty, id: "ai-preview.copy") as? NSButton,
              (SettingsControlTestSupport.element(empty, id: "ai-preview.prompt") as? NSTextView)?.string == "合成空检测提示词" else { return false }
        emptyCopy.performClick(nil); guard copies == ["合成空检测提示词"] else { return false }
        copies.removeAll(); preview.close()
        return copies.isEmpty && launches == 1
    }
    static func entry() async -> Bool {
        let state = PanelPreviewRenderer.syntheticState(alert: true)
        let hosting = PanelHosting.make(state: state)
        let anchorWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        let anchor = NSButton(frame: NSRect(x: 10, y: 10, width: 80, height: 20)); anchor.title = "合成预览"
        anchorWindow.contentView?.addSubview(anchor); anchorWindow.makeKeyAndOrderFront(nil)
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = hosting.controller
        defer { popover.performClose(nil); popover.contentViewController = nil; anchorWindow.close() }
        var opened = 0; state.onAIDiagnosis = { opened += 1 }
        do {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            let size = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard popover.isShown, size.width == 360, size.height <= 820,
                  let window = hosting.controller.view.window,
                  let frame = hosting.measurements.interactionFrames["diagnosis.ai"],
                  let energyBottom = hosting.measurements.cardBottoms["system.energy"], energyBottom <= hosting.measurements.viewportHeight else { return false }
            let view = hosting.controller.view
            let local = NSPoint(x: frame.midX, y: view.isFlipped ? frame.midY : size.height - frame.midY)
            let point = view.convert(local, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
                window.sendEvent(event)
            }
            SettingsControlTestSupport.settle(window)
            guard opened == 1, state.showsAIDiagnosis, state.diagnosisHint == "建议用 AI 诊断" else { print("AI 入口事件未触发：opened=\(opened)，point=\(point)，frame=\(frame)，flipped=\(view.isFlipped)，shown=\(popover.isShown)"); return false }
            state.aiDiagnosisEntry = false
            _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard !state.showsAIDiagnosis, hosting.measurements.interactionFrames["diagnosis.ai"] == nil,
                  state.diagnosisHint == "建议用 AI 诊断：把进程名和数值交给 AI 助手排查" else { return false }
            let thermal = Reminder(kind: .thermal, object: "system", tab: .system, title: "温度偏高，未发现异常进程，建议降温或用 AI 诊断", detail: "热状态 serious", sampledAt: state.now())
            state.energy = EnergyDiagnosis(topFive: [], runaway: [], longAssertions: [], prolongedMemoryPressure: false)
            guard !state.showsAIDiagnosis(for: thermal) else { return false }
            state.aiDiagnosisEntry = true
            guard state.showsAIDiagnosis(for: thermal), state.aiDiagnosisPrompt.contains("没有诊断行") else { return false }
            let snap = state.snapshot!
            state.snapshot = SystemSnapshot(timestamp: snap.timestamp, cpuUsage: snap.cpuUsage, memoryPressure: .normal,
                swapUsedBytes: nil, diskAvailableBytes: nil, diskTotalBytes: nil, networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
                battery: snap.battery, thermal: .serious, sensors: snap.sensors)
            state.showingReminders = true
            _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard let reminder = state.allReminders.first(where: { $0.kind == .thermal }),
                  hosting.measurements.interactionFrames["reminder.ai." + reminder.id] != nil else { return false }
            state.aiDiagnosisEntry = false
            _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            return hosting.measurements.interactionFrames["reminder.ai." + reminder.id] == nil
        } catch { print("AI 入口原生容器测试失败：\(error)"); return false }
    }
    static func screenshots() async -> Bool {
        let capture = ProcessInfo.processInfo.environment["MEOWMAC_AI_CAPTURE"] == "1"
        let bitmap = ProcessInfo.processInfo.environment["MEOWMAC_AI_BITMAP"] == "1"
        guard capture || bitmap else { return true }
        let root = URL(fileURLWithPath: "build/acceptance/ai-agent-launch/previews")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previewState = PanelPreviewRenderer.syntheticState(alert: true)
            let agent = AIAgentController(state: previewState,
                detect: { [.init(agent: .codex, location: URL(fileURLWithPath: "/example/codex"))] },
                readLast: { nil }, recordSuccess: { _ in })
            let preview = AIDiagnosisWindowController(controller: agent)
            preview.open(prompt: AIDiagnosisPrompt.make(rows: previewState.diagnosisRows, snapshot: previewState.snapshot, macOSVersion: "26.5"))
            defer { preview.close() }
            guard let previewWindow = preview.window else { return false }
            for dark in [false, true] {
                previewWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); SettingsControlTestSupport.settle(previewWindow)
                let name = "prompt-" + (dark ? "dark" : "light")
                if bitmap, let view = previewWindow.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + "-cache.png"))
                }
                if capture { try ConfigPreviewCapture.capture(previewWindow, to: root.appendingPathComponent(name + ".png")) }
            }
            preview.close()
            for enabled in [true, false] {
                let state = PanelPreviewRenderer.syntheticState(alert: true); state.aiDiagnosisEntry = enabled
                let hosting = PanelHosting.make(state: state)
                let anchorWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
                anchorWindow.isReleasedWhenClosed = false
                let anchor = NSButton(frame: NSRect(x: 10, y: 10, width: 80, height: 20)); anchorWindow.contentView?.addSubview(anchor)
                anchorWindow.makeKeyAndOrderFront(nil)
                let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = hosting.controller
                defer { popover.performClose(nil); popover.contentViewController = nil; anchorWindow.close() }
                for dark in [false, true] {
                    popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    if !popover.isShown { popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY) }
                    let size = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                    guard size.width == 360, size.height <= 820, let window = hosting.controller.view.window else { return false }
                    SettingsControlTestSupport.settle(window)
                    let name = "system-" + (enabled ? "entry" : "original") + "-" + (dark ? "dark" : "light")
                    print("AI 系统预览：\(name) \(size.width) × \(size.height) pt")
                    if bitmap, let rep = hosting.controller.view.bitmapImageRepForCachingDisplay(in: hosting.controller.view.bounds) {
                        hosting.controller.view.cacheDisplay(in: hosting.controller.view.bounds, to: rep)
                        try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + "-cache.png"))
                    }
                    if capture { try ConfigPreviewCapture.capture(window, to: root.appendingPathComponent(name + ".png")) }
                }
            }
            return true
        } catch { print("AI 系统原生预览失败：\(error)"); return false }
    }
}
