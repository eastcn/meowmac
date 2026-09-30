import Foundation

public struct QuotaPace: Codable {
    public let expectedRemainingFraction: Double
    public let aheadPercentagePoints: Double
    public let secondsUntilExhaustion: TimeInterval?
    public let exhaustsBeforeReset: Bool

    public static func calculate(window: QuotaWindow, now: Date) -> QuotaPace? {
        guard let minutes = window.effectiveWindowMinutes, minutes > 0, let reset = window.resetsAt else { return nil }
        let length = Double(minutes) * 60
        let remainingTime = reset.timeIntervalSince(now)
        guard remainingTime > 0, remainingTime <= length else { return nil }
        let elapsed = length - remainingTime
        let used = min(1, max(0, window.usedPercent / 100))
        let eta = elapsed > 0 && used > 0 ? (1 - used) * elapsed / used : nil
        return QuotaPace(expectedRemainingFraction: remainingTime / length,
                         aheadPercentagePoints: (used - elapsed / length) * 100,
                         secondsUntilExhaustion: eta,
                         exhaustsBeforeReset: eta.map { $0 < remainingTime } ?? false)
    }
}

public struct QuotaPeak: Codable {
    public let resetsAt: Date
    public let usedPercent: Double
    public let isCurrent: Bool
}

public enum QuotaHistorySeries {
    public static func peaks(_ history: [QuotaHistoryLine], now: Date) -> [QuotaPeak] {
        let samples = history.filter { $0.windowMinutes == 300 && $0.sampledAt >= now.addingTimeInterval(-7 * 86400) && $0.sampledAt <= now && $0.resetsAt != nil }
        return Dictionary(grouping: samples, by: { $0.resetsAt! }).map { reset, rows in
            QuotaPeak(resetsAt: reset, usedPercent: rows.map(\.usedPercent).max() ?? 0, isCurrent: reset > now)
        }.sorted { $0.resetsAt < $1.resetsAt }
    }

    public static func currentCycle(_ history: [QuotaHistoryLine], window: QuotaWindow, now: Date) -> [QuotaHistoryLine] {
        guard let minutes = window.effectiveWindowMinutes, let reset = window.resetsAt else { return [] }
        let start = reset.addingTimeInterval(Double(-minutes * 60))
        return history.filter {
            $0.windowMinutes == minutes && ($0.windowID == nil || $0.windowID == window.identifier)
                && $0.resetsAt == reset && $0.sampledAt >= start && $0.sampledAt <= min(reset, now)
        }.sorted { $0.sampledAt < $1.sampledAt }
    }
}

public enum MetricFormat {
    public static func rate(_ value: Double) -> String {
        let bounded = value.isFinite ? max(0, value) : 0
        let units = ["B", "K", "M", "G"]
        var scaled = bounded, index = 0
        while scaled >= 1024 && index < units.count - 1 { scaled /= 1024; index += 1 }
        return String(format: "%.1f%@", scaled, units[index])
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes >= 1440 { return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分" }
        return "\(minutes) 分钟"
    }
}
