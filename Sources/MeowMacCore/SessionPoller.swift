import Foundation

/// 本地扫描一个渠道会话记录得到的结论。
public enum AgentActivity: Equatable {
    case active
    case idle
    /// 目录存在但读不了，或结构不符合预期。只有这种情况才退回 CLI。
    case unavailable
}

public struct SessionPollPlan: Equatable {
    /// 扫描得到结论的渠道：true 为 active。
    public var updates: [QuotaProvider: Bool]
    /// 需要调用 CLI 补问的渠道。
    public var fallback: [QuotaProvider]
}

/// 会话轮询的决策（D8）：扫描结论直接使用，扫描不了的渠道才退回 `sessions`，
/// 且 CLI 调用间隔不少于 `fallbackSeconds`，因为每次调用都会触发 `spctl`。
public struct SessionPoller {
    public static let providers: [QuotaProvider] = [.claude, .codex]
    public static let fallbackSeconds: TimeInterval = 300

    private var lastFallback: Date?

    public init() {}

    public mutating func plan(_ scan: [QuotaProvider: AgentActivity], at now: Date) -> SessionPollPlan {
        var updates: [QuotaProvider: Bool] = [:]
        var unavailable: [QuotaProvider] = []
        for provider in Self.providers {
            switch scan[provider] ?? .unavailable {
            case .active: updates[provider] = true
            case .idle: updates[provider] = false
            case .unavailable: unavailable.append(provider)
            }
        }
        guard !unavailable.isEmpty,
              lastFallback.map({ now.timeIntervalSince($0) >= Self.fallbackSeconds }) ?? true else {
            return SessionPollPlan(updates: updates, fallback: [])
        }
        lastFallback = now
        return SessionPollPlan(updates: updates, fallback: unavailable)
    }

    /// CLI 的返回里没有某个渠道的活跃会话，就是 idle。
    public static func states(for providers: [QuotaProvider], from sessions: [SessionActivity]) -> [QuotaProvider: Bool] {
        Dictionary(uniqueKeysWithValues: providers.map { provider in
            (provider, sessions.contains { $0.provider == provider && $0.active })
        })
    }
}
