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
    public let now: Date
    public let quotaSnapshots: [QuotaSnapshot]

    public init(system: SystemSnapshot?, energy: EnergyDiagnosis?, quotaUsedPercent: [Double], network: NetworkTone,
                failedSources: [String: Int], fairSince: Date?, now: Date, quotaSnapshots: [QuotaSnapshot] = []) {
        self.system = system; self.energy = energy; self.quotaUsedPercent = quotaUsedPercent
        self.network = network; self.failedSources = failedSources; self.fairSince = fairSince; self.now = now
        self.quotaSnapshots = quotaSnapshots
    }
}

public enum HealthEvaluator {
    public static func evaluate(_ input: HealthInputs, config: LocalConfig) -> HealthSummary {
        var issues: [HealthIssue] = []
        func add(_ level: HealthLevel, _ tab: PanelTab, _ message: String) {
            issues.append(HealthIssue(level: level, tab: tab, message: message))
        }
        switch input.network {
        case .red: add(.severe, .network, "网络检测失败")
        case .yellow: add(.warn, .network, "网络状态待确认")
        case .green, .gray: break
        }
        if input.quotaUsedPercent.contains(where: { 1 - $0 / 100 < config.quotaRemainingWarn }) {
            add(.warn, .quota, "额度剩余不足")
        }
        for snapshot in input.quotaSnapshots.sorted(by: { $0.provider.rawValue < $1.provider.rawValue }) {
            for window in snapshot.windows where QuotaPace.calculate(window: window, now: input.now)?.exhaustsBeforeReset == true {
                add(.warn, .quota, "\(snapshot.provider.displayName) \(window.displayName.replacingOccurrences(of: "窗口", with: ""))额度偏快")
            }
        }
        if let remaining = input.system?.diskRemainingFraction, remaining < config.diskRemainingWarn {
            add(.warn, .system, "磁盘剩余不足")
        }
        let runaway = input.energy?.runaway ?? []
        if !runaway.isEmpty { add(.warn, .system, "进程 CPU 持续偏高，建议用 AI 诊断") }
        if !(input.energy?.longAssertions ?? []).isEmpty { add(.warn, .system, "进程持续阻止休眠，建议用 AI 诊断") }
        if input.energy?.prolongedMemoryPressure == true { add(.warn, .system, "内存压力持续偏高，建议用 AI 诊断") }
        if let system = input.system, system.thermal == .serious || system.thermal == .critical {
            let message = runaway.isEmpty ? "温度偏高，未发现异常进程，建议降温或用 AI 诊断" : "系统已降频，建议用 AI 诊断"
            add(.warn, .system, message)
        }
        for (source, failures) in input.failedSources.sorted(by: { $0.key < $1.key }) where failures >= config.sourceFailureCount {
            add(.warn, source.hasPrefix("network") ? .network : source.hasPrefix("quota") ? .quota : .system,
                "数据源失效：\(source)")
        }
        let cooling = input.system?.thermal == .fair && input.fairSince.map { input.now.timeIntervalSince($0) >= config.fairThermalSeconds } == true
        issues.sort { $0.level > $1.level }
        return HealthSummary(level: issues.first?.level ?? .normal, issues: issues, coolingHint: cooling)
    }
}
