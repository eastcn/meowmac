import Foundation
import os

/// 一个电量点（D44）。`segmentStart` 为真表示应用启动或系统唤醒后的第一个点，曲线和摘要不跨段（D10）。
public struct BatteryHistoryRecord: Codable, Equatable {
    public let sampledAt: Date
    public let percent: Int
    public let state: BatteryPowerState
    /// 放电功率，W。只在使用电池时记录。
    public let dischargeWatts: Double?
    public let segmentStart: Bool

    public init(sampledAt: Date, percent: Int, state: BatteryPowerState, dischargeWatts: Double? = nil, segmentStart: Bool = false) {
        self.sampledAt = sampledAt.wholeSeconds; self.percent = percent; self.state = state
        self.dischargeWatts = dischargeWatts; self.segmentStart = segmentStart
    }

    enum CodingKeys: String, CodingKey { case sampledAt, percent, state, dischargeWatts, segmentStart }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let percent = try container.decode(Int.self, forKey: .percent)
        guard (0...100).contains(percent) else {
            throw DecodingError.dataCorruptedError(forKey: .percent, in: container, debugDescription: "电量超出 0～100")
        }
        let state = try container.decode(BatteryPowerState.self, forKey: .state)
        guard state != .noBattery else {
            throw DecodingError.dataCorruptedError(forKey: .state, in: container, debugDescription: "无电池不应有电量点")
        }
        let watts = try container.decodeIfPresent(Double.self, forKey: .dischargeWatts)
        sampledAt = try container.decode(Date.self, forKey: .sampledAt)
        self.percent = percent; self.state = state
        dischargeWatts = watts.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        segmentStart = try container.decodeIfPresent(Bool.self, forKey: .segmentStart) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sampledAt, forKey: .sampledAt)
        try container.encode(percent, forKey: .percent)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(dischargeWatts, forKey: .dischargeWatts)
        if segmentStart { try container.encode(true, forKey: .segmentStart) }
    }
}

/// 近 24 小时的用电池摘要（D10）。
public struct BatteryUsageSummary: Equatable {
    /// 用电池的总时长，秒。
    public let batterySeconds: TimeInterval
    /// 这些区间内电量下降之和，百分点。
    public let drainedPercent: Int
    /// 这些区间端点的放电功率均值，W。
    public let averageWatts: Double?
    /// 窗口内最早一个点到现在的时长，秒。没有点时为 0。
    public let recordedSeconds: TimeInterval
    /// 窗口内的记录是否已覆盖近 24 小时。
    public let coversWindow: Bool
    public var hasBatteryUse: Bool { batterySeconds > 0 }
}

/// 内存中的电量历史，只保留最近 24 小时（D4）。
public struct BatteryHistory: Equatable {
    public static let retention: TimeInterval = 86400
    /// 两点相隔不超过这个时长才视为连续（5 分钟加 30 秒余量）。
    public static let maxGap: TimeInterval = 330
    public static let recordInterval: TimeInterval = 300
    public private(set) var records: [BatteryHistoryRecord]

    public init(records: [BatteryHistoryRecord] = []) {
        self.records = records.sorted { $0.sampledAt < $1.sampledAt }
    }

    public var last: BatteryHistoryRecord? { records.last }

    public mutating func append(_ record: BatteryHistoryRecord, now: Date) {
        records.append(record); trim(now: now)
    }

