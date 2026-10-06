import Foundation

public struct RuleEvaluation {
    public let rule: AlertRule
    public let reading: MetricReading
    public let duration: TimeInterval
    public let triggered: Bool
    public var key: String { rule.id + "." + reading.object }
}

/// 持续时长只由新采样推进；重复读取缓存不会累计时长。
public struct RuleClock {
    private struct Entry {
        var fingerprint: AlertRule
        var since: Date?
        var last: Date
        var latched: Bool
        var resetAt: Date?
        var evaluation: RuleEvaluation?
    }
    private var entries: [String: Entry] = [:]
    public private(set) var evaluations: [RuleEvaluation] = []
    public init() {}
    public mutating func sleep() {
        for key in entries.keys {
            entries[key]?.since = nil
            entries[key]?.evaluation = nil
        }
        evaluations = []
    }
    public mutating func update(rules: [AlertRule], input: HealthInputs) {
        let live = Dictionary(rules.filter { $0.enabled && $0.available }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entries = entries.filter { _, entry in
            guard let rule = live[entry.fingerprint.id] else { return false }
            let previous = entry.fingerprint
            return rule.metric == previous.metric && rule.comparison == previous.comparison
                && rule.threshold == previous.threshold && rule.durationSeconds == previous.durationSeconds && rule.scope == previous.scope
        }
        var next: [RuleEvaluation] = []
        for rule in live.values.sorted(by: { $0.id < $1.id }) {
            guard let metric = AlertMetric(rawValue: rule.metric) else { continue }
            for reading in metric.read(input) where rule.scope?.contains(reading) ?? true {
                let key = rule.id + "." + reading.object
                if let previous = entries[key], reading.sampledAt <= previous.last {
                    if reading.sampledAt == previous.last, let evaluation = previous.evaluation {
                        next.append(RuleEvaluation(rule: rule, reading: reading, duration: evaluation.duration, triggered: evaluation.triggered))
                    }
                    continue
                }
                var entry = entries[key] ?? Entry(fingerprint: rule, since: nil, last: reading.sampledAt, latched: false, resetAt: reading.resetAt, evaluation: nil)
                if reading.sampledAt.timeIntervalSince(entry.last) > metric.sampleSeconds * 2.5 {
                    entry.since = nil
                }
                if let oldReset = entry.resetAt, let reset = reading.resetAt,
                   abs(oldReset.timeIntervalSince(reset)) > QuotaHistorySeries.resetTolerance {
                    entry.since = nil; entry.latched = false
                }
                entry.resetAt = reading.resetAt
                if rule.comparison.matches(reading.value, threshold: rule.threshold) {
                    if entry.since == nil { entry.since = max(reading.sampledAt, input.now) }
                    if max(0, reading.sampledAt.timeIntervalSince(entry.since!)) >= rule.durationSeconds { entry.latched = true }
                } else { entry.since = nil; entry.latched = false }
                entry.last = reading.sampledAt
                let evaluation = RuleEvaluation(rule: rule, reading: reading,
                    duration: entry.since.map { max(0, reading.sampledAt.timeIntervalSince($0)) } ?? 0,
                    triggered: entry.latched)
                entry.evaluation = evaluation; entries[key] = entry; next.append(evaluation)
            }
        }
        evaluations = next
    }
}
