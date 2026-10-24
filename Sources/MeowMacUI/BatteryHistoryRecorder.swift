import Foundation
import MeowMacCore
import os

/// 记录近 24 小时电量（D44）。挂在系统采样路径上：距上一点满 300 秒或供电状态变化时记一点。
/// 启动后和每次唤醒后的第一个点是段起点，立即记录。睡眠期间不记录。
/// 文件读写都在后台串行队列，失败只记日志。无电池时不建目录、不写文件。
@MainActor
public final class BatteryHistoryRecorder {
    private let store: BatteryHistoryStore
    private let queue = DispatchQueue(label: "io.github.eastcn.meowmac.battery-history", qos: .utility)
    private let logger = Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "battery-history")
    private let update: (BatteryHistory) -> Void
    private var pendingSegmentStart = true
    private var sleeping = false
    /// 本次运行还没写过盘。第一次写入时按内存历史整体重写，顺带清掉过期和坏行。
    private var needsRewrite = true
    private var lastRewrite: Date?
    public private(set) var history: BatteryHistory

    public init(store: BatteryHistoryStore = BatteryHistoryStore(), now: Date = Date(), update: @escaping (BatteryHistory) -> Void) {
        self.store = store
        self.update = update
        history = store.load(now: now)
        update(history)
    }

    /// 每次系统采样调用。
    public func record(_ status: BatteryStatus?, at date: Date) {
        guard !sleeping else { return }
        guard let row = BatteryHistory.nextRecord(status: status, at: date, last: history.last, segmentStart: pendingSegmentStart) else { return }
        pendingSegmentStart = false
        history.append(row, now: date)
        if needsRewrite || (lastRewrite.map { date.timeIntervalSince($0) >= 3600 } ?? true) {
            needsRewrite = false
            lastRewrite = date
            let snapshot = history
            persist { try $0.rewrite(snapshot) }
        } else {
            persist { try $0.append(row) }
        }
        update(history)
    }

    public func sleep() { sleeping = true }

    /// 唤醒后的第一个点标记为段起点，并在下一次采样时立即记录。
    public func wake() {
        sleeping = false
        pendingSegmentStart = true
    }

    /// 等待已排队的写入完成。只供测试使用。
    public func flush() { queue.sync {} }

    private func persist(_ work: @escaping (BatteryHistoryStore) throws -> Void) {
        let store = store, logger = logger
        queue.async {
            do { try work(store) } catch { logger.error("电量历史写入失败：\(error.localizedDescription, privacy: .public)") }
        }
    }
}
