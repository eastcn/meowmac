import AppKit
import Foundation
import MeowMacCore
import MeowMacSystem
import os

public struct ProxyTrafficViewData: Sendable {
    public var rows: [ProxyTrafficRow]
    public var enabled: Bool
    public var available: Bool
    public var readFailures: Int
    public init(rows: [ProxyTrafficRow] = [], enabled: Bool = true, available: Bool = false, readFailures: Int = 0) {
        self.rows = rows; self.enabled = enabled; self.available = available; self.readFailures = readFailures
    }
}

/// 无定时器的运行逻辑；生产队列与假时钟测试共用采样、恢复和结算路径。
public final class ProxyTrafficSession {
    private let store: ProxyTrafficStoring
    private let client: ProxyTrafficFetching
    private let clock: () -> Date
    private let timeZone: TimeZone
    private let report: (String) -> Void
    private var accumulator: ProxyTrafficAccumulator
    private var checkpointAt: Date?
    private var history: [ProxyTrafficRow]
    public private(set) var enabled: Bool
    public private(set) var sleeping = false
    public private(set) var available = false
    public private(set) var readFailures = 0

    public init(store: ProxyTrafficStoring, client: ProxyTrafficFetching, enabled: Bool = true,
                timeZone: TimeZone = .current, clock: @escaping () -> Date = Date.init,
                report: @escaping (String) -> Void = { _ in }) throws {
        self.store = store; self.client = client; self.enabled = enabled
        self.timeZone = timeZone; self.clock = clock; self.report = report
        if let checkpoint = try store.loadCheckpoint() {
            accumulator = try ProxyTrafficAccumulator(checkpoint: checkpoint, timeZone: timeZone)
        } else { accumulator = ProxyTrafficAccumulator(timeZone: timeZone) }
        history = try store.loadRows(now: clock())
        // 即使控制接口尚未恢复，已结束的检查点小时仍可结算。
        settle(at: clock())
    }
    public func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; accumulator.interruptCoverage(); available = false
        if !value { saveCheckpoint(at: clock()) }
    }
    public func sleep() {
        sleeping = true; accumulator.interruptCoverage(); saveCheckpoint(at: clock())
    }
    public func wake() { sleeping = false; accumulator.interruptCoverage() }
    public func stop() { accumulator.interruptCoverage(); saveCheckpoint(at: clock()) }

    public func sample() {
        guard enabled, !sleeping else { return }
        do {
            let data = try client.fetchConnections()
            let snapshot = try ProxyTrafficSnapshot.parse(data)
            let now = clock()
            try accumulator.accept(snapshot, at: now)
            available = true
            settle(at: now)
            if checkpointAt == nil || now.timeIntervalSince(checkpointAt!) >= 300 { saveCheckpoint(at: now) }
        } catch {
            available = false; readFailures += 1; accumulator.interruptCoverage()
            // 只记类别，不把控制接口响应、socket 路径或连接明细送入日志。
            report("sample_failed")
            settle(at: clock())
        }
    }
    private func saveCheckpoint(at now: Date) {
        do { try store.saveCheckpoint(accumulator.checkpoint()); checkpointAt = now }
        catch { report("checkpoint_failed") }
    }
    private func settle(at now: Date) {
        do {
            let current = ProxyTrafficTime.start(now, timeZone: timeZone)
            let ended = try accumulator.rows().filter { ($0.date ?? .distantFuture) < current }
            guard !ended.isEmpty else { return }
            // 失败时不允许任何小时追加；失败小时保留在内存和检查点中。
            try store.saveCheckpoint(accumulator.checkpoint()); checkpointAt = now
            for row in ended {
                do {
                    try store.append(row)
                    // 已有有效行优先，不用恢复出的旧副本覆盖内存历史。
                    if !history.contains(where: { $0.date == row.date }) { history.append(row) }
                    accumulator.remove(hour: row.hour)
                    do { try store.trim(now: now) } catch { report("retention_failed") }
                } catch { report("append_failed") }
            }
            let cutoff = now.addingTimeInterval(-31 * 86400)
            history.removeAll { ($0.date ?? .distantPast) < cutoff }
        } catch { report("settlement_checkpoint_failed") }
    }
    public func viewData() throws -> ProxyTrafficViewData {
        let now = clock()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        let rows = try history + accumulator.rows()
        var seen = Set<Date>()
        return ProxyTrafficViewData(rows: rows.filter {
            guard let date = $0.date, date >= start, date <= now else { return false }
            return seen.insert(date).inserted
        }.sorted { $0.hour < $1.hour }, enabled: enabled, available: available, readFailures: readFailures)
    }
}

/// 五秒定时器、客户端、计算和磁盘操作都在同一后台队列。面板关闭时不生成展示数据。
@MainActor
public final class ProxyTrafficCoordinator {
    // timer、session 和 visible 只在 queue 上读写；主线程仅持有引用。
    private final class Worker: @unchecked Sendable {
        var timer: DispatchSourceTimer?
        var session: ProxyTrafficSession?
        var visible = false
    }
    private let worker = Worker()
    private let queue = DispatchQueue(label: "io.github.eastcn.meowmac.proxy-traffic", qos: .utility)
    private let config: LocalConfig
    private let update: @MainActor @Sendable (ProxyTrafficViewData) -> Void
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "proxy-traffic")
    public init(config: LocalConfig, update: @escaping @MainActor @Sendable (ProxyTrafficViewData) -> Void) {
        self.config = config; self.update = update
    }
    public func start() {
        let worker = worker, enabled = config.proxyTrafficEnabled, logger = logger, update = update, queue = queue
        queue.async {
            guard worker.timer == nil else { return }
            do {
                let report: (String) -> Void = { event in logger.error("代理流量：\(event, privacy: .public)") }
                let store = ProxyTrafficStore(report: { event, count in
                    logger.error("代理流量历史：\(event, privacy: .public)，行数 \(count)")
                })
                worker.session = try ProxyTrafficSession(store: store, client: ProxyTrafficClient(),
                    enabled: enabled, report: report)
            } catch {
                logger.error("代理流量初始化失败，保留原历史和检查点")
                DispatchQueue.main.async { update(ProxyTrafficViewData(enabled: enabled)) }
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 5, leeway: .milliseconds(100))
            timer.setEventHandler {
                worker.session?.sample()
                guard worker.visible, let session = worker.session else { return }
                do {
                    let value = try session.viewData()
                    DispatchQueue.main.async { update(value) }
                } catch { logger.error("代理流量展示数据生成失败") }
            }
            worker.timer = timer; timer.resume()
        }
    }
    public func setPanelVisible(_ visible: Bool) {
        let worker = worker, update = update, logger = logger
        queue.async {
            worker.visible = visible
            guard visible, let session = worker.session else { return }
            do {
                let value = try session.viewData()
                DispatchQueue.main.async { update(value) }
            } catch { logger.error("代理流量展示数据生成失败") }
        }
    }
    public func sleep() { let worker = worker; queue.async { worker.session?.sleep() } }
    public func wake() { let worker = worker; queue.async { worker.session?.wake() } }
    public func stop() {
        let worker = worker
        queue.sync { worker.timer?.cancel(); worker.timer = nil; worker.session?.stop() }
    }
}
