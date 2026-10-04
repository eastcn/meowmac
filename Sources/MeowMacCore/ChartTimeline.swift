import Foundation

public struct ChartSample: Codable, Equatable {
    public let date: Date
    public let value: Double
    public init(date: Date, value: Double) { self.date = date; self.value = value }
}

/// 系统采样每 10 秒一次。缺测、长间隔与容量变化都不能用直线补齐。
public enum ChartTimeline {
    public static let sampleTolerance: TimeInterval = 5
    public static let maximumGap: TimeInterval = 30

    public static func ordered(_ points: [ChartPoint], in domain: ClosedRange<Date>) -> [ChartPoint] {
        var unique: [Date: ChartPoint] = [:]
        for point in points where point.timestamp.timeIntervalSince1970.isFinite && domain.contains(point.timestamp) {
            unique[point.timestamp] = point
        }
        return unique.values.sorted { $0.timestamp < $1.timestamp }
    }

    public static func selection(_ points: [ChartPoint], at date: Date, in domain: ClosedRange<Date>) -> ChartPoint? {
        guard date.timeIntervalSince1970.isFinite, domain.contains(date),
              let point = ordered(points, in: domain).min(by: {
                  abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
              }), abs(point.timestamp.timeIntervalSince(date)) <= sampleTolerance else { return nil }
        return point
    }

    public static func segments(_ points: [ChartPoint], in domain: ClosedRange<Date>,
                                value: (ChartPoint) -> Double?,
                                breakBefore: (ChartPoint, ChartPoint) -> Bool = { _, _ in false }) -> [[ChartSample]] {
        var result: [[ChartSample]] = [], current: [ChartSample] = []
        var previous: ChartPoint?
        func finish() { if !current.isEmpty { result.append(current); current = [] }; previous = nil }
        for point in ordered(points, in: domain) {
            guard let number = value(point), number.isFinite else { finish(); continue }
            if let last = previous, point.timestamp.timeIntervalSince(last.timestamp) > maximumGap || breakBefore(last, point) { finish() }
            current.append(ChartSample(date: point.timestamp, value: number)); previous = point
        }
        finish()
        return result
    }

    /// 每个真实样本只覆盖附近半个采样间隔，空白时段不继承旧值。
    public static func missingPeriods(_ points: [ChartPoint], in domain: ClosedRange<Date>,
                                      available: (ChartPoint) -> Bool) -> [ClosedRange<Date>] {
        var periods: [ClosedRange<Date>] = [], end = domain.lowerBound
        for point in ordered(points, in: domain) where available(point) {
            let start = max(domain.lowerBound, point.timestamp.addingTimeInterval(-sampleTolerance))
            if start > end { periods.append(end...start) }
            end = max(end, min(domain.upperBound, point.timestamp.addingTimeInterval(sampleTolerance)))
        }
        if end < domain.upperBound { periods.append(end...domain.upperBound) }
        return periods
    }
}
