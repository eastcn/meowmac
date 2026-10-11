import Foundation
import MeowMacCore
import MeowMacQuota

final class ResetTestProtocol: URLProtocol {
    struct Reply { let status: Int; var headers: [String: String] = [:]; var data = Data(); var delay: TimeInterval = 0; var error: NSError? }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var recorded: [URLRequest] = []
    private static var recordedTaskIDs: [Int?] = []
    private var stopped = false
    static func prepare(_ values: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = values; recorded = []; recordedTaskIDs = [] }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    static var taskIDs: [Int?] { lock.lock(); defer { lock.unlock() }; return recordedTaskIDs }
    override class func canInit(with request: URLRequest) -> Bool { request.url == CodexResetClient.endpoint }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        Self.recordedTaskIDs.append(task?.taskIdentifier)
        let reply = Self.replies.isEmpty ? Reply(status: 500) : Self.replies.removeFirst()
        Self.lock.unlock()
        func deliver() {
            Self.lock.lock(); let cancelled = stopped; Self.lock.unlock()
            guard !cancelled else { return }
            if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { deliver() } }
        else { deliver() }
    }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }
}

@MainActor
enum CodexResetTests {
    static let clock = ResetDate.parse("2026-10-08T02:00:00Z")!
    static var tests: [(String, @MainActor () async -> Bool)] { [
        ("Core.Reset/字段版本时间与未知状态", { parsing() }),
        ("Core.Reset/预告估算与确认日期排序", { presentation() }),
        ("Core.Reset/最近确认时间不使用过期估算", { confirmedPreview() }),
        ("Core.Reset/确认与预告悬停语义", { detailSemantics() }),
        ("Quota.Reset/200 ETag 304 与重启限频", { await conditional() }),
        ("Quota.Reset/旧缓存切换6小时并保留ETag", { await longerInterval() }),
        ("Quota.Reset/空缓存 304 坏响应与撤回", { await replacement() }),
        ("Quota.Reset/手动并发合并与6小时边界", { await coalescing() }),
        ("Quota.Reset/429 Retry-After 与5xx退避", { await backoff() }),
        ("Quota.Reset/慢失败从返回时起至少等待15分钟", { await slowFailure() }),
        ("Quota.Reset/TLS意外断开新会话重试并保留ETag", { await tlsRecovery() }),
        ("Quota.Reset/TLS连续失败只重试一次且保持限频", { await tlsRetryLimit() }),
        ("Quota.Reset/证书与其他连接错误不重试", { await tlsNoRetry() }),
        ("Quota.Reset/TLS重试后保留HTTP退避与坏响应", { await tlsRetryOutcomes() }),
        ("Quota.Reset/TLS重试遵守任务取消", { await tlsCancellation() }),
        ("Quota.Reset/缓存损坏符号链接与写入失败", { await damagedCache() })
    ] }
    static func event(id: String = "example-pending", status: String = "announced", phase: String = "announced",
                      confirmed: String? = nil, day: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "type": "direct_reset", "status": status,
            "title": "合成重置消息", "displayLabel": "额度重置", "updatedAt": "2026-10-07T18:00:00Z",
            "presentation": ["status": phase, "scopeKnown": true, "scopeLabel": "example paid plan",
                "audienceZh": "示例付费用户", "productsZh": "Codex", "kindExplicit": true, "timeInferred": true],
            "schedule": ["from": "2026-10-08T12:00:00Z", "through": "2026-10-08T14:00:00Z", "label": "示例公告"],
            "estimate": ["from": "2026-10-08T12:00:00Z", "through": "2026-10-08T15:00:00Z", "label": "示例估算"]]
        if let confirmed { value["confirmedAt"] = confirmed }
        if let day { value["occurredOn"] = day }
        return value
    }
    static func data(_ events: [[String: Any]]? = nil) -> Data {
        try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "checkedAt": "2026-10-08T01:55:00.000Z",
            "events": events ?? [event()], "monitor": ["status": "healthy", "lastVerifiedAt": "2026-10-08T01:55:00Z"]])
    }
    static func parsing() -> Bool {
        do {
            let parsed = try CodexResetFeed.parse(data())
            guard parsed.events.count == 1, parsed.checkedAt != nil else { return false }
            var unknown = event(); unknown["presentation"] = NSNull(); unknown["status"] = "future_status"
            let display = CodexResetDisplay(feed: try CodexResetFeed.parse(data([unknown])), fetchedAt: clock, error: nil)
            guard display.pending.count == 1, display.pending[0].status.contains("未知"), display.latest == nil,
                  display.pending[0].scope == "适用范围未说明" else { return false }
            var bad = event(); bad["updatedAt"] = "无效时间"
            var duplicate = event(); duplicate["title"] = "另一个示例"
            var range = event(); range["schedule"] = ["from": "2026-10-08T14:00:00Z", "through": "2026-10-08T12:00:00Z", "label": "倒序"]
            let invalid = [Data("{}".utf8), Data("{\"schemaVersion\":2,\"events\":[]}".utf8), data([bad]), data([event(), duplicate]), data([range]), data([event(day: "2026-02-30")])]
            for body in invalid { if (try? CodexResetFeed.parse(body)) != nil { return false } }
            return true
        } catch { print("重置解析测试：\(error)"); return false }
    }
    static func presentation() -> Bool {
        do {
            let feed = try CodexResetFeed.parse(data([
                event(phase: "likely_completed"),
                event(id: "example-old", status: "confirmed", confirmed: "2026-10-05T23:20:00Z"),
                event(id: "example-new", status: "confirmed", day: "2026-10-07")]))
            let display = CodexResetDisplay(feed: feed, fetchedAt: clock, error: nil, timezone: TimeZone(secondsFromGMT: 28800)!)
            guard display.pending.count == 1, display.pending[0].preview == "估算 10/8 20:00～23:00 · 额度重置", display.pending[0].status == "站点推测已落地 · 尚未确认",
                  display.pending[0].announcement?.contains("10/8 20:00") == true,
                  display.pending[0].announcement?.contains("推断") == true,
                  display.pending[0].estimate?.contains("非官方承诺") == true,
                  display.latest?.id == "example-new", display.latest?.estimate == nil,
                  display.latest?.confirmation == "发生日期：2026-10-07（北京时间）" else { return false }
            for phase in ["announced", "in_progress", "expired_unconfirmed", "confirmed", "new_phase"] {
                let value = CodexResetDisplay(feed: try CodexResetFeed.parse(data([event(phase: phase)])), fetchedAt: clock, error: nil)
                guard value.latest == nil, !value.pending.isEmpty, value.pending[0].confirmation == nil else { return false }
            }
            var noEstimate = event(); noEstimate.removeValue(forKey: "estimate")
            let missing = CodexResetDisplay(feed: try CodexResetFeed.parse(data([noEstimate])), fetchedAt: clock, error: nil)
            guard missing.pending[0].preview == "时间待估算 · 额度重置" else { return false }
            var crossDay = event()
            crossDay["estimate"] = ["from": "2026-10-08T12:00:00Z", "through": "2026-10-09T15:00:00Z", "label": "跨日示例"]
            let cross = CodexResetDisplay(feed: try CodexResetFeed.parse(data([crossDay])), fetchedAt: clock, error: nil, timezone: TimeZone(secondsFromGMT: 28800)!)
            guard cross.pending[0].preview == "估算 10/8 20:00～10/9 23:00 · 额度重置" else { return false }
            crossDay["estimate"] = ["from": "2026-10-08T00:00:00Z", "through": "2026-10-09T00:00:00Z", "label": "10/8 全天", "precision": "date"]
            let dateOnly = CodexResetDisplay(feed: try CodexResetFeed.parse(data([crossDay])), fetchedAt: clock, error: nil)
            guard dateOnly.pending[0].preview == "估算 10/8 全天 · 额度重置" else { return false }
            let empty = try CodexResetFeed.parse(data([]))
            return CodexResetDisplay(feed: nil, fetchedAt: nil, error: nil).headline == "等待首次采集"
                && CodexResetDisplay(feed: empty, fetchedAt: clock, error: nil).headline == "暂无重置预告"
        } catch { return false }
    }
    static func root(_ name: String) throws -> URL {
        let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/codex-reset-monitor/tests")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent.appendingPathComponent(name + "-" + UUID().uuidString)
    }
    static func confirmedPreview() -> Bool {
        do {
            let zone = TimeZone(secondsFromGMT: 28800)!
            for (event, expected) in [
                (event(status: "confirmed", confirmed: "2026-10-07T03:35:00Z"), "10/7 11:35"),
                (event(status: "confirmed", day: "2026-10-07"), "2026-10-07（北京时间）"),
                (event(status: "confirmed"), "确认时间未说明")
            ] {
                let display = CodexResetDisplay(feed: try CodexResetFeed.parse(data([event])), fetchedAt: clock, error: nil, timezone: zone)
                guard display.pending.isEmpty, display.latest?.previewTime == expected,
                      display.latest?.confirmation != nil, display.latest?.estimate == nil else { return false }
            }
            return true
        } catch { return false }
    }
    static func detailSemantics() -> Bool {
        do {
            let feed = try CodexResetFeed.parse(data([event(), event(id: "example-confirmed", status: "confirmed", confirmed: "2026-10-07T03:35:00Z")]))
            let zone = TimeZone(secondsFromGMT: 28800)!
            let display = CodexResetDisplay(feed: feed, fetchedAt: clock, error: nil, timezone: zone)
            let confirmed = display.details(for: display.latest, timezone: zone)
            let pending = display.details(for: display.pending.first, timezone: zone)
            return !confirmed.contains("估算") && !confirmed.contains("非官方承诺")
                && confirmed.contains("公开消息不代表当前账号已到账")
                && confirmed.contains("确认消息：10/7 11:35") && confirmed.contains("已确认")
                && pending.contains("AIHOT 估算，非官方承诺") && pending.contains("尚未确认")
        } catch { return false }
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResetTestProtocol.self]
        return URLSession(configuration: config)
    }
    static func tlsError(_ code: Int = -9816, streamDomain: Int = 3) -> NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "kCFErrorDomainCFNetwork", code: NSURLErrorSecureConnectionFailed,
                userInfo: ["_kCFStreamErrorDomainKey": streamDomain, "_kCFStreamErrorCodeKey": code])])
    }
    static func tlsRecovery() async -> Bool {
        do {
            let root = try root("tls-recovery"), session = session(); var time = clock
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            ResetTestProtocol.prepare([.init(status: 200, headers: ["ETag": "W/\"example-tls\""], data: data()),
                .init(status: 0, error: tlsError()), .init(status: 304, delay: 0.1)])
            let client = CodexResetClient(root: root, session: session, now: { time })
            guard await client.refresh(), client.state.feed != nil else { return false }
            time.addTimeInterval(21_600)
            let refresh = Task { await client.refresh() }
            for _ in 0..<100 {
                if ResetTestProtocol.requests.count == 3 { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard ResetTestProtocol.requests.count == 3, client.requesting, !(await client.refresh()) else { return false }
            guard await refresh.value, client.state.feed != nil, client.state.error == nil,
                  client.state.failures == 0, client.state.fetchedAt == time,
                  client.state.nextAttemptAt == time.addingTimeInterval(21_600) else { return false }
            let requests = ResetTestProtocol.requests
            // taskIdentifier 在同一 session 内唯一；新会话的首次任务重新从 1 开始。
            guard ResetTestProtocol.taskIDs == [1, 2, 1],
                  requests[1].value(forHTTPHeaderField: "If-None-Match") == "W/\"example-tls\"",
                  requests[2].allHTTPHeaderFields == requests[1].allHTTPHeaderFields else { return false }
            let restart = CodexResetClient(root: root, session: session, now: { time })
            guard restart.state.error == nil, restart.state.failures == 0, !(await restart.refresh()) else { return false }
            return ResetTestProtocol.requests.count == 3
        } catch { print("TLS恢复测试：\(error)"); return false }
    }
    static func tlsRetryLimit() async -> Bool {
        do {
            let root = try root("tls-limit"), session = session(); var time = clock
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            ResetTestProtocol.prepare([.init(status: 0, error: tlsError()), .init(status: 0, error: tlsError()),
                .init(status: 200, data: data())])
            let client = CodexResetClient(root: root, session: session, now: { time })
            guard await client.refresh(), ResetTestProtocol.requests.count == 2,
                  client.state.error != nil, client.state.failures == 1,
                  client.state.nextAttemptAt == time.addingTimeInterval(900) else { return false }
            let restart = CodexResetClient(root: root, session: session, now: { time })
            time.addTimeInterval(899)
            guard restart.state.failures == 1, !(await restart.refresh()), ResetTestProtocol.requests.count == 2 else { return false }
            time.addTimeInterval(1)
            return await restart.refresh() && restart.state.error == nil && restart.state.failures == 0
                && ResetTestProtocol.requests.count == 3
        } catch { return false }
    }
    static func tlsNoRetry() async -> Bool {
        for error in [tlsError(-9802), tlsError(streamDomain: 1),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)] {
            do {
                let root = try root("tls-no-retry"), session = session()
                defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
                ResetTestProtocol.prepare([.init(status: 0, error: error), .init(status: 200, data: data())])
                let client = CodexResetClient(root: root, session: session, now: { clock })
                guard await client.refresh(), ResetTestProtocol.requests.count == 1,
                      client.state.error != nil, client.state.failures == 1 else { return false }
            } catch { return false }
        }
        return true
    }
    static func tlsRetryOutcomes() async -> Bool {
        for (reply, wait) in [(ResetTestProtocol.Reply(status: 429, headers: ["Retry-After": "172800"]), 172_800.0),
                              (.init(status: 503), 900.0),
                              (.init(status: 200, data: Data("broken".utf8)), 900.0),
                              (.init(status: 0, error: tlsError(-9802)), 900.0)] {
            do {
                let root = try root("tls-outcome"), session = session()
                defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
                ResetTestProtocol.prepare([.init(status: 0, error: tlsError()), reply, .init(status: 200, data: data())])
                let client = CodexResetClient(root: root, session: session, now: { clock })
                guard await client.refresh(), ResetTestProtocol.requests.count == 2,
                      client.state.failures == 1, client.state.error != nil,
                      client.state.nextAttemptAt == clock.addingTimeInterval(wait) else { return false }
            } catch { return false }
        }
        return true
    }
    static func tlsCancellation() async -> Bool {
        for count in [1, 2] {
            do {
                let root = try root("tls-cancel"), session = session()
                defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
                let delayed = ResetTestProtocol.Reply(status: 0, delay: 0.2, error: tlsError())
                ResetTestProtocol.prepare(count == 1 ? [delayed] : [.init(status: 0, error: tlsError()), delayed])
                let client = CodexResetClient(root: root, session: session, now: { clock })
                let refresh = Task { await client.refresh() }
                for _ in 0..<100 {
                    if ResetTestProtocol.requests.count == count { break }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                let reached = ResetTestProtocol.requests.count == count && client.requesting
                refresh.cancel()
                guard await refresh.value, reached, ResetTestProtocol.requests.count == count,
                      !client.requesting, client.state.failures == 0, client.state.error == nil,
                      client.state.nextAttemptAt == clock.addingTimeInterval(900) else { return false }
            } catch { return false }
        }
        return true
    }
    static func conditional() async -> Bool {
        do {
            let root = try root("conditional"), session = session()
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            var time = clock
            ResetTestProtocol.prepare([.init(status: 200, headers: ["ETag": "W/\"example-v1\""], data: data()), .init(status: 304)])
            let client = CodexResetClient(root: root, session: session, now: { time })
            guard await client.refresh(), client.state.feed != nil else { return false }
            let verified = client.state.feed?.checkedAt
            let restart = CodexResetClient(root: root, session: session, now: { time })
            guard !(await restart.refresh()), restart.state.feed != nil else { return false }
            time = time.addingTimeInterval(21_600)
            guard await restart.refresh(), restart.state.fetchedAt == time,
                  restart.state.feed?.checkedAt == verified, restart.state.failures == 0 else { return false }
            let requests = ResetTestProtocol.requests
            return requests.count == 2 && requests[0].value(forHTTPHeaderField: "If-None-Match") == nil
                && requests[1].value(forHTTPHeaderField: "If-None-Match") == "W/\"example-v1\""
                && requests[0].value(forHTTPHeaderField: "User-Agent") == requests[1].value(forHTTPHeaderField: "User-Agent")
                && requests[0].value(forHTTPHeaderField: "Accept-Encoding") == "gzip"
        } catch { return false }
    }
    static func replacement() async -> Bool {
        do {
            let root = try root("replacement"), session = session(); var time = clock
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            ResetTestProtocol.prepare([.init(status: 304), .init(status: 200, data: data()),
                .init(status: 200, data: Data("broken".utf8)), .init(status: 200, data: data([]))])
            let client = CodexResetClient(root: root, session: session, now: { time })
            _ = await client.refresh()
            guard client.state.feed == nil, client.state.error != nil, client.state.failures == 1 else { return false }
            time.addTimeInterval(21_600); _ = await client.refresh()
            guard client.state.feed?.events.count == 1, client.state.error == nil else { return false }
            time.addTimeInterval(21_600); _ = await client.refresh()
            guard client.state.feed?.events.count == 1, client.state.display.headline.contains("保留上次") else { return false }
            time.addTimeInterval(21_600); _ = await client.refresh()
            return client.state.feed?.events.isEmpty == true && client.state.display.headline == "暂无重置预告"
                && ResetTestProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil }
        } catch { return false }
    }
    static func coalescing() async -> Bool {
        do {
            let root = try root("coalesce"), session = session(); var time = clock
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            ResetTestProtocol.prepare([.init(status: 200, data: data()), .init(status: 200, data: data())])
            let client = CodexResetClient(root: root, session: session, now: { time })
            let first = Task { await client.refresh() }
            await Task.yield()
            let second = await client.refresh(); _ = await first.value
            guard CodexResetClient.interval == 21_600, !second, ResetTestProtocol.requests.count == 1 else { return false }
            time.addTimeInterval(21_599); guard !(await client.refresh()) else { return false }
            time.addTimeInterval(1); return await client.refresh() && ResetTestProtocol.requests.count == 2
        } catch { return false }
    }
    static func backoff() async -> Bool {
        do {
            let root = try root("backoff"), session = session(); var time = clock
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            ResetTestProtocol.prepare([.init(status: 429, headers: ["Retry-After": "1800"]), .init(status: 503),
                .init(status: 503), .init(status: 429, headers: ["Retry-After": "172800"]), .init(status: 200, data: data())])
            let client = CodexResetClient(root: root, session: session, now: { time })
            _ = await client.refresh(); guard client.state.nextAttemptAt == clock.addingTimeInterval(1800) else { return false }
            time.addTimeInterval(1799); guard !(await client.refresh()) else { return false }
            time.addTimeInterval(1); _ = await client.refresh()
            guard client.state.nextAttemptAt == time.addingTimeInterval(1800) else { return false }
            time.addTimeInterval(1800); _ = await client.refresh()
            guard client.state.nextAttemptAt == time.addingTimeInterval(3600) else { return false }
            let restart = CodexResetClient(root: root, session: session, now: { time })
            guard !(await restart.refresh()), restart.state.failures == 3 else { return false }
            time.addTimeInterval(3600); _ = await restart.refresh()
            guard restart.state.nextAttemptAt == time.addingTimeInterval(172_800) else { return false }
            time.addTimeInterval(172_799); guard !(await restart.refresh()) else { return false }
            time.addTimeInterval(1); _ = await restart.refresh()
            return restart.state.failures == 0 && restart.state.error == nil
                && CodexResetClient.retryDate("Thu, 08 Oct 2026 03:00:00 GMT", now: clock) == clock.addingTimeInterval(3600)
        } catch { return false }
    }
    static func longerInterval() async -> Bool {
        do {
            let root = try root("longer-interval"), session = session(); var time = clock
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            ResetTestProtocol.prepare([.init(status: 200, headers: ["ETag": "W/\"example-v1\""], data: data()), .init(status: 304)])
            let client = CodexResetClient(root: root, session: session, now: { time })
            guard await client.refresh() else { return false }
            let file = root.appendingPathComponent("codex-reset-monitor.json")
            var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            saved.removeValue(forKey: "schedulingVersion")
            saved.removeValue(forKey: "manualNotBeforeAt")
            saved.removeValue(forKey: "serverNotBeforeAt")
            saved["nextAttemptAt"] = clock.addingTimeInterval(600).timeIntervalSince1970 * 1000
            try JSONSerialization.data(withJSONObject: saved).write(to: file)
            time.addTimeInterval(600)
            let restart = CodexResetClient(root: root, session: session, now: { time })
            guard restart.state.nextAttemptAt == clock.addingTimeInterval(21_600), !(await restart.refresh()) else { return false }
            time = clock.addingTimeInterval(21_599)
            guard !(await restart.refresh()) else { return false }
            time.addTimeInterval(1)
            return await restart.refresh() && ResetTestProtocol.requests.count == 2
                && ResetTestProtocol.requests[1].value(forHTTPHeaderField: "If-None-Match") == "W/\"example-v1\""
        } catch { return false }
    }
    static func damagedCache() async -> Bool {
        do {
            let root = try root("damaged"), session = session()
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("codex-reset-monitor.json"), original = Data("damaged-cache".utf8)
            try original.write(to: file)
            ResetTestProtocol.prepare([.init(status: 200, data: data()), .init(status: 200, data: data())])
            let client = CodexResetClient(root: root, session: session, now: { clock })
            guard client.state.cacheError != nil else { return false }
            _ = await client.refresh()
            guard client.state.cacheError != nil, client.state.feed != nil, try Data(contentsOf: file) == original else { return false }
            try FileManager.default.removeItem(at: file)
            let sentinel = root.appendingPathComponent("sentinel"); try original.write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sentinel)
            let linked = CodexResetClient(root: root, session: session, now: { clock }); _ = await linked.refresh()
            guard linked.state.cacheError != nil, try Data(contentsOf: sentinel) == original else { return false }
            let badRoot = root.appendingPathComponent("file-root"); try original.write(to: badRoot)
            let failure = CodexResetClient(root: badRoot, session: session, now: { clock })
            let preserved = try Data(contentsOf: badRoot)
            return failure.state.cacheError != nil && preserved == original
        } catch { print("重置缓存测试：\(error)"); return false }
    }
    static func slowFailure() async -> Bool {
        do {
            let root = try root("slow-failure"), session = session(); var time = clock
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
            ResetTestProtocol.prepare([.init(status: 429, delay: 0.1), .init(status: 200, data: data())])
            let client = CodexResetClient(root: root, session: session, now: { time })
            let request = Task { await client.refresh() }
            for _ in 0..<100 where !client.requesting { await Task.yield() }
            guard client.requesting else { return false }
            time.addTimeInterval(30)
            _ = await request.value
            guard client.state.failures == 1, client.state.nextAttemptAt == time.addingTimeInterval(900) else { return false }
            time.addTimeInterval(899)
            guard !(await client.refresh()), ResetTestProtocol.requests.count == 1 else { return false }
            time.addTimeInterval(1)
            return await client.refresh() && ResetTestProtocol.requests.count == 2
        } catch { return false }
    }
}
