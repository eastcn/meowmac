import AppKit
import MeowMacCore
import MeowMacUI

@MainActor
enum ReminderIntegrationTests {
    private static func captureWindow(_ window: NSWindow, name: String) throws {
        guard ProcessInfo.processInfo.environment["MEOWMAC_ALERT_CAPTURE"] == "1" else { return }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/acceptance/reminder-ui/popover-" + name + ".png")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.path]
        let errors = Pipe(); process.standardError = errors; process.standardOutput = Pipe()
        try process.run(); process.waitUntilExit()
        if process.terminationStatus != 0 {
            print("原生材质截图未完成，继续保留用户视觉验收；退出码 \(process.terminationStatus)")
        }
    }
    static func runtime() -> Bool {
        do {
            let (state, root) = try ReminderUITests.prepare()
            CatRuntime.initialize(state: state, store: CatStore(rootURL: root), environment: [:])
            ReminderUITests.setDisk(state, available: 50)
            let clock = state.now()
            guard let disk = state.allReminders.first(where: { $0.kind == .disk }) else { return false }
            try state.snooze(disk.id, seconds: 3 * 86400)
            for id in CatPackageLoader.builtinIDs {
                try state.catStore?.select(id, state: state)
                let snapshot = PanelSnapshot(state: state)
                guard snapshot.overview.health.level == .normal, snapshot.cat.level == .normal,
                      snapshot.reminders.current.count == 1, snapshot.reminders.snoozed.count == 1,
                      snapshot.reminders.pendingIDs.isEmpty,
                      snapshot.reminders.snoozed.first?.until == clock.addingTimeInterval(3 * 86400) else { return false }
            }
            let restart = PanelState(configResult: state.configResult); restart.now = { clock.addingTimeInterval(4 * 86400) }
            CatRuntime.initialize(state: restart, store: CatStore(rootURL: root), environment: [:])
            // 无须打开面板，到期与猫状态已经生效；未采集不能虚报恢复。
            guard restart.catDisplay().level == .warn, restart.snoozedReminders.isEmpty,
                  restart.allReminders.first?.confirmed == false, ReminderStore(rootURL: root).load().records.isEmpty else { return false }
            ReminderUITests.setDisk(restart, available: 500)
            guard restart.allReminders.isEmpty else { return false }
            let data = try JSONEncoder().encode(PanelSnapshot(state: state))
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["reminders"] != nil
        } catch { print("提醒运行时接入失败：\(error)"); return false }
    }
    static func popover() async -> Bool {
        do {
            let (state, _) = try ReminderUITests.prepare()
            let hosting = PanelHosting.make(state: state)
            let anchorWindow = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 100, height: 40),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
            anchorWindow.isReleasedWhenClosed = false
            let anchor = NSButton(frame: NSRect(x: 10, y: 10, width: 60, height: 20)); anchor.title = "合成预览"
            anchorWindow.contentView?.addSubview(anchor); anchorWindow.makeKeyAndOrderFront(nil)
            let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = hosting.controller
            defer { popover.performClose(nil); popover.contentViewController = nil; anchorWindow.close() }
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            state.showReminders()
            let empty = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard popover.isShown, empty.width == 360, empty.height <= 820, state.allReminders.isEmpty else { return false }
            ReminderUITests.setDisk(state, available: 50)
            state.failures = ["CPU": 2, "内存压力": 2, "磁盘": 2, "电池": 2, "energy": 2]
            for provider in QuotaProvider.defaults {
                state.quotas[provider] = QuotaSnapshot(provider: provider, source: "合成", updatedAt: state.now(),
                    windows: [QuotaWindow(usedPercent: 95, windowMinutes: 300, resetsAt: state.now().addingTimeInterval(3600), resetDescription: nil)], paceSummary: nil, credits: nil)
            }
            let long = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard long.width == 360, long.height == 820, hosting.measurements.contentHeight > hosting.measurements.viewportHeight else { return false }
            // 点击固定筛选，超高内容不挤走标题和筛选。
            if let window = hosting.controller.view.window {
                let point = NSPoint(x: 210, y: window.contentView!.bounds.height - 61)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) { window.sendEvent(event) }
                }
            }
            _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard state.reminderFilter == .quota else { print("弹出面板筛选未触发"); return false }
            try await Task.sleep(nanoseconds: 100_000_000)
            if let window = hosting.controller.view.window { try captureWindow(window, name: "quota") }
            state.reminderFilter = .system
            state.activeSnoozeID = "disk.system"
            let form = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard form.width == 360, form.height <= 820 else { return false }
            try await Task.sleep(nanoseconds: 100_000_000)
            if let window = hosting.controller.view.window { try captureWindow(window, name: "duration") }
            if ProcessInfo.processInfo.environment["MEOWMAC_ALERT_CAPTURE"] == "1" {
                popover.appearance = NSAppearance(named: .aqua)
                hosting.controller.view.appearance = NSAppearance(named: .aqua)
                _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                try await Task.sleep(nanoseconds: 100_000_000)
                if let window = hosting.controller.view.window { try captureWindow(window, name: "duration-light") }
                state.activeSnoozeID = nil; state.reminderFilter = .system
                let process = ProcessEnergy(pid: 501, name: String(repeating: "合成长进程名称", count: 5), cpuPercent: 99, impact: 80)
                state.energy = EnergyDiagnosis(topFive: [process], runaway: [process], longAssertions: [], prolongedMemoryPressure: false)
                _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                try await Task.sleep(nanoseconds: 100_000_000)
                if let window = hosting.controller.view.window { try captureWindow(window, name: "system-light") }
            }
            state.activeSnoozeID = nil; state.showingReminders = false
            state.open()
            guard !state.showingReminders, state.activeSnoozeID == nil else { return false }
            print("真实 NSPopover：空列表 \(empty)，超高列表 \(long)，选择页 \(form)；筛选点击通过")
            return true
        } catch { print("提醒弹出容器失败：\(error)"); return false }
    }
}
