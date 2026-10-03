import Foundation
import MeowMacCore
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
    public var hasResult: Bool { fetchedAt != nil || failures > 0 }
    public var display: CodexResetDisplay {
        CodexResetDisplay(feed: feed, fetchedAt: fetchedAt, error: error, cacheError: cacheError)
    }
    public init(feed: CodexResetFeed? = nil, fetchedAt: Date? = nil, error: String? = nil,
                cacheError: String? = nil, failures: Int = 0, nextAttemptAt: Date? = nil) {
        self.feed = feed; self.fetchedAt = fetchedAt; self.error = error; self.cacheError = cacheError
        self.failures = failures; self.nextAttemptAt = nextAttemptAt
    }
}

@MainActor
public final class CodexResetClient {
    public nonisolated static let endpoint = URL(string: "https://aihot.news/api/v1/codex-resets/recent")!
    public nonisolated static let interval: TimeInterval = 600
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
            state = CodexResetState(feed: try cache.body.map(CodexResetFeed.parse), fetchedAt: cache.fetchedAt,
                error: cache.error, failures: cache.failures, nextAttemptAt: cache.nextAttemptAt)
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
    private func setNext(_ date: Date) { cache.nextAttemptAt = date; state.nextAttemptAt = date }

    /// 所有入口共用 10 分钟下限，包含手动刷新与重启后的首次刷新。
    @discardableResult public func refresh() async -> Bool {
        guard !requesting, cache.nextAttemptAt.map({ now() >= $0 }) ?? true else { return false }
        requesting = true
        defer { requesting = false }
        let started = now()
        setNext(started.addingTimeInterval(Self.interval))
        persist()
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("aihot-api/2.0.0 aihot-actor/" + cache.actorID.uuidString.lowercased(), forHTTPHeaderField: "User-Agent")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if cache.body != nil, let etag = cache.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        var retryAfter: Date?
        var serverFailure = false
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  response.url?.scheme == "https", response.url?.host == Self.endpoint.host else {
                throw CodexResetError.invalid("重置接口响应来源无效")
            }
            retryAfter = Self.retryDate(response.value(forHTTPHeaderField: "Retry-After"), now: now())
            serverFailure = response.statusCode >= 500
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
        } catch {
            if Task.isCancelled { persist(); return true }
            cache.failures = min(cache.failures + 1, 1_000_000)
            cache.error = error.localizedDescription
            state.failures = cache.failures; state.error = cache.error
            let backoff = serverFailure ? min(Self.interval * pow(2, Double(min(cache.failures, 3))), 3600) : Self.interval
            setNext(max(now().addingTimeInterval(backoff), retryAfter ?? .distantPast))
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
