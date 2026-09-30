import Foundation

public struct QuotaSchedule {
    private var lastFullRefresh: Date?
    private var lastManualRefresh: Date?
    private var pendingFinish: [QuotaProvider: Date] = [:]
    private var wasActive: [QuotaProvider: Bool] = [:]
    private var sleeping = false

    public init() {}

    public mutating func markFullRefresh(at now: Date) { lastFullRefresh = now }

    public mutating func dueFullRefresh(at now: Date, config: LocalConfig) -> Bool {
        guard !sleeping else { return false }
        return lastFullRefresh.map { now.timeIntervalSince($0) >= config.quotaRefreshSeconds } ?? true
    }

    public mutating func sessionUpdate(_ sessions: [SessionActivity], at now: Date, config: LocalConfig) {
        for provider in [QuotaProvider.claude, .codex] {
            let active = sessions.contains { $0.provider == provider && $0.active }
            if wasActive[provider] == true && !active { pendingFinish[provider] = now.addingTimeInterval(config.sessionFinishDelaySeconds) }
            if active { pendingFinish.removeValue(forKey: provider) }
            wasActive[provider] = active
        }
    }

    public mutating func dueFinishRefresh(at now: Date) -> [QuotaProvider] {
        guard !sleeping else { return [] }
        let due = pendingFinish.filter { $0.value <= now }.map(\.key).sorted { $0.rawValue < $1.rawValue }
        for provider in due { pendingFinish.removeValue(forKey: provider) }
        return due
    }

    public mutating func deferFinishRefresh(_ provider: QuotaProvider, until date: Date) {
        pendingFinish[provider] = date
    }

    public mutating func manualRefresh(at now: Date, config: LocalConfig) -> Bool {
        guard !sleeping, lastManualRefresh.map({ now.timeIntervalSince($0) >= config.manualMergeSeconds }) ?? true else { return false }
        lastManualRefresh = now
        return true
    }

    public mutating func sleep() { sleeping = true }

    public mutating func wake(at now: Date, config: LocalConfig) -> Bool {
        sleeping = false
        return dueFullRefresh(at: now, config: config)
    }
}