    /// 去掉 24 小时之前和晚于现在 60 秒以上的点。
    public mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention), future = now.addingTimeInterval(60)
        records.removeAll { $0.sampledAt < cutoff || $0.sampledAt > future }
    }

    /// 是否应记一个点：段起点立即记；否则距上一点满 300 秒，或供电状态与上一点不同。
    /// 无电池、没有电量读数或时钟回拨时不记。
    public static func nextRecord(status: BatteryStatus?, at date: Date, last: BatteryHistoryRecord?, segmentStart: Bool) -> BatteryHistoryRecord? {
        guard let status, status.hasBattery, let percent = status.percent, date.timeIntervalSince1970.isFinite else { return nil }
        let record = BatteryHistoryRecord(sampledAt: date, percent: percent, state: status.state,
                                          dischargeWatts: status.state == .battery ? status.powerWatts : nil,
                                          segmentStart: segmentStart || last == nil)
        guard let last else { return record }
        guard record.sampledAt > last.sampledAt else { return nil }
        if segmentStart || record.sampledAt.timeIntervalSince(last.sampledAt) >= recordInterval || record.state != last.state { return record }
        return nil
    }

    /// 相邻两点是否属于同一连续采集段：后一点不是段起点，间隔不超过 330 秒。
    public static func connected(_ a: BatteryHistoryRecord, _ b: BatteryHistoryRecord) -> Bool {
        !b.segmentStart && b.sampledAt > a.sampledAt && b.sampledAt.timeIntervalSince(a.sampledAt) <= maxGap
    }

    /// 窗口 `(now-24h, now]` 内的点，按连续段切开。曲线逐段画线，段与段之间不连线。
    public func segments(now: Date) -> [[BatteryHistoryRecord]] {
        let start = now.addingTimeInterval(-Self.retention)
        var result: [[BatteryHistoryRecord]] = []
        for record in records where record.sampledAt > start && record.sampledAt <= now {
            if let previous = result.last?.last, Self.connected(previous, record) { result[result.count - 1].append(record) }
            else { result.append([record]) }
        }
        return result
    }

    /// 没有记录的时段（D10），曲线在这些时段画斜纹：段与段之间；窗口开头到第一个点、最后一点到现在超过 330 秒的部分。
    public static func missingPeriods(_ segments: [[BatteryHistoryRecord]], domain: ClosedRange<Date>) -> [ClosedRange<Date>] {
        var result: [ClosedRange<Date>] = [], cursor = domain.lowerBound
        for (index, segment) in segments.enumerated() {
            guard let first = segment.first, let last = segment.last else { continue }
            // 窗口开头恰好落在两次记录之间时，不足一个记录间隔的空白不算缺失。
            let leading = index == 0 && first.sampledAt.timeIntervalSince(cursor) <= maxGap
            if first.sampledAt > cursor, !leading { result.append(cursor...first.sampledAt) }
            cursor = max(cursor, last.sampledAt)
        }
        if segments.isEmpty || domain.upperBound.timeIntervalSince(cursor) > maxGap { result.append(cursor...domain.upperBound) }
        return result
    }

    /// 悬停选择：只选距 `date` 不超过 5 分钟的真实样本，规则同磁盘卡片。
    public func selection(at date: Date, now: Date) -> BatteryHistoryRecord? {
        let start = now.addingTimeInterval(-Self.retention)
        guard date.timeIntervalSince1970.isFinite, date >= start, date <= now,
              let nearest = records.filter({ $0.sampledAt > start && $0.sampledAt <= now })
                .min(by: { abs($0.sampledAt.timeIntervalSince(date)) < abs($1.sampledAt.timeIntervalSince(date)) }),
              abs(nearest.sampledAt.timeIntervalSince(date)) <= Self.recordInterval else { return nil }
        return nearest
    }

    /// D10：只统计同一段内相邻两点都在使用电池、间隔不超过 330 秒的区间。
    public func summary(now: Date) -> BatteryUsageSummary {
        var seconds: TimeInterval = 0, drained = 0
        var used: [Date: Double?] = [:]
        let segments = segments(now: now)
        for segment in segments {
            for (a, b) in zip(segment, segment.dropFirst()) where a.state == .battery && b.state == .battery {
                seconds += b.sampledAt.timeIntervalSince(a.sampledAt)
                drained += max(0, a.percent - b.percent)
                used[a.sampledAt] = a.dischargeWatts; used[b.sampledAt] = b.dischargeWatts
            }
        }
        let watts = used.values.compactMap { $0 }
        let first = segments.first?.first?.sampledAt
        let recorded = first.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return BatteryUsageSummary(batterySeconds: seconds, drainedPercent: drained,
                                   averageWatts: watts.isEmpty ? nil : watts.reduce(0, +) / Double(watts.count),
                                   recordedSeconds: recorded, coversWindow: recorded >= Self.retention - Self.maxGap)
    }
}

/// `samples.jsonl`。坏行跳过，超大或读不了的文件当作空历史。
public struct BatteryHistoryStore {
    public static let maxFileBytes = 4 * 1024 * 1024
    public let directory: URL
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "battery-history")

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MeowMac/history/battery", isDirectory: true)) {
        self.directory = directory
    }

    public var file: URL { directory.appendingPathComponent("samples.jsonl") }

    /// 只读，不建目录。
    public func load(now: Date) -> BatteryHistory {
        var history = BatteryHistory(records: read())
        history.trim(now: now)
        return history
    }

    public func append(_ record: BatteryHistoryRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encode([record]))
    }

    /// 用内存中已裁剪的历史整体重写。
    public func rewrite(_ history: BatteryHistory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encode(history.records).write(to: file, options: .atomic)
    }

    private func encode(_ rows: [BatteryHistoryRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try rows.reduce(into: Data()) { data, row in data.append(try encoder.encode(row)); data.append(0x0A) }
    }

    private func read() -> [BatteryHistoryRecord] {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return [] }
        guard size <= Self.maxFileBytes else {
            logger.error("电量历史文件过大，已忽略")
            return []
        }
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var skipped = 0
        let rows = data.split(separator: 0x0A).compactMap { line -> BatteryHistoryRecord? in
            guard let row = try? decoder.decode(BatteryHistoryRecord.self, from: Data(line)) else { skipped += 1; return nil }
            return row
        }
        if skipped > 0 { logger.error("跳过 \(skipped) 行损坏的电量历史") }
        return rows
    }
}
