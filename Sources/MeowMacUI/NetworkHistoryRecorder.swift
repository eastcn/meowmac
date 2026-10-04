import Foundation
import MeowMacCore
import TunCanaryCore
import os

/// 把 TunCanary 的站点结果换算成 MeowMac 的分组轮次。
public enum NetworkRoundBuilder {
    static let groups: [(NetworkSiteGroup, Set<SiteGroup>)] = [
        (.mainland, [.mainland]), (.overseas, [.overseas]), (.subnet, [.intranet, .tailnet]),
    ]

    /// 取每个站点最新一次结果。轮次时间是其中最新的检测时间；没有结果时返回空。
    public static func rows(from history: SiteHistory) -> [SiteRoundRecord] {
        let latest = history.results.values.compactMap(\.last)
        guard let time = latest.map(\.checkedAt).max() else { return [] }
        return groups.map { group, included in
            let items = latest.filter { included.contains($0.site.group) }
            let passed = items.filter { !$0.isFailure }
            let latency = NetworkTrend.median(passed.compactMap(\.medianLatency).map { $0 * 1000 })
            return SiteRoundRecord(sampledAt: time, group: group, passed: passed.count, total: items.count, medianMilliseconds: latency)
        }
    }
}

/// 记录站点轮次和速率，写入本机历史。文件读写都在后台串行队列，失败只记日志。
@MainActor
public final class NetworkHistoryRecorder {
    private let store: NetworkHistoryStore
    private let queue = DispatchQueue(label: "io.github.eastcn.meowmac.network-history", qos: .utility)
    private let logger = Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "network-history")
    private var accumulator = TrafficAccumulator()
    private var lastRewrite: Date
    private let update: (NetworkHistory) -> Void
    public private(set) var history: NetworkHistory

    public init(store: NetworkHistoryStore = NetworkHistoryStore(), now: Date = Date(), update: @escaping (NetworkHistory) -> Void) {
        self.store = store
        self.update = update
        history = store.load(now: now)
        history.startedAt = now
        lastRewrite = now
        update(history)
        // 启动时按已裁剪的内存历史重写一次，短时间运行也不会让文件越积越大。
        let loaded = history
        persist { try $0.rewrite(loaded) }
    }

    /// 站点结果变化时调用。同一批次（最新检测时间不变）只记一次。
    public func record(siteHistory: SiteHistory, now: Date) {
        let rows = NetworkRoundBuilder.rows(from: siteHistory)
        guard let time = rows.first?.sampledAt, time > (history.lastSiteRoundAt ?? .distantPast) else { return }
        history.append(sites: rows, now: now)
        persist { try $0.append(sites: rows) }
        finish(now: now)
    }

    /// 每次系统采样调用，满 30 秒写一条。
    public func record(received: Double?, sent: Double?, at date: Date) {
        guard let row = accumulator.add(received: received, sent: sent, at: date) else { return }
        history.append(traffic: row, now: date)
        persist { try $0.append(traffic: row) }
        finish(now: date)
    }

    private func finish(now: Date) {
        if now.timeIntervalSince(lastRewrite) >= 3600 {
            lastRewrite = now
            let snapshot = history
            persist { try $0.rewrite(snapshot) }
        }
        update(history)
    }

    private func persist(_ work: @escaping (NetworkHistoryStore) throws -> Void) {
        let store = store, logger = logger
        queue.async {
            do { try work(store) } catch { logger.error("网络历史写入失败：\(error.localizedDescription, privacy: .public)") }
        }
    }
}
