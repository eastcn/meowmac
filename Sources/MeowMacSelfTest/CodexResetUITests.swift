import Foundation
import AppKit
import MeowMacCore
import MeowMacQuota
import MeowMacUI

@MainActor
enum CodexResetUITests {
    static var tests: [(String, @MainActor () async -> Bool)] { [
        ("UI.Reset/独立快照与四渠道归属", { snapshots() }),
        ("UI.Reset/后台渲染最近确认与紧凑行", { confirmedRendering() }),
        ("UI.Reset/独立提醒暂缓重启到期与恢复", { reminders() }),
        ("UI.Reset/真实360pt弹出容器与浅深色分节", { await containers() }),
        ("UI.Reset/启停休眠唤醒和手动刷新限频", { await lifecycle() }),
        ("Quota.ResetLive/公开接口单次限频只读", { await live() })
    ] }
    static func snapshots() -> Bool {
        do {
            let state = PanelPreviewRenderer.syntheticState()
            let original = state.quotas[.codex]?.windows.map(\.usedPercent)
            state.codexResetState = CodexResetState(feed: try CodexResetFeed.parse(CodexResetTests.data()), fetchedAt: state.now())
            let snapshot = PanelSnapshot(state: state)
            let codex = snapshot.quota.first { $0.provider == .codex }
            guard codex?.resetMonitor?.pending.count == 1,
                  snapshot.quota.filter({ $0.provider != .codex }).allSatisfy({ $0.resetMonitor == nil }),
                  state.quotas[.codex]?.windows.map(\.usedPercent) == original,
                  state.health.level == .normal else { return false }
            state.quotas.removeValue(forKey: .codex)
            state.quotaErrors[.codex] = "示例账号额度错误"
            return state.channelDisplay(.codex).resetMonitor?.pending.count == 1
                && state.channelDisplay(.codex).windows.isEmpty
        } catch { return false }
    }
    static func reminders() -> Bool {
        do {
            let root = try CodexResetTests.root("reminders")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            var time = CodexResetTests.clock
            let state = PanelState(); state.now = { time }; state.initializeReminders(store: ReminderStore(rootURL: root))
            state.failures["quota.codex-resets"] = state.configResult.config.sourceFailureCount - 1
            guard state.allReminders.isEmpty else { return false }
            state.failures["quota.codex-resets"] = state.configResult.config.sourceFailureCount
            guard let reminder = state.allReminders.first, reminder.id == "source.quota.codex-resets",
                  reminder.tab == .quota, reminder.provider == .codex, reminder.canSnooze,
                  state.health.level == .warn, state.failures["quota.codex"] == nil else { return false }
            try state.snooze(reminder.id, seconds: 600)
            guard state.health.level == .normal else { return false }
            let restart = PanelState(); restart.now = { time }; restart.initializeReminders(store: ReminderStore(rootURL: root))
            guard restart.snoozedReminders.first?.provider == .codex, restart.snoozedReminders.first?.confirmed == false else { return false }
            time.addTimeInterval(600)
            guard restart.health.level == .warn else { return false }
            restart.failures["quota.codex-resets"] = 0
            guard restart.allReminders.isEmpty else { return false }
            state.failures["quota.codex"] = state.configResult.config.sourceFailureCount
            state.failures["quota.codex-resets"] = 0
            return state.allReminders.count == 1 && state.allReminders[0].id == "source.quota.codex"
        } catch { print("重置提醒测试：\(error)"); return false }
    }
    static func containers() async -> Bool {
        do {
            let state = PanelPreviewRenderer.syntheticState(); state.selectedTab = .quota; state.selectedProvider = .codex
            let hosting = PanelHosting.make(state: state)
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 80, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 40)); window.contentView?.addSubview(anchor)
            window.orderFront(nil)
            let popover = NSPopover(); popover.contentViewController = hosting.controller
            defer { popover.performClose(nil); popover.contentViewController = nil; window.close() }
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/codex-reset-monitor/previews")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var noEstimate = CodexResetTests.event(); noEstimate.removeValue(forKey: "estimate")
            var longType = CodexResetTests.event(); longType["displayLabel"] = String(repeating: "示例类型", count: 200)
            var longDate = CodexResetTests.event()
            longDate["estimate"] = ["from": "2026-10-08T00:00:00Z", "through": "2026-10-09T00:00:00Z",
                "label": String(repeating: "示例日期", count: 200), "precision": "date"]
            let cases: [(String, Data?, String?)] = [
                ("pending", CodexResetTests.data(), nil as String?),
                ("empty", CodexResetTests.data([]), nil),
                ("confirmed", CodexResetTests.data([CodexResetTests.event(status: "confirmed", confirmed: "2026-10-07T20:00:00Z")]), nil),
                ("overdue", CodexResetTests.data([CodexResetTests.event(phase: "expired_unconfirmed")]), nil),
                ("failed", CodexResetTests.data(), "示例接口返回 HTTP 503"),
                ("missing-estimate", CodexResetTests.data([noEstimate]), nil),
                ("waiting", nil, nil),
                ("failed-no-cache", nil, "示例接口返回 HTTP 503"),
                ("long-type", CodexResetTests.data([longType]), nil),
                ("long-date", CodexResetTests.data([longDate]), nil)
            ]
            for (name, body, error) in cases {
                state.codexResetState = CodexResetState(feed: try body.map(CodexResetFeed.parse), fetchedAt: body == nil ? nil : CodexResetTests.clock, error: error)
                for dark in [false, true] {
                    hosting.controller.view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let size = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                    guard popover.isShown, size.width == 360, size.height <= 820,
                          hosting.measurements.contentHeight > hosting.measurements.viewportHeight else { return false }
                    guard let image = PanelPreviewRenderer.resetMonitorPNG(state: state, dark: dark),
                          let bitmap = NSBitmapImageRep(data: image) else { return false }
                    // 每条消息仍最多两行、40pt；获取时间和新增加的确认行单独计入。
                    let rowCount = max(1, state.codexResetState.display.pending.count) + (state.codexResetState.display.latest == nil ? 0 : 1)
                    let maximum = CGFloat(rowCount * 40 + (rowCount - 1) * 6 + 18)
                    let sectionHeight = CGFloat(bitmap.pixelsHigh) / 2 - 32
                    guard sectionHeight <= maximum else {
                        print("重置消息占用 \(sectionHeight)pt，超过 \(maximum)pt")
                        return false
                    }
                    try image.write(to: output.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
                }
            }
            print("重置监控：真实 NSPopover 宽 360pt，最大高 820pt；20 张紧凑预告补充预览已生成")
            return true
        } catch { print("重置容器测试：\(error)"); return false }
    }
    static func confirmedRendering() -> Bool {
        do {
            let state = PanelPreviewRenderer.syntheticState()
            let output = URL(fileURLWithPath: "build/acceptance/reset-and-background-validation/previews")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for dark in [false, true] {
                state.codexResetState = CodexResetState(feed: try CodexResetFeed.parse(CodexResetTests.data([])), fetchedAt: CodexResetTests.clock)
                guard let empty = PanelPreviewRenderer.resetMonitorPNG(state: state, dark: dark),
                      let emptyImage = NSBitmapImageRep(data: empty) else { return false }
                var long = CodexResetTests.event(id: "example-long", status: "confirmed", day: "2026-10-07")
                long["displayLabel"] = String(repeating: "合成类型", count: 200)
                let cases: [(String, [[String: Any]], String?)] = [
                    ("confirmed", [CodexResetTests.event(status: "confirmed", confirmed: "2026-10-07T03:35:00Z")], nil),
                    ("both", [CodexResetTests.event(), long], nil),
                    ("cached-long-date", [long], "合成采集失败"),
                    ("missing-time", [CodexResetTests.event(status: "confirmed")], nil)
                ]
                for (name, events, error) in cases {
                    state.codexResetState = CodexResetState(feed: try CodexResetFeed.parse(CodexResetTests.data(events)), fetchedAt: CodexResetTests.clock, error: error)
                    guard let png = PanelPreviewRenderer.resetMonitorPNG(state: state, dark: dark),
                          let image = NSBitmapImageRep(data: png), image.pixelsWide == 720,
                          image.pixelsHigh > emptyImage.pixelsHigh,
                          CGFloat(image.pixelsHigh) / 2 - 32 <= 104 else { return false }
                    try png.write(to: output.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
                }
            }
            return true
        } catch { print("重置消息后台渲染失败：\(error)"); return false }
    }
    static func lifecycle() async -> Bool {
        do {
            let root = try CodexResetTests.root("lifecycle"), session = CodexResetTests.session()
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            var time = CodexResetTests.clock
            ResetTestProtocol.prepare([.init(status: 200, data: CodexResetTests.data()), .init(status: 200, data: CodexResetTests.data([]))])
            let client = CodexResetClient(root: root, session: session, now: { time }), state = PanelState()
            let coordinator = CodexResetCoordinator(state: state, client: client)
            defer { coordinator.stop() }
            coordinator.start()
            for _ in 0..<100 where state.codexResetState.fetchedAt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            guard state.codexResetState.feed?.events.count == 1, ResetTestProtocol.requests.count == 1 else { return false }
            coordinator.refresh(); coordinator.refresh()
            try await Task.sleep(nanoseconds: 20_000_000)
            guard ResetTestProtocol.requests.count == 1 else { return false }
            coordinator.setSleeping(true); time.addTimeInterval(21_600); coordinator.refresh()
            try await Task.sleep(nanoseconds: 20_000_000)
            guard ResetTestProtocol.requests.count == 1 else { return false }
            coordinator.setSleeping(false)
            for _ in 0..<100 where state.codexResetState.feed?.events.isEmpty != true { try await Task.sleep(nanoseconds: 5_000_000) }
            guard ResetTestProtocol.requests.count == 2, state.failures["quota.codex-resets"] == 0 else { return false }
            coordinator.stop(); time.addTimeInterval(21_600); coordinator.refresh()
            try await Task.sleep(nanoseconds: 20_000_000)
            // 启动读取旧的成功缓存不能作为新检测恢复证据。
            let restart = PanelState(); restart.failures["quota.codex-resets"] = 2
            time.addTimeInterval(-21_600)
            let restored = CodexResetCoordinator(state: restart, client: CodexResetClient(root: root, session: session, now: { time }))
            restored.start(); defer { restored.stop() }
            try await Task.sleep(nanoseconds: 20_000_000)
            return ResetTestProtocol.requests.count == 2 && restart.failures["quota.codex-resets"] == 2
                && restart.codexResetState.feed?.events.isEmpty == true
        } catch { return false }
    }
    static func live() async -> Bool {
        guard ProcessInfo.processInfo.environment["MEOWMAC_RESET_LIVE"] == "1" else { print("SKIP 公开重置接口实测"); return true }
        do {
            let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/codex-reset-monitor")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let client = CodexResetClient(root: parent.appendingPathComponent("live"))
            guard await client.refresh() else { print("实测距上次请求未满间隔，已按限频合并"); return client.state.feed != nil }
            print("公开接口：有效快照 \(client.state.feed != nil)，缓存错误 \(client.state.cacheError != nil)，采集错误 \(client.state.error != nil)")
            return client.state.feed != nil && client.state.error == nil && client.state.cacheError == nil
        } catch { print("公开接口实测未完成"); return false }
    }
}
