import AppKit
import MeowMacCore
import MeowMacUI

@MainActor
enum ReminderUITests {
    static func prepare() throws -> (PanelState, URL) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/acceptance/reminder-ui/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let state = PanelPreviewRenderer.syntheticState()
        state.writeLastTab = { _ in }; state.readLastTab = { .system }
        state.initializeReminders(store: ReminderStore(rootURL: root))
        return (state, root)
    }
    static func setDisk(_ state: PanelState, available: Int64?) {
        state.snapshot = SystemSnapshot(timestamp: state.now(), cpuUsage: 0.24, memoryPressure: .normal, swapUsedBytes: 0,
            diskAvailableBytes: available, diskTotalBytes: 1000, networkReceivedBytesPerSecond: 0,
            networkSentBytesPerSecond: 0, battery: BatteryMetrics(temperatureCelsius: 30, systemPowerWatts: 8), thermal: .nominal)
    }
    static func lifecycle() -> Bool {
        do {
            let (state, root) = try prepare(); setDisk(state, available: 50)
            state.failures["quota.claude"] = 2
            guard let source = state.allReminders.first(where: { $0.kind == .source }), source.provider == .claude,
                  state.reminderDataTime(source) == "待确认 · 没有有效数据时间" else { return false }
            state.failures["quota.claude"] = 0
            guard let disk = state.allReminders.first(where: { $0.kind == .disk }), state.health.level == .warn else { return false }
            let clock = state.now()
            try state.snooze(disk.id, seconds: 2 * 86400)
            guard state.health.level == .normal, state.level(for: .system) == .warn, state.snoozedReminders.count == 1 else { return false }
            state.now = { clock.addingTimeInterval(3600) }
            let restarted = PanelState(configResult: state.configResult); restarted.now = state.now
            restarted.initializeReminders(store: ReminderStore(rootURL: root))
            guard restarted.snoozedReminders.count == 1, restarted.allReminders.first?.confirmed == false,
                  restarted.snoozeDeadline(disk) == clock.addingTimeInterval(2 * 86400) else { return false }
            setDisk(restarted, available: nil)
            guard restarted.snoozedReminders.count == 1 else { return false }
            try restarted.restoreReminder(disk.id)
            guard restarted.health.level == .warn else { return false }
            try restarted.snooze(disk.id, seconds: 3600)
            restarted.now = { clock.addingTimeInterval(7200) }; restarted.refreshReminders()
            guard restarted.health.level == .warn, restarted.snoozedReminders.isEmpty else { return false }
            setDisk(restarted, available: 500)
            setDisk(restarted, available: 50)
            guard restarted.pendingReminders.count == 1 else { return false }
            state.initializeReminders(store: ReminderStore(rootURL: root, beforePublish: { throw SnoozeError.invalid("合成失败") }))
            do { try state.snooze(disk.id, seconds: 3600); return false } catch {}
            guard state.health.level == .warn else { return false }
            let quota = PanelPreviewRenderer.syntheticState(quotaAlert: true)
            quota.writeLastTab = { _ in }
            guard let item = quota.allReminders.first(where: { $0.provider == .codex }) else { return false }
            quota.showReminders(); quota.showReminderDetail(item)
            guard quota.selectedTab == .quota, quota.selectedProvider == .codex, !quota.showingReminders else { return false }
            return SnoozeUnit.hours.duration("4") == 14400 && SnoozeUnit.days.duration("3") == 259200
                && ["", "0", "-1", "1.5", "inf", " 1", "99999999999999999999"].allSatisfy { SnoozeUnit.hours.duration($0) == nil }
                && SnoozeUnit.days.duration("31") == nil
        } catch { print("提醒动作测试失败：\(error)"); return false }
    }
    private static func click(_ window: NSWindow, x: CGFloat, fromTop: CGFloat) -> Bool {
        guard let view = window.contentView else { return false }
        let point = NSPoint(x: x, y: view.bounds.height - fromTop)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
            window.sendEvent(event)
        }
        return true
    }
    private static func capture(_ view: NSView, name: String) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.coderInvalidValue) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
        try bytes.write(to: URL(fileURLWithPath: "build/acceptance/reminder-ui/" + name + ".png"))
    }
    static func nativeControls() async -> Bool {
        do {
            let (state, _) = try prepare(); setDisk(state, available: 50)
            let hosting = PanelHosting.make(state: state)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentViewController = hosting.controller
            defer { window.contentViewController = nil; window.close() }
            window.makeKeyAndOrderFront(nil)
            _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            try await Task.sleep(nanoseconds: 100_000_000)
            guard click(window, x: 60, fromTop: 50) else { return false }
            let list = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            try capture(hosting.controller.view, name: "list")
            guard state.showingReminders, list.width == 360, list.height <= 820,
                  let disk = state.allReminders.first(where: { $0.kind == .disk }) else { return false }
            let rowAction = hosting.measurements.headerHeight + 123
            guard click(window, x: 315, fromTop: rowAction) else { return false }
            let form = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            try capture(hosting.controller.view, name: "duration")
            guard state.activeSnoozeID == disk.id, state.snoozedReminders.isEmpty, form.width == 360, form.height <= 820 else {
                print("时长按钮未打开：header \(hosting.measurements.headerHeight)，点击 \(rowAction)"); return false
            }
            guard click(window, x: 55, fromTop: form.height - hosting.measurements.footerHeight - 23) else { return false }
            _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard state.activeSnoozeID == nil, state.snoozedReminders.isEmpty else { print("取消选择改变了暂缓状态"); return false }
            guard click(window, x: 315, fromTop: hosting.measurements.headerHeight + 123) else { return false }
            _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard click(window, x: 180, fromTop: hosting.measurements.headerHeight + 125) else { return false }
            guard click(window, x: 295, fromTop: form.height - hosting.measurements.footerHeight - 23) else { return false }
            let known = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            try capture(hosting.controller.view, name: "known")
            guard state.activeSnoozeID == nil, state.health.level == .normal, state.snoozeDeadline(disk) == state.now().addingTimeInterval(2 * 86400) else {
                print("两天暂缓按钮未正确保存：\(String(describing: state.snoozeDeadline(disk)))"); return false
            }
            guard click(window, x: 305, fromTop: hosting.measurements.headerHeight + 142) else { return false }
            _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard state.health.level == .warn else { print("恢复按钮未生效"); return false }
            state.networkModel = PanelPreviewRenderer.networkModel(failure: true, now: state.now()); state.networkTone = .red
            let mixed = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            try capture(hosting.controller.view, name: "mixed")
            guard state.health.level == .severe, mixed.height <= 820 else { return false }
            guard state.allReminders.filter({ $0.kind == .network }).allSatisfy({ !$0.canSnooze }), known.width == 360 else { return false }
            print("提醒原生容器：列表 \(list)，选择 \(form)，混合 \(mixed)")
            return true
        } catch { print("提醒原生控件失败：\(error)"); return false }
    }
}
