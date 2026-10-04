import Foundation
import MeowMacCore
import MeowMacQuota

/// D8：本地扫描会话记录的修改时间，代替每分钟一次的 `sessions`。全部用临时目录和合成文件。
enum AgentActivityTests {
    private static let now = Date(timeIntervalSince1970: 2_000_000)

    private final class Home {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult
        func write(_ path: String, age: TimeInterval) -> URL {
            let file = url.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data("{}\n".utf8))
            try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
            return file
        }

        func scan() -> [QuotaProvider: AgentActivity] { AgentActivityScanner(home: url).scan(now: now) }
    }

    /// 120 秒窗口：119 秒前写过算 active，120 秒前算 idle；两个渠道互不影响。
    static func window() -> Bool {
        let home = Home()
        home.write(".claude/projects/p1/a.jsonl", age: 119)
        home.write(".codex/sessions/2026/10/04/rollout-a.jsonl", age: 120)
        let scan = home.scan()
        return scan[.claude] == .active && scan[.codex] == .idle && scan[.deepseek] == nil
    }

    /// Claude 子 Agent 的记录在 `<会话>/subagents/` 下，主 transcript 已经静默时也要算 active。
    static func claudeSubagents() -> Bool {
        let home = Home()
        home.write(".claude/projects/p1/main.jsonl", age: 600)
        home.write(".claude/projects/p1/session-id/subagents/agent-1.jsonl", age: 5)
        home.write(".claude/projects/p1/notes.txt", age: 1)
        guard home.scan()[.claude] == .active else { return false }
        let quiet = Home()
        quiet.write(".claude/projects/p1/main.jsonl", age: 600)
        quiet.write(".claude/projects/p1/notes.txt", age: 1)
        return quiet.scan()[.claude] == .idle
    }

    /// Codex 只看名称最新的 3 个日期目录：第 3 个有写入算 active，第 4 个没有人看。
    static func codexRecentDates() -> Bool {
        let home = Home()
        for day in ["2026/10/01", "2026/10/02", "2026/10/03", "2026/10/04"] { home.write(".codex/sessions/\(day)/old.jsonl", age: 86_400) }
        home.write(".codex/sessions/2026/10/01/fresh.jsonl", age: 10)
        home.write(".codex/sessions/abc/10/05/ignored.jsonl", age: 1)
        home.write(".codex/sessions/2026/10/x/ignored.jsonl", age: 1)
        guard home.scan()[.codex] == .idle else { return false }
        home.write(".codex/sessions/2026/10/02/fresh.jsonl", age: 10)
        guard home.scan()[.codex] == .active else { return false }
        // 跨年按完整日期排序，不是按目录名的字典序拼接。
        let year = Home()
        year.write(".codex/sessions/2025/12/31/a.jsonl", age: 10)
        year.write(".codex/sessions/2026/01/01/a.jsonl", age: 86_400)
        return year.scan()[.codex] == .active
    }

    /// 根目录不存在是没装，算 idle；存在但不是目录或结构不符，才是 unavailable。
    static func availability() -> Bool {
        let empty = Home()
        let missing = empty.scan()
        guard missing[.claude] == .idle, missing[.codex] == .idle else { return false }
        let blank = Home()
        try? FileManager.default.createDirectory(at: blank.url.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: blank.url.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        let none = blank.scan()
        guard none[.claude] == .idle, none[.codex] == .idle else { return false }
        let notDirectory = Home()
        notDirectory.write(".claude/projects", age: 1)
        notDirectory.write(".codex/sessions", age: 1)
        let broken = notDirectory.scan()
        guard broken[.claude] == .unavailable, broken[.codex] == .unavailable else { return false }
        // Codex 根目录里有内容，却一个日期目录都认不出来：布局变了。
        let changed = Home()
        changed.write(".codex/sessions/by-project/a/b.jsonl", age: 1)
        return changed.scan()[.codex] == .unavailable
    }

    /// 目录内的符号链接不跟随：链接到外面的新文件或新目录都不算。根目录本身可以是符号链接。
    static func symbolicLinks() -> Bool {
        let home = Home()
        let outside = Home()
        let fresh = outside.write("fresh.jsonl", age: 1)
        outside.write("dir/inside.jsonl", age: 1)
        home.write(".claude/projects/p1/old.jsonl", age: 900)
        try? FileManager.default.createSymbolicLink(at: home.url.appendingPathComponent(".claude/projects/p1/link.jsonl"), withDestinationURL: fresh)
        try? FileManager.default.createSymbolicLink(at: home.url.appendingPathComponent(".claude/projects/linked"),
                                                    withDestinationURL: outside.url.appendingPathComponent("dir"))
        guard home.scan()[.claude] == .idle else { return false }
        let linked = Home()
        let real = Home()
        real.write("p1/a.jsonl", age: 5)
        try? FileManager.default.createDirectory(at: linked.url.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: linked.url.appendingPathComponent(".claude/projects"), withDestinationURL: real.url)
        return linked.scan()[.claude] == .active
    }

    /// 轮询决策：都可读时不调用 CLI；有渠道不可读时，对它退回 CLI，间隔不少于 300 秒。
    static func pollerFallback() -> Bool {
        var poller = SessionPoller()
        let readable = poller.plan([.claude: .active, .codex: .idle], at: now)
        guard readable.updates == [.claude: true, .codex: false], readable.fallback.isEmpty else { return false }
        let first = poller.plan([.claude: .idle, .codex: .unavailable], at: now.addingTimeInterval(60))
        guard first.updates == [.claude: false], first.fallback == [.codex] else { return false }
        guard poller.plan([.claude: .idle, .codex: .unavailable], at: now.addingTimeInterval(359)).fallback.isEmpty,
              poller.plan([.claude: .idle, .codex: .unavailable], at: now.addingTimeInterval(360)).fallback == [.codex] else { return false }
        // 渠道缺失按不可读处理。
        var missing = SessionPoller()
        let plan = missing.plan([:], at: now)
        let states = SessionPoller.states(for: [.codex], from: [SessionActivity(provider: .claude, active: true), SessionActivity(provider: .codex, active: false)])
        return plan.updates.isEmpty && plan.fallback == [.claude, .codex] && states == [.codex: false]
            && SessionPoller.states(for: [.claude], from: [SessionActivity(provider: .claude, active: true)]) == [.claude: true]
    }

    /// 两个渠道来源不同：一个渠道没更新时，它的状态保留，不会被另一个渠道的更新翻成 idle。
    static func scheduleKeepsUnupdatedProvider() -> Bool {
        let config = LocalConfig()
        var schedule = QuotaSchedule()
        schedule.sessionUpdate(provider: .codex, active: true, at: now, config: config)
        schedule.sessionUpdate(provider: .claude, active: true, at: now, config: config)
        // 之后只有 claude 在每分钟更新，codex 走 300 秒一次的 CLI，或者 CLI 失败。
        for minute in 1...4 { schedule.sessionUpdate(provider: .claude, active: true, at: now.addingTimeInterval(Double(minute) * 60), config: config) }
        guard schedule.dueFinishRefresh(at: now.addingTimeInterval(2_000)).isEmpty else { return false }
        schedule.sessionUpdate(provider: .claude, active: false, at: now.addingTimeInterval(300), config: config)
        guard schedule.dueFinishRefresh(at: now.addingTimeInterval(300 + config.sessionFinishDelaySeconds - 1)).isEmpty,
              schedule.dueFinishRefresh(at: now.addingTimeInterval(300 + config.sessionFinishDelaySeconds)) == [.claude] else { return false }
        schedule.sessionUpdate(provider: .codex, active: false, at: now.addingTimeInterval(600), config: config)
        return schedule.dueFinishRefresh(at: now.addingTimeInterval(600 + config.sessionFinishDelaySeconds)) == [.codex]
    }
}
