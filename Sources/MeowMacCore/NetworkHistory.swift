import Foundation
import os

/// 站点分组。子网目标合并内网和 Tailnet。
public enum NetworkSiteGroup: String, Codable, CaseIterable {
    case mainland, overseas, subnet
    public var title: String {
        switch self { case .mainland: return "国内"; case .overseas: return "海外"; case .subnet: return "子网目标" }
    }
}

/// 一轮站点探测中一个分组的结果。延迟只取成功站点，全部失败时为空。
public struct SiteRoundRecord: Codable, Equatable {
    public let sampledAt: Date
    public let group: NetworkSiteGroup
    public let passed: Int
    public let total: Int
    public let medianMilliseconds: Double?
    public init(sampledAt: Date, group: NetworkSiteGroup, passed: Int, total: Int, medianMilliseconds: Double?) {
        self.sampledAt = sampledAt.wholeSeconds; self.group = group; self.passed = passed; self.total = total
        self.medianMilliseconds = medianMilliseconds
    }
    public var failed: Bool { total > 0 && passed < total }
    public var allFailed: Bool { total > 0 && passed == 0 }
}

extension Date {
    /// 历史按 ISO 8601 存到秒，记录时先取整，读回后才能和内存中的值一致。
    var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

/// 30 秒内上下行速率的均值和峰值，单位为每秒字节。
public struct TrafficRecord: Codable, Equatable {
    public let sampledAt: Date
    public let receivedAverage: Double, sentAverage: Double
    public let receivedPeak: Double, sentPeak: Double
    public init(sampledAt: Date, receivedAverage: Double, sentAverage: Double, receivedPeak: Double, sentPeak: Double) {
        self.sampledAt = sampledAt.wholeSeconds; self.receivedAverage = receivedAverage; self.sentAverage = sentAverage
        self.receivedPeak = receivedPeak; self.sentPeak = sentPeak
    }
}

/// 把 2 秒一次的速率样本累计成 30 秒一条。样本间隔超过 10 秒（休眠、卡顿）时丢弃未满的窗口。
public struct TrafficAccumulator {
    public static let windowSeconds: TimeInterval = 30
    static let maxGap: TimeInterval = 10
    private var start: Date?
    private var last: Date?
    private var received: [Double] = []
    private var sent: [Double] = []
    public init() {}

    public mutating func add(received rx: Double?, sent tx: Double?, at date: Date) -> TrafficRecord? {
        guard let rx, let tx, rx.isFinite, tx.isFinite, rx >= 0, tx >= 0 else { return nil }
        if let last, date.timeIntervalSince(last) > Self.maxGap || date < last { reset() }
        if start == nil { start = date }
        last = date
        received.append(rx); sent.append(tx)
        guard let start, date.timeIntervalSince(start) >= Self.windowSeconds else { return nil }
        let record = TrafficRecord(sampledAt: date, receivedAverage: received.reduce(0, +) / Double(received.count),
            sentAverage: sent.reduce(0, +) / Double(sent.count), receivedPeak: received.max() ?? 0, sentPeak: sent.max() ?? 0)
        reset()
        return record
    }

    private mutating func reset() { start = nil; last = nil; received = []; sent = [] }
}

/// 内存中的网络历史，只保留最近 24 小时。
public struct NetworkHistory: Equatable {
    public static let retention: TimeInterval = 86400
    public private(set) var sites: [SiteRoundRecord] = []
    public private(set) var traffic: [TrafficRecord] = []
    /// 本次运行开始记录的时刻，用于判断“较早时段暂无记录”。
    public var startedAt: Date?
    public init(sites: [SiteRoundRecord] = [], traffic: [TrafficRecord] = [], startedAt: Date? = nil) {
        self.sites = sites.sorted { $0.sampledAt < $1.sampledAt }
        self.traffic = traffic.sorted { $0.sampledAt < $1.sampledAt }
        self.startedAt = startedAt
    }

