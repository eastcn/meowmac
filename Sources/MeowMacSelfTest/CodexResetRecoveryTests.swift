import Foundation
import AppKit
import MeowMacUI
import MeowMacCore
import MeowMacQuota

@MainActor
enum CodexResetRecoveryTests {
    static var tests: [(String, @MainActor () async -> Bool)] { [
        ("Quota.ResetRecovery/普通失败15分钟恢复且保留条件缓存", { await recovery() }),
        ("Quota.ResetRecovery/手动10分钟完成边界与重启限频", { await manualRefresh() }),
        ("Quota.ResetRecovery/网络HTTP解析混合失败指数退避上限", { await exponentialFailures() }),
        ("Quota.ResetRecovery/200与304服务端等待限制自动及手动", { await successfulRetryAfter() }),
        ("Quota.ResetRecovery/旧缓存未知退避保留与成功缓存迁移", { await legacySchedule() }),
        ("Quota.ResetRecovery/200替换清除旧ETag且304保留", { await etagReplacement() }),
        ("Quota.ResetRecovery/慢失败和取消保留重启调度", { await slowAndCancelled() }),
        ("UI.ResetRecovery/手动入口与定时休眠隔离", { await coordinator() }),
        ("UI.ResetRecovery/检查与来源核验分离及浅深色渲染", { presentation() })
    ] }
    static func recovery() async -> Bool {
        do {
            let root = try CodexResetTests.root("recovery-contract"), session = CodexResetTests.session()
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            var time = CodexResetTests.clock
            ResetTestProtocol.prepare([.init(status: 200, headers: ["ETag": "W/\"example-recovery\""], data: CodexResetTests.data()),
                .init(status: 0, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)), .init(status: 304)])
            let client = CodexResetClient(root: root, session: session, now: { time })
            guard await client.refresh() else { return false }
            let verified = client.state.display.verifiedAt
            time.addTimeInterval(21_600)
            guard await client.refresh(), client.state.failures == 1, client.state.feed != nil,
                  client.state.nextAttemptAt == time.addingTimeInterval(900) else {
                print("普通失败应在返回后 15 分钟重试，实际仍被旧调度限制")
                return false
            }
            let restart = CodexResetClient(root: root, session: session, now: { time })
            time.addTimeInterval(899)
            guard !(await restart.refresh()) else { return false }
            time.addTimeInterval(1)
            return await restart.refresh() && restart.state.error == nil && restart.state.failures == 0
                && restart.state.display.verifiedAt == verified && restart.state.fetchedAt == time
                && ResetTestProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "W/\"example-recovery\""
        } catch { print("重置恢复测试：\(error)"); return false }
    }

    static func manualRefresh() async -> Bool {
        do {
            let root = try CodexResetTests.root("manual-boundary"), session = CodexResetTests.session()
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            var time = CodexResetTests.clock
            ResetTestProtocol.prepare([.init(status: 200, data: CodexResetTests.data(), delay: 0.1), .init(status: 304)])
            let client = CodexResetClient(root: root, session: session, now: { time })
            let first = Task { await client.refresh() }
            for _ in 0..<100 where !client.requesting { await Task.yield() }
            guard client.requesting, !(await client.refresh(manual: true)) else { return false }
            time.addTimeInterval(30)
            guard await first.value, client.state.nextAttemptAt == time.addingTimeInterval(21_600),
                  client.state.manualAvailableAt == time.addingTimeInterval(600) else { return false }
            let restart = CodexResetClient(root: root, session: session, now: { time })
            time.addTimeInterval(599)
            guard !(await restart.refresh(manual: true)), !(await restart.refresh()) else { return false }
            time.addTimeInterval(1)
            guard !(await restart.refresh()), await restart.refresh(manual: true),
                  restart.state.fetchedAt == time, restart.state.nextAttemptAt == time.addingTimeInterval(21_600) else { return false }
            guard ResetTestProtocol.requests.count == 2 else { return false }
            return !(await restart.refresh(manual: true))
        } catch { return false }
    }

    static func exponentialFailures() async -> Bool {
        do {
            let root = try CodexResetTests.root("failure-cap"), session = CodexResetTests.session()
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            var time = CodexResetTests.clock
            ResetTestProtocol.prepare([.init(status: 0, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)),
                .init(status: 503), .init(status: 429), .init(status: 200, data: Data("invalid".utf8)),
                .init(status: 500), .init(status: 503), .init(status: 502), .init(status: 200, data: CodexResetTests.data())])
            var client = CodexResetClient(root: root, session: session, now: { time })
            for (index, wait) in [900.0, 1800, 3600, 7200, 14400, 21600, 21600].enumerated() {
                guard await client.refresh(), client.state.failures == index + 1,
                      client.state.nextAttemptAt == time.addingTimeInterval(wait),
                      client.state.manualAvailableAt == time.addingTimeInterval(600) else { return false }
                client = CodexResetClient(root: root, session: session, now: { time })
                time.addTimeInterval(wait - 1)
                guard !(await client.refresh()) else { return false }
                time.addTimeInterval(1)
            }
            guard await client.refresh(), client.state.failures == 0, client.state.error == nil,
                  client.state.nextAttemptAt == time.addingTimeInterval(21_600) else { return false }
            // 新一轮失败重新从 15 分钟开始，手动请求可越过本地自动退避。
            ResetTestProtocol.prepare([.init(status: 503), .init(status: 200, data: CodexResetTests.data())])
            time.addTimeInterval(600)
            guard await client.refresh(manual: true), client.state.failures == 1,
                  client.state.nextAttemptAt == time.addingTimeInterval(900) else { return false }
            time.addTimeInterval(600)
            guard !(await client.refresh()) else { return false }
            return await client.refresh(manual: true) && client.state.failures == 0
        } catch { return false }
    }

    static func successfulRetryAfter() async -> Bool {
        do {
            let root = try CodexResetTests.root("successful-wait"), session = CodexResetTests.session()
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            var time = CodexResetTests.clock
            ResetTestProtocol.prepare([.init(status: 200, headers: ["ETag": "W/\"example-cooldown\"", "Retry-After": "172800"], data: CodexResetTests.data()),
                .init(status: 304, headers: ["Retry-After": "86400"]), .init(status: 304)])
            var client = CodexResetClient(root: root, session: session, now: { time })
            for wait in [172_800.0, 86_400] {
                guard await client.refresh(), client.state.failures == 0,
                      client.state.nextAttemptAt == time.addingTimeInterval(wait),
                      client.state.manualAvailableAt == time.addingTimeInterval(wait) else { return false }
                client = CodexResetClient(root: root, session: session, now: { time })
                time.addTimeInterval(wait - 1)
                guard !(await client.refresh()), !(await client.refresh(manual: true)) else { return false }
                time.addTimeInterval(1)
            }
            return await client.refresh(manual: true) && client.state.nextAttemptAt == time.addingTimeInterval(21_600)
                && client.state.manualAvailableAt == time.addingTimeInterval(600)
                && ResetTestProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "W/\"example-cooldown\""
        } catch { return false }
    }

    static func etagReplacement() async -> Bool {
        do {
            let root = try CodexResetTests.root("etag-replacement"), session = CodexResetTests.session()
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            var time = CodexResetTests.clock
            ResetTestProtocol.prepare([.init(status: 200, headers: ["ETag": "W/\"example-old\""], data: CodexResetTests.data()),
                .init(status: 304), .init(status: 200, data: CodexResetTests.data([])),
                .init(status: 200, headers: ["ETag": "W/\"example-new\""], data: CodexResetTests.data()),
                .init(status: 200, headers: ["ETag": String(repeating: "x", count: 513)], data: CodexResetTests.data([])),
                .init(status: 304)])
            let client = CodexResetClient(root: root, session: session, now: { time })
            for _ in 0..<6 {
                guard await client.refresh(manual: true) else { return false }
                time.addTimeInterval(600)
            }
            let headers = ResetTestProtocol.requests.map { $0.value(forHTTPHeaderField: "If-None-Match") }
            return headers == [nil, "W/\"example-old\"", "W/\"example-old\"", nil, "W/\"example-new\"", nil]
                && client.state.feed?.events.isEmpty == true && client.state.error == nil
        } catch { return false }
    }

    static func legacySchedule() async -> Bool {
        for (failures, wait) in [(0, 21_600.0), (0, 172_800), (3, 172_800)] {
            do {
                let root = try CodexResetTests.root("legacy-schedule"), session = CodexResetTests.session()
                defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
                var time = CodexResetTests.clock
                ResetTestProtocol.prepare([.init(status: 200, headers: ["ETag": "W/\"example-legacy\""], data: CodexResetTests.data()), .init(status: 304)])
                let client = CodexResetClient(root: root, session: session, now: { time })
                guard await client.refresh() else { return false }
                let file = root.appendingPathComponent("codex-reset-monitor.json")
                var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                for key in ["schedulingVersion", "manualNotBeforeAt", "serverNotBeforeAt"] { saved.removeValue(forKey: key) }
                saved["failures"] = failures
                if failures > 0 { saved["error"] = "合成旧失败" }
                saved["nextAttemptAt"] = time.addingTimeInterval(wait).timeIntervalSince1970 * 1000
                try JSONSerialization.data(withJSONObject: saved).write(to: file)
                let restored = CodexResetClient(root: root, session: session, now: { time })
                let manualWait = wait == 21_600 ? 600.0 : wait
                time.addTimeInterval(manualWait - 1)
                guard !(await restored.refresh()), !(await restored.refresh(manual: true)) else { return false }
                time.addTimeInterval(1)
                guard await restored.refresh(manual: true), restored.state.failures == 0,
                      restored.state.manualAvailableAt == time.addingTimeInterval(600),
                      restored.state.feed != nil, ResetTestProtocol.requests.count == 2,
                      ResetTestProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "W/\"example-legacy\"" else { return false }
            } catch { return false }
        }
        return true
    }

    static func slowAndCancelled() async -> Bool {
        for cancelled in [false, true] {
            do {
                let root = try CodexResetTests.root("slow-or-cancel"), session = CodexResetTests.session()
                defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
                var time = CodexResetTests.clock
                ResetTestProtocol.prepare([.init(status: 429, headers: ["Retry-After": "7200"], delay: 0.1), .init(status: 200, data: CodexResetTests.data())])
                let client = CodexResetClient(root: root, session: session, now: { time })
                let attempt = Task { await client.refresh() }
                for _ in 0..<100 where !client.requesting { await Task.yield() }
                guard client.requesting else { return false }
                time.addTimeInterval(30)
                if cancelled { attempt.cancel() }
                guard await attempt.value else { return false }
                let wait = cancelled ? 900.0 : 7200.0
                let manualWait = cancelled ? 600.0 : 7200.0
                guard client.state.nextAttemptAt == time.addingTimeInterval(wait),
                      client.state.manualAvailableAt == time.addingTimeInterval(manualWait),
                      client.state.failures == (cancelled ? 0 : 1) else { return false }
                let restored = CodexResetClient(root: root, session: session, now: { time })
                time.addTimeInterval(manualWait - 1)
                guard !(await restored.refresh()), !(await restored.refresh(manual: true)) else { return false }
                time.addTimeInterval(1)
                // 取消可能发生在 URLProtocol 收到请求前；重置合成队列，避免把未消费响应误作恢复。
                ResetTestProtocol.prepare([.init(status: 200, data: CodexResetTests.data())])
                guard await restored.refresh(manual: true), restored.state.error == nil else { return false }
            } catch { return false }
        }
        return true
    }

    static func coordinator() async -> Bool {
        do {
            let root = try CodexResetTests.root("manual-coordinator"), session = CodexResetTests.session()
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            var time = CodexResetTests.clock
            ResetTestProtocol.prepare([.init(status: 200, data: CodexResetTests.data()), .init(status: 304)])
            let client = CodexResetClient(root: root, session: session, now: { time }), state = PanelState()
            let coordinator = CodexResetCoordinator(state: state, client: client)
            defer { coordinator.stop() }
            coordinator.start()
            for _ in 0..<100 where state.codexResetState.fetchedAt == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            guard state.codexResetState.fetchedAt == time else { return false }
            time.addTimeInterval(600)
            coordinator.refresh()
            try await Task.sleep(nanoseconds: 20_000_000)
            guard ResetTestProtocol.requests.count == 1 else { return false }
            coordinator.setSleeping(true); coordinator.refresh(manual: true)
            try await Task.sleep(nanoseconds: 20_000_000)
            guard ResetTestProtocol.requests.count == 1 else { return false }
            coordinator.setSleeping(false)
            try await Task.sleep(nanoseconds: 20_000_000)
            coordinator.refresh(manual: true)
            for _ in 0..<100 where state.codexResetState.fetchedAt != time { try await Task.sleep(nanoseconds: 5_000_000) }
            return ResetTestProtocol.requests.count == 2 && state.codexResetState.fetchedAt == time
                && state.codexResetState.nextAttemptAt == time.addingTimeInterval(21_600)
        } catch { return false }
    }

    static func presentation() -> Bool {
        do {
            var object = try JSONSerialization.jsonObject(with: CodexResetTests.data()) as! [String: Any]
            object["monitor"] = ["status": "attention", "lastVerifiedAt": "2026-10-07T01:00:00Z"]
            let feed = try CodexResetFeed.parse(JSONSerialization.data(withJSONObject: object))
            let state = PanelPreviewRenderer.syntheticState(), time = CodexResetTests.clock
            state.codexResetState = CodexResetState(feed: feed, fetchedAt: time, nextAttemptAt: time.addingTimeInterval(900), manualAvailableAt: time.addingTimeInterval(600))
            let display = state.codexResetState.display, zone = TimeZone(secondsFromGMT: 28800)!
            guard display.timingSummary(timezone: zone) == "检查 10/8 10:00 · 下次 10/8 10:15",
                  display.siteStatus == "站点采集待核验", display.verifiedAt == ResetDate.parse("2026-10-07T01:00:00Z"),
                  display.details(for: nil, timezone: zone).contains("站点核验：10/7 09:00"),
                  display.details(for: nil, timezone: zone).contains("最早手动检查：10/8 10:10") else { return false }
            let output = URL(fileURLWithPath: "build/acceptance/backlog-fixes/reset")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for dark in [false, true] {
                guard let data = PanelPreviewRenderer.resetMonitorPNG(state: state, dark: dark),
                      let image = NSBitmapImageRep(data: data), image.pixelsWide == 720,
                      CGFloat(image.pixelsHigh) / 2 - 32 <= 76 else { return false }
                try data.write(to: output.appendingPathComponent(dark ? "timing-dark.png" : "timing-light.png"))
            }
            return true
        } catch { return false }
    }
}
