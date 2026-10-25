import Foundation

/// 一条本轮结束的提示（D46，plan D3）。
public struct AgentSessionNotice: Equatable, Identifiable, Sendable {
    /// 渠道、会话和完成标识拼成，同一次完成只有一条。
    public let id: String
    public let provider: QuotaProvider
    public let name: String
    public let duration: TimeInterval?
    public let completedAt: Date
    /// 出现的时间，5 分钟后自动消失。
    public let shownAt: Date
    public init(id: String, provider: QuotaProvider, name: String, duration: TimeInterval?, completedAt: Date, shownAt: Date) {
        self.id = id; self.provider = provider; self.name = name; self.duration = duration
        self.completedAt = completedAt; self.shownAt = shownAt
    }
    /// 名称之后的部分，例如“· Codex · 已完成 · 12 分”。耗时用提示专用的短格式（D17）；不知道耗时就不写。
    public var detail: String {
        "· " + provider.displayName + " · 已完成" + (duration.map { " · " + Self.shortDuration($0) } ?? "")
    }

    /// 结束提示的短时长（D17）：不足 1 分记 1 分，例如“12 分”；满 60 分写“1 时 5 分”。面板仍用 `MetricFormat.duration`。
    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(max(0, seconds) / 60))
        return minutes >= 60 ? "\(minutes / 60) 时 \(minutes % 60) 分" : "\(minutes) 分"
    }
}

/// 桌面猫上显示的一条：单条完成，或合并后的“另有 n 个会话完成”。
public enum AgentSessionToast: Equatable, Identifiable, Sendable {
    case single(AgentSessionNotice)
    /// 合并的条数和它们的标识，点一下全部关掉。
    case more(count: Int, ids: [String])
    public var id: String {
        switch self {
        case .single(let notice): return notice.id
        case .more(_, let ids): return "more:" + ids.joined(separator: ",")
        }
    }
    public var ids: [String] {
        switch self {
        case .single(let notice): return [notice.id]
        case .more(_, let ids): return ids
        }
    }
    public var text: String {
        switch self {
        case .single(let notice): return "✓ " + notice.name + " " + notice.detail
        case .more(let count, _): return "另有 \(count) 个会话完成"
        }
    }
}

/// 结束提示的生成与管理（plan D3、D5a）。纯逻辑，时间由调用方给。
///
/// 按会话记下“已处理的完成标识”。读到的最新完成标识和记下的不同、完成时间不早于协调器开始运行的时间、会话没有停止，
/// 就提示一次再更新记录。不依赖上一次检查的时间，所以因读取预算延后读到的完成只会晚一点提示，不会丢。
public struct AgentSessionNoticeBoard: Equatable, Sendable {
    public static let lifetime: TimeInterval = 300
    public static let maxShown = 2
    public let startedAt: Date
    /// 会话 → 已处理的完成标识和完成时间。
    public private(set) var processed: [String: (id: String, at: Date)] = [:]
    /// 当前的提示，旧的在前。
    public private(set) var notices: [AgentSessionNotice] = []

    public init(startedAt: Date) { self.startedAt = startedAt }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.startedAt == rhs.startedAt && lhs.notices == rhs.notices
            && lhs.processed.mapValues(\.id) == rhs.processed.mapValues(\.id)
    }

    /// 对比本次检查的会话，返回新增的提示。也会清掉过期的提示。
    @discardableResult
    public mutating func update(_ sessions: [AgentSessionState], now: Date) -> [AgentSessionNotice] {
        expire(now: now)
        var added: [AgentSessionNotice] = []
        var seen = Set<String>()
        for session in sessions {
            seen.insert(session.key)
            guard let completion = session.completion else { continue }
            if processed[session.key]?.id == completion.id { continue }
            processed[session.key] = (completion.id, completion.completedAt)
            // 停止的会话、协调器开始之前就完成的轮次、10 分钟前的完成：只记录，不提示。
            guard session.status != .stopped, completion.completedAt >= startedAt,
                  now.timeIntervalSince(completion.completedAt) <= AgentSessionParser.staleInterval else { continue }
            let notice = AgentSessionNotice(id: session.key + ":" + completion.id, provider: session.provider, name: session.displayName,
                                            duration: completion.duration, completedAt: completion.completedAt, shownAt: now)
            guard !notices.contains(where: { $0.id == notice.id }) else { continue }
            notices.append(notice)
            added.append(notice)
        }
        // 不在本次列表里、完成已超过 10 分钟的记录可以清掉：再出现时它的完成太旧，不会提示。
        processed = processed.filter { seen.contains($0.key) || now.timeIntervalSince($0.value.at) <= AgentSessionParser.staleInterval }
        return added
    }

    public mutating func expire(now: Date) {
        notices.removeAll { now.timeIntervalSince($0.shownAt) >= Self.lifetime }
    }

    /// 最早一条提示到期的时间；没有提示时为 nil。
    public var nextExpiry: Date? { notices.map { $0.shownAt.addingTimeInterval(Self.lifetime) }.min() }

    public mutating func dismiss(_ ids: [String]) {
        notices.removeAll { ids.contains($0.id) }
    }

    /// 显示用：第 0 条贴着气泡（上方的角贴着猫），是最新的一条。超过 2 条时，离猫远的那条合并成“另有 n 个会话完成”。
    public var toasts: [AgentSessionToast] {
        let newest = Array(notices.reversed())
        guard newest.count > Self.maxShown else { return newest.map(AgentSessionToast.single) }
        let rest = newest.dropFirst()
        return [.single(newest[0]), .more(count: rest.count, ids: rest.map(\.id))]
    }
}
