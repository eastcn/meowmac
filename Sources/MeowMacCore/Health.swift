import Foundation

public enum HealthLevel: Int, Comparable, Codable {
    case normal, warn, severe
    public static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum PanelTab: String, CaseIterable, Codable {
    case system, quota, network
}

public enum NetworkTone: String, Codable { case green, yellow, red, gray }

public struct HealthIssue: Codable {
    public let level: HealthLevel
    public let tab: PanelTab
    public let message: String

    public init(level: HealthLevel, tab: PanelTab, message: String) {
        self.level = level; self.tab = tab; self.message = message
    }
}

public struct HealthSummary: Codable {
    public let level: HealthLevel
    public let issues: [HealthIssue]
    public let coolingHint: Bool

    public var worst: HealthIssue? { issues.first }

    public init(level: HealthLevel, issues: [HealthIssue], coolingHint: Bool) {
        self.level = level; self.issues = issues; self.coolingHint = coolingHint
    }
}

public struct HealthInputs {
    public let system: SystemSnapshot?
    public let energy: EnergyDiagnosis?
    public let quotaUsedPercent: [Double]
    public let network: NetworkTone
    public let failedSources: [String: Int]
    public let fairSince: Date?
    public let fanHighSince: Date?
    public let now: Date
    public let quotaSnapshots: [QuotaSnapshot]
    public let networkSignals: [NetworkReminderSignal]?
    public let networkConfirmed: Bool
    public let networkCheckedAt: Date?
    public let energyUpdatedAt: Date?

    public init(system: SystemSnapshot?, energy: EnergyDiagnosis?, quotaUsedPercent: [Double], network: NetworkTone,
                failedSources: [String: Int], fairSince: Date?, now: Date, quotaSnapshots: [QuotaSnapshot] = [],
                networkSignals: [NetworkReminderSignal]? = nil, networkConfirmed: Bool = true,
                networkCheckedAt: Date? = nil, energyUpdatedAt: Date? = nil, fanHighSince: Date? = nil) {
        self.system = system; self.energy = energy; self.quotaUsedPercent = quotaUsedPercent
        self.network = network; self.failedSources = failedSources; self.fairSince = fairSince; self.now = now
        self.quotaSnapshots = quotaSnapshots
        self.networkSignals = networkSignals; self.networkConfirmed = networkConfirmed
        self.networkCheckedAt = networkCheckedAt; self.energyUpdatedAt = energyUpdatedAt
        self.fanHighSince = fanHighSince
    }
}

public enum HealthEvaluator {
    public static func evaluate(_ input: HealthInputs, config: LocalConfig) -> HealthSummary {
        var tracker = ReminderTracker()
        tracker.reconcile(ReminderCollector.collect(input, config: config), now: input.now)
        return tracker.health(now: input.now)
    }
}
