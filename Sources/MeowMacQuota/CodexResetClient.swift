import Foundation
import MeowMacCore
import Security
import os

private final class ResetSessionPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct CodexResetState {
    public var feed: CodexResetFeed?
    public var fetchedAt: Date?
    public var error: String?
    public var cacheError: String?
    public var failures: Int
    public var nextAttemptAt: Date?
    public var manualAvailableAt: Date?
    public var hasResult: Bool { fetchedAt != nil || failures > 0 }
    public var display: CodexResetDisplay {
        CodexResetDisplay(feed: feed, fetchedAt: fetchedAt, error: error, cacheError: cacheError,
            nextAttemptAt: nextAttemptAt, manualAvailableAt: manualAvailableAt)
    }
    public init(feed: CodexResetFeed? = nil, fetchedAt: Date? = nil, error: String? = nil,
                cacheError: String? = nil, failures: Int = 0, nextAttemptAt: Date? = nil, manualAvailableAt: Date? = nil) {
        self.feed = feed; self.fetchedAt = fetchedAt; self.error = error; self.cacheError = cacheError
        self.failures = failures; self.nextAttemptAt = nextAttemptAt; self.manualAvailableAt = manualAvailableAt
    }
}

@MainActor
public final class CodexResetClient {
    public nonisolated static let endpoint = URL(string: "https://aihot.news/api/v1/codex-resets/recent")!
    public nonisolated static let interval: TimeInterval = 6 * 60 * 60
    public nonisolated static let failureInterval: TimeInterval = 15 * 60
    public nonisolated static let manualInterval: TimeInterval = 10 * 60
    public private(set) var state = CodexResetState()
    public private(set) var requesting = false
    private let session: URLSession
    private let store: CodexResetCacheStore
    private var cache = CodexResetCache()
    private let now: () -> Date
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "codex-reset-monitor")
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MeowMac"),
                session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        store = CodexResetCacheStore(root: root); self.now = now
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: configuration, delegate: ResetSessionPolicy(), delegateQueue: nil)
        }
        do {
            if let saved = try store.load() { cache = saved }
            if cache.schedulingVersion == nil {
                // 旧失败缓存没有记录退避来源，原截止时间作为服务端限制保留一次。
                let previousNext = cache.nextAttemptAt
                if cache.failures > 0 || cache.fetchedAt == nil {
                    cache.serverNotBeforeAt = previousNext
                } else if let fetchedAt = cache.fetchedAt {
                    let regularNext = fetchedAt.addingTimeInterval(Self.interval)
                    if let previousNext, previousNext > regularNext { cache.serverNotBeforeAt = previousNext }
                    cache.nextAttemptAt = max(previousNext ?? .distantPast, regularNext)
                    cache.manualNotBeforeAt = fetchedAt.addingTimeInterval(Self.manualInterval)
                }
                cache.schedulingVersion = 2
            }
            state = CodexResetState(feed: try cache.body.map(CodexResetFeed.parse), fetchedAt: cache.fetchedAt,
                error: cache.error, failures: cache.failures, nextAttemptAt: cache.nextAttemptAt,
                manualAvailableAt: manualAvailableAt)
        } catch {
            state.cacheError = "缓存未恢复：" + error.localizedDescription
            logger.error("重置缓存恢复失败：\(error.localizedDescription, privacy: .private)")
        }
    }
    private func persist() {
        do { try store.save(cache); state.cacheError = nil }
        catch {
            state.cacheError = "缓存未保存：" + error.localizedDescription
            logger.error("重置缓存保存失败：\(error.localizedDescription, privacy: .private)")
        }
    }
    private var manualAvailableAt: Date? {
        [cache.manualNotBeforeAt, cache.serverNotBeforeAt].compactMap { $0 }.max()
    }
    private func setNext(_ date: Date) {
        cache.nextAttemptAt = max(date, cache.serverNotBeforeAt ?? .distantPast)
        state.nextAttemptAt = cache.nextAttemptAt
        state.manualAvailableAt = manualAvailableAt
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            let failure = error as NSError
            guard failure.domain == NSURLErrorDomain, failure.code == NSURLErrorSecureConnectionFailed else { throw error }
            let details = [failure, failure.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
            guard details.contains(where: {
                ($0.userInfo["_kCFStreamErrorDomainKey"] as? Int) == 3
                    && ($0.userInfo["_kCFStreamErrorCodeKey"] as? Int) == Int(errSSLClosedNoNotify)
            }) else { throw error }
            // 只恢复未正常关闭的 TLS 连接；证书校验仍由系统处理，不放宽信任。
            let retry = URLSession(configuration: session.configuration, delegate: ResetSessionPolicy(), delegateQueue: nil)
            defer { retry.invalidateAndCancel() }
            return try await retry.data(for: request)
        }
    }

    /// 自动成功后等 6 小时；失败从 15 分钟退避，手动至少等 10 分钟，均尊重服务端限制。
    @discardableResult public func refresh(manual: Bool = false) async -> Bool {
        let deadline = manual ? manualAvailableAt : cache.nextAttemptAt
        guard !Task.isCancelled, !requesting, deadline.map({ now() >= $0 }) ?? true else { return false }
        requesting = true
        defer { requesting = false }
        let started = now()
        cache.schedulingVersion = 2
        cache.serverNotBeforeAt = nil
        cache.manualNotBeforeAt = started.addingTimeInterval(Self.manualInterval)
        // 请求中退出或休眠仍有限频记录，但不会把尚未成功的采集推迟 6 小时。
        setNext(started.addingTimeInterval(Self.failureInterval))
        persist()
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("aihot-api/2.0.0 aihot-actor/" + cache.actorID.uuidString.lowercased(), forHTTPHeaderField: "User-Agent")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if cache.body != nil, let etag = cache.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        var retryAfter: Date?
        do {
            let (data, response) = try await data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  response.url?.scheme == "https", response.url?.host == Self.endpoint.host else {
                throw CodexResetError.invalid("重置接口响应来源无效")
            }
            retryAfter = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: now())
            if response.statusCode == 304 {
                guard cache.body != nil, state.feed != nil else { throw CodexResetError.invalid("接口返回 304，但没有有效缓存") }
            } else if response.statusCode == 200 {
                let feed = try CodexResetFeed.parse(data)
                cache.body = data; state.feed = feed
                cache.etag = nil
            } else { throw CodexResetError.invalid("重置接口返回 HTTP \(response.statusCode)") }
            if let etag = response.value(forHTTPHeaderField: "ETag"), CodexResetCacheStore.validETag(etag) { cache.etag = etag }
            cache.fetchedAt = now(); cache.failures = 0; cache.error = nil
            state.fetchedAt = cache.fetchedAt; state.failures = 0; state.error = nil
            cache.serverNotBeforeAt = retryAfter
            cache.manualNotBeforeAt = now().addingTimeInterval(Self.manualInterval)
            setNext(now().addingTimeInterval(Self.interval))
        } catch {
            cache.serverNotBeforeAt = retryAfter
            cache.manualNotBeforeAt = now().addingTimeInterval(Self.manualInterval)
            if Task.isCancelled {
                setNext(now().addingTimeInterval(Self.failureInterval))
                persist(); return true
            }
            cache.failures = min(cache.failures + 1, 1_000_000)
            cache.error = error.localizedDescription
            state.failures = cache.failures; state.error = cache.error
            let backoff = min(Self.failureInterval * pow(2, Double(min(cache.failures - 1, 5))), Self.interval)
            setNext(now().addingTimeInterval(backoff))
            logger.error("重置监控采集失败：\(error.localizedDescription, privacy: .private)")
        }
        persist()
        return true
    }
    public static func retryDate(_ value: String?, now: Date) -> Date? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        return formatter.date(from: value)
    }
}
