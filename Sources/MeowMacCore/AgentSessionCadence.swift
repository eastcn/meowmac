import Foundation

/// 会话读取的节奏（D46，plan D4）。纯函数。
public enum AgentSessionCadence {
    /// 桌面猫指标目录里“AI 会话”的 id。
    public static let metricID = "agent.sessions"
    /// 没有会话在跑时每 60 秒检查一次，有会话在跑时每 10 秒。
    public static let idleInterval: TimeInterval = 60
    public static let busyInterval: TimeInterval = 10

    /// 只在桌面猫开着且选了这项指标时运行。
    public static func wanted(_ config: DesktopCatConfig) -> Bool {
        config.enabled && config.metrics.contains(metricID)
    }

    /// 下一次检查的间隔；nil 表示不运行，或休眠、屏幕休眠时暂停。
    public static func interval(wanted: Bool, paused: Bool, running: Int) -> TimeInterval? {
        guard wanted, !paused else { return nil }
        return running > 0 ? busyInterval : idleInterval
    }
}

/// 会话协调器的日志（plan D7a）：只含数字和状态，不含路径、标题和目录名。
public enum AgentSessionLog {
    /// 扫描状态：至少一个渠道能读是 ok，装了但都读不了是 unavailable，都没装是 missing。
    public static func state(_ snapshot: AgentSessionSnapshot) -> String {
        snapshot.readable ? "ok" : snapshot.installed ? "unavailable" : "missing"
    }

    /// 计数、未确认数或扫描状态变化时记的 `.notice`，例如 `claude=1 codex=0 unknown=0 state=ok`。
    public static func notice(_ snapshot: AgentSessionSnapshot) -> String {
        "claude=\(snapshot.running(.claude)) codex=\(snapshot.running(.codex)) unknown=\(snapshot.unknownTotal) state=\(state(snapshot))"
    }

    /// 每次检查记的 `.debug`：检查序号、完成时间（Unix 秒）、各渠道计数、未确认数和扫描状态。
    public static func check(sequence: Int, snapshot: AgentSessionSnapshot, finishedAt: Date) -> String {
        "check=\(sequence) at=\(Int(finishedAt.timeIntervalSince1970)) " + notice(snapshot)
    }
}