    public mutating func append(sites rows: [SiteRoundRecord], now: Date) {
        sites.append(contentsOf: rows); trim(now: now)
    }
    public mutating func append(traffic row: TrafficRecord, now: Date) {
        traffic.append(row); trim(now: now)
    }
    public mutating func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention), future = now.addingTimeInterval(60)
        sites.removeAll { $0.sampledAt < cutoff || $0.sampledAt > future }
        traffic.removeAll { $0.sampledAt < cutoff || $0.sampledAt > future }
    }
    public var lastSiteRoundAt: Date? { sites.last?.sampledAt }
}

/// 两份 JSONL：`sites.jsonl` 和 `traffic.jsonl`。坏行跳过，超大或读不了的文件当作空历史。
public struct NetworkHistoryStore {
    public static let maxFileBytes = 16 * 1024 * 1024
    public let directory: URL
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "network-history")

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MeowMac/history/network", isDirectory: true)) {
        self.directory = directory
    }

    var sitesFile: URL { directory.appendingPathComponent("sites.jsonl") }
    var trafficFile: URL { directory.appendingPathComponent("traffic.jsonl") }

    public func load(now: Date) -> NetworkHistory {
        var history = NetworkHistory(sites: read(SiteRoundRecord.self, from: sitesFile), traffic: read(TrafficRecord.self, from: trafficFile))
        history.trim(now: now)
        return history
    }

    public func append(sites rows: [SiteRoundRecord]) throws { try append(rows, to: sitesFile) }
    public func append(traffic row: TrafficRecord) throws { try append([row], to: trafficFile) }

    /// 用内存中已裁剪的历史整体重写两份文件。
    public func rewrite(_ history: NetworkHistory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encode(history.sites).write(to: sitesFile, options: .atomic)
        try encode(history.traffic).write(to: trafficFile, options: .atomic)
    }

    private func append<T: Encodable>(_ rows: [T], to file: URL) throws {
        guard !rows.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encode(rows))
    }

    private func encode<T: Encodable>(_ rows: [T]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try rows.reduce(into: Data()) { data, row in data.append(try encoder.encode(row)); data.append(0x0A) }
    }

    private func read<T: Decodable>(_ type: T.Type, from file: URL) -> [T] {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return [] }
        guard size <= Self.maxFileBytes else {
            logger.error("网络历史文件过大，已忽略：\(file.lastPathComponent, privacy: .public)")
            return []
        }
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var skipped = 0
        let rows = data.split(separator: 0x0A).compactMap { line -> T? in
            guard let row = try? decoder.decode(T.self, from: Data(line)) else { skipped += 1; return nil }
            return row
        }
        if skipped > 0 { logger.error("跳过 \(skipped) 行损坏的网络历史：\(file.lastPathComponent, privacy: .public)") }
        return rows
    }
}

/// 趋势图上的一个点。`value` 为空表示这一点断线（全部失败或没有数据）。
public struct NetworkTrendPoint: Equatable {
    public let date: Date
    public let value: Double?
    public let low: Double?, high: Double?
    public let failedRounds: Int, totalRounds: Int
    public init(date: Date, value: Double?, low: Double? = nil, high: Double? = nil, failedRounds: Int = 0, totalRounds: Int = 0) {
        self.date = date; self.value = value; self.low = low; self.high = high
        self.failedRounds = failedRounds; self.totalRounds = totalRounds
    }
    public var hasFailure: Bool { failedRounds > 0 }
}

public enum NetworkTrendRange: Int, CaseIterable, Codable {
    case hour = 60, day = 1440
    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    public var title: String { self == .hour ? "1 小时" : "24 小时" }
    /// 24 小时视图的分桶：站点 10 分钟，速率 5 分钟。1 小时视图不分桶。
    public var siteBucket: TimeInterval? { self == .day ? 600 : nil }
    public var trafficBucket: TimeInterval? { self == .day ? 300 : nil }
}

public enum NetworkTrend {
    /// 一个分组的延迟序列，单位毫秒。
    public static func sites(_ rows: [SiteRoundRecord], group: NetworkSiteGroup, range: NetworkTrendRange, now: Date) -> [NetworkTrendPoint] {
        let start = now.addingTimeInterval(-range.seconds)
        let rows = rows.filter { $0.group == group && $0.sampledAt > start && $0.sampledAt <= now && $0.total > 0 }
        guard let bucket = range.siteBucket else {
            return rows.map { NetworkTrendPoint(date: $0.sampledAt, value: $0.medianMilliseconds, failedRounds: $0.failed ? 1 : 0, totalRounds: 1) }
        }
        return bucketed(rows, start: start, bucket: bucket, date: \.sampledAt).map { date, items in
            let values = items.compactMap(\.medianMilliseconds)
            return NetworkTrendPoint(date: date, value: median(values), low: values.min(), high: values.max(),
                                     failedRounds: items.filter(\.failed).count, totalRounds: items.count)
        }
    }

    /// 速率序列。`received` 为真取下行，否则取上行。
    public static func traffic(_ rows: [TrafficRecord], received: Bool, range: NetworkTrendRange, now: Date) -> [NetworkTrendPoint] {
        let start = now.addingTimeInterval(-range.seconds)
        let rows = rows.filter { $0.sampledAt > start && $0.sampledAt <= now }
        let average: (TrafficRecord) -> Double = { received ? $0.receivedAverage : $0.sentAverage }
        let peak: (TrafficRecord) -> Double = { received ? $0.receivedPeak : $0.sentPeak }
        guard let bucket = range.trafficBucket else {
            return rows.map { NetworkTrendPoint(date: $0.sampledAt, value: average($0), low: average($0), high: peak($0)) }
        }
        return bucketed(rows, start: start, bucket: bucket, date: \.sampledAt).map { date, items in
            let values = items.map(average)
            return NetworkTrendPoint(date: date, value: values.reduce(0, +) / Double(values.count),
                                     low: values.min(), high: items.map(peak).max())
        }
    }

    /// 相邻两点相隔超过这个时长，就视为没有记录的空档，图上断开并画斜纹。
    public static func gapThreshold(range: NetworkTrendRange, sites: Bool) -> TimeInterval {
        if let bucket = sites ? range.siteBucket : range.trafficBucket { return bucket * 2.5 }
        return sites ? 330 : 95
    }

    /// 没有记录的时段（相对窗口的起止比例 0～1）。窗口开头到第一个点之间也算。
    public static func missingIntervals(_ dates: [Date], range: NetworkTrendRange, now: Date, threshold: TimeInterval) -> [ClosedRange<Double>] {
        let start = now.addingTimeInterval(-range.seconds)
        let fraction: (Date) -> Double = { min(1, max(0, $0.timeIntervalSince(start) / range.seconds)) }
        guard let first = dates.first else { return [0...1] }
        var result: [ClosedRange<Double>] = []
        if first.timeIntervalSince(start) > threshold { result.append(0...fraction(first)) }
        for (a, b) in zip(dates, dates.dropFirst()) where b.timeIntervalSince(a) > threshold { result.append(fraction(a)...fraction(b)) }
        if let last = dates.last, now.timeIntervalSince(last) > threshold { result.append(fraction(last)...1) }
        return result
    }

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// 按固定桶分组，桶的时间取桶中点；空桶不出现。
    static func bucketed<T>(_ rows: [T], start: Date, bucket: TimeInterval, date: KeyPath<T, Date>) -> [(Date, [T])] {
        var groups: [Int: [T]] = [:]
        for row in rows { groups[Int(row[keyPath: date].timeIntervalSince(start) / bucket), default: []].append(row) }
        return groups.keys.sorted().map { key in (start.addingTimeInterval((Double(key) + 0.5) * bucket), groups[key]!) }
    }
}
