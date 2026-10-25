import Foundation
import MeowMacCore
import MeowMacQuota
import MeowMacUI

/// AI 会话的读取与刷新节奏（D46，plan 条目 4：D4、D7、D7a）。全部用临时目录和虚构记录。
@MainActor
enum AgentSessionReaderTests {
    static var tests: [(String, @MainActor () async -> Bool)] {
        [
            ("Quota.AgentSessions/修改时间筛选与每次 20 个的读取预算", { budget() }),
            ("Quota.AgentSessions/旧日期目录恢复写入与目录列表缓存", { codexDirectories() }),
            ("Quota.AgentSessions/没变的文件不重读，开头元数据只读一次", { caches() }),
            ("Quota.AgentSessions/子 Agent 与子线程合并到主会话", { children() }),
            ("Quota.AgentSessions/符号链接不跟随，根目录不存在与不可读", { roots() }),
            ("UI.AgentSessions/节奏：未选不运行，60 秒与 10 秒切换，关掉清空", { await cadence() }),
            ("UI.AgentSessions/休眠暂停，唤醒立即检查", { await sleepWake() }),
            ("UI.AgentSessions/日志只含数字与状态，序号连续", { await logs() }),
            ("Quota.Live.AgentSessions/本机会话读取耗时", { live() }),
        ]
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let t = AgentSessionTests.self

    final class Home {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meowmac-sessions-" + UUID().uuidString, isDirectory: true)
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit {
            // 测试里改过权限的目录先恢复，才能删掉。
            if let enumerator = FileManager.default.enumerator(atPath: url.path) {
                for case let path as String in enumerator { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appendingPathComponent(path).path) }
            }
            try? FileManager.default.removeItem(at: url)
        }
        @discardableResult
        func write(_ path: String, _ lines: [String], age: TimeInterval) -> URL {
            let file = url.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: AgentSessionTests.text(lines))
            touch(path, age: age)
            return file
        }
        func touch(_ path: String, age: TimeInterval) {
            try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.appendingPathComponent(path).path)
        }
        func append(_ path: String, _ lines: [String], age: TimeInterval) {
            let file = url.appendingPathComponent(path)
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            try? handle.seekToEnd(); try? handle.write(contentsOf: AgentSessionTests.text(lines)); try? handle.close()
            touch(path, age: age)
        }
    }

    /// 刚结束的 Claude 会话（相对 `now` 的时间）。
    static func endedClaude(_ index: Int) -> [String] {
        [t.cUser(-900 + Double(index)), t.cAssistant(-400 + Double(index), stop: "end_turn", id: "msg_\(index)")].map(shift)
    }
    static func runningClaude(_ index: Int) -> [String] {
        [t.cUser(-900 + Double(index)), t.cAssistant(-400 + Double(index), stop: "tool_use", id: "msg_\(index)", block: "tool_use")].map(shift)
    }
    /// 夹具的时间以 `AgentSessionTests.base` 为原点；这里改成以 `now` 为原点。
    static func shift(_ line: String) -> String {
        var result = line
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let pattern = try! NSRegularExpression(pattern: #""timestamp":"([^"]+)""#)
        for match in pattern.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
            guard let range = Range(match.range(at: 1), in: line), let date = f.date(from: String(line[range])) else { continue }
            let moved = now.addingTimeInterval(date.timeIntervalSince(AgentSessionTests.base))
            result.replaceSubrange(Range(match.range(at: 1), in: result)!, with: f.string(from: moved))
        }
        return result
    }
    static func codexLines(_ lines: [String]) -> [String] {
        lines.map(shift).map { line in
            // `started_at`、`completed_at` 也改成以 `now` 为原点。
            var text = line
            let offset = Int(now.timeIntervalSince1970 - AgentSessionTests.base.timeIntervalSince1970)
            for key in ["started_at", "completed_at"] {
                let pattern = try! NSRegularExpression(pattern: "\"\(key)\":(\\d+)")
                for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                    let range = Range(match.range(at: 1), in: text)!
                    text.replaceSubrange(range, with: String(Int(text[range])! + offset))
                }
            }
            return text
        }
    }
    static func rollout(_ day: String, _ id: String) -> String { ".codex/sessions/\(day)/rollout-2027-01-15T08-00-00-\(id).jsonl" }
    static func uuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }

    static func budget() -> Bool {
        let home = Home()
        for i in 0..<25 { home.write(".claude/projects/-Users-example-demo/s-\(i).jsonl", endedClaude(i), age: 30 + Double(i)) }
        home.write(".claude/projects/-Users-example-demo/s-old.jsonl", endedClaude(99), age: 601)
        let reader = AgentSessionReader(home: home.url)
        let first = reader.read(now: now)
        // 修改时间超过 10 分钟的不读、不列出；预算 20 个：从新到旧读 20 个，其余 5 个未确认。
        guard first.sessions.count == 25, first.sessions.filter({ $0.status == .finished }).count == 20, first.unknownTotal == 5,
              first.runningTotal == 0, reader.counters.tailReads == 20,
              first.sessions.filter({ $0.status == .unknown }).map(\.id).sorted() == (20..<25).map { "s-\($0)" }.sorted() else {
            print("预算第 1 次：\(first.sessions.count) \(first.unknownTotal) \(reader.counters)"); return false
        }
        var board = AgentSessionNoticeBoard(startedAt: now.addingTimeInterval(-1000))
        guard board.update(first.sessions, now: now).count == 20 else { return false }
        let second = reader.read(now: now)
        guard second.sessions.allSatisfy({ $0.status == .finished }), second.unknownTotal == 0, reader.counters.tailReads == 25,
              board.update(second.sessions, now: now).count == 5 else { return false }
        // 没变的文件不重读。
        _ = reader.read(now: now)
        guard reader.counters.tailReads == 25 else { return false }
        // 在跑的会话：未确认的不计入在跑数。
        let busy = Home()
        for i in 0..<25 { busy.write(".claude/projects/p/s-\(i).jsonl", runningClaude(i), age: 30 + Double(i)) }
        let busyReader = AgentSessionReader(home: busy.url)
        let b1 = busyReader.read(now: now), b2 = busyReader.read(now: now)
        return b1.runningTotal == 20 && b1.unknownTotal == 5 && b2.runningTotal == 25 && b2.running(.claude) == 25
    }

    static func codexDirectories() -> Bool {
        let home = Home()
        let running = codexLines([t.xMeta(id: uuid(1)), t.xStarted("turn-1", -100)])
        // 旧日期目录里恢复写入的会话也能找到（D8 只看最新 3 个日期目录，这里看全部）。
        home.write(rollout("2025/01/01", uuid(1)), running, age: 5)
        for (n, day) in ["2027/01/12", "2027/01/13", "2027/01/14", "2027/01/15"].enumerated() {
            home.write(rollout(day, uuid(10 + n)), codexLines([t.xMeta(id: uuid(10 + n)), t.xStarted("t", -5000)]), age: 5000)
        }
        home.write(".codex/sessions/abcd/01/01/x.jsonl", running, age: 1)
        let reader = AgentSessionReader(home: home.url)
        let first = reader.read(now: now)
        guard first.sessions.count == 1, first.sessions[0].id == uuid(1), first.sessions[0].status == .running,
              first.roots[.codex] == .ok, first.roots[.claude] == .missing, reader.counters.directoryListings == 5 else {
            print("Codex 目录：\(first.sessions.map(\.id)) \(reader.counters)"); return false
        }
        // 目录没变：不重新列；新增文件的目录重新列。
        _ = reader.read(now: now)
        guard reader.counters.directoryListings == 5 else { return false }
        home.write(rollout("2027/01/15", uuid(20)), codexLines([t.xMeta(id: uuid(20)), t.xStarted("turn-n", -10)]), age: 2)
        let third = reader.read(now: now)
        return reader.counters.directoryListings == 6 && third.running(.codex) == 2
    }

    static func caches() -> Bool {
        let home = Home()
        let path = rollout("2027/01/15", uuid(1))
        home.write(path, codexLines([t.xMeta(id: uuid(1)), t.xStarted("turn-1", -100)]), age: 5)
        let reader = AgentSessionReader(home: home.url)
        let first = reader.read(now: now)
        guard first.running(.codex) == 1, reader.counters.headReads == 1, reader.counters.tailReads == 1,
              first.sessions[0].project == "sample-service" else { return false }
        // 同一文件追加了内容：重读尾部，不再读开头。
        home.append(path, codexLines([t.xComplete("turn-1", -3, start: -100)]), age: 3)
        let second = reader.read(now: now)
        guard second.sessions[0].status == .finished, reader.counters.headReads == 1, reader.counters.tailReads == 2,
              second.sessions[0].completion?.id == "turn-1" else { return false }
        // 没变：两样都不读。
        _ = reader.read(now: now)
        guard reader.counters.headReads == 1, reader.counters.tailReads == 2 else { return false }
        // 文件消失：清掉缓存；同一路径再出现时重新读开头。
        try? FileManager.default.removeItem(at: home.url.appendingPathComponent(path))
        let gone = reader.read(now: now)
        guard gone.sessions.isEmpty, reader.cachedFiles == 0 else { return false }
        home.write(path, codexLines([t.xMeta(id: uuid(1)), t.xStarted("turn-2", -10)]), age: 1)
        _ = reader.read(now: now)
        return reader.counters.headReads == 2 && reader.cachedFiles == 2
    }

    static func children() -> Bool {
        let home = Home()
        // Claude：主会话 15 分钟没写，子 Agent 刚写：主会话仍算在跑，子 Agent 不单独计数。
        home.write(".claude/projects/p/s-main.jsonl", runningClaude(1), age: 900)
        home.write(".claude/projects/p/s-main/subagents/agent-1.jsonl", runningClaude(2), age: 3)
        home.write(".claude/projects/p/s-quiet.jsonl", runningClaude(3), age: 900)
        // Codex：父线程 15 分钟没写，子线程刚写；另有一个父线程找不到的子线程。
        home.write(rollout("2027/01/15", uuid(1)), codexLines([t.xMeta(id: uuid(1)), t.xStarted("turn-p", -1000)]), age: 900)
        home.write(rollout("2027/01/15", uuid(2)), codexLines([t.xMeta(id: uuid(2), parent: uuid(1)), t.xStarted("turn-c", -10)]), age: 2)
        home.write(rollout("2027/01/15", uuid(3)), codexLines([t.xMeta(id: uuid(3), parent: uuid(404)), t.xStarted("turn-o", -10)]), age: 2)
        let snapshot = AgentSessionReader(home: home.url).read(now: now)
        let ids = snapshot.sessions.map(\.id).sorted()
        guard ids == ["s-main", uuid(1), uuid(3)].sorted() else { print("合并：\(ids)"); return false }
        return snapshot.running(.claude) == 1 && snapshot.running(.codex) == 2
            && snapshot.sessions.first { $0.id == uuid(1) }?.lastWriteAt == now.addingTimeInterval(-2)
    }

    static func roots() -> Bool {
        // 符号链接：目录内的链接文件和链接目录都不跟随。
        let home = Home(), outside = Home()
        outside.write("real/s-link.jsonl", runningClaude(1), age: 1)
        outside.write("2027/01/15/rollout-2027-01-15T08-00-00-\(uuid(9)).jsonl", codexLines([t.xMeta(id: uuid(9)), t.xStarted("t", -1)]), age: 1)
        home.write(".claude/projects/p/s-real.jsonl", runningClaude(2), age: 1)
        let fm = FileManager.default
        try? fm.createSymbolicLink(at: home.url.appendingPathComponent(".claude/projects/linked"), withDestinationURL: outside.url.appendingPathComponent("real"))
        try? fm.createSymbolicLink(at: home.url.appendingPathComponent(".claude/projects/p/s-file.jsonl"),
                                   withDestinationURL: outside.url.appendingPathComponent("real/s-link.jsonl"))
        try? fm.createDirectory(at: home.url.appendingPathComponent(".codex/sessions/2027/01"), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: home.url.appendingPathComponent(".codex/sessions/2027/01/15"), withDestinationURL: outside.url.appendingPathComponent("2027/01/15"))
        let linked = AgentSessionReader(home: home.url).read(now: now)
        guard linked.sessions.map(\.id) == ["s-real"], linked.roots[.codex] == .ok else { print("符号链接：\(linked.sessions.map(\.id))"); return false }
        // 根目录本身是符号链接时允许（同 D8）。
        let dotfiles = Home()
        try? fm.createDirectory(at: dotfiles.url.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: dotfiles.url.appendingPathComponent(".claude/projects"), withDestinationURL: home.url.appendingPathComponent(".claude/projects"))
        guard AgentSessionReader(home: dotfiles.url).read(now: now).running(.claude) == 1 else { return false }
        // 都不存在：没装；根目录是文件、不可读：读不了，读数写“—”。
        let empty = Home()
        let none = AgentSessionReader(home: empty.url).read(now: now)
        guard none.roots == [.claude: .missing, .codex: .missing], !none.installed, !AgentSessionReader.rootsExist(home: empty.url) else { return false }
        let broken = Home()
        broken.write(".claude/projects", [], age: 1)
        try? fm.createDirectory(at: broken.url.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: broken.url.appendingPathComponent(".codex/sessions").path)
        let bad = AgentSessionReader(home: broken.url).read(now: now)
        return bad.roots == [.claude: .unavailable, .codex: .unavailable] && bad.installed && !bad.readable
            && AgentSessionReader.rootsExist(home: broken.url) && AgentSessionReader.rootsExist(home: home.url)
    }

    // MARK: - 协调器

    final class FakeSource: @unchecked Sendable {
        private let lock = NSLock()
        private var _running = 0
        private var _reads = 0
        var running: Int { get { lock.withLock { _running } } set { lock.withLock { _running = newValue } } }
        var reads: Int { lock.withLock { _reads } }
        func read(_ at: Date) -> AgentSessionSnapshot {
            let count = lock.withLock { _reads += 1; return _running }
            let sessions = (0..<count).map {
                AgentSessionState(provider: .claude, id: "s-\($0)", phase: .running, lastWriteAt: at, now: at)
            }
            return AgentSessionSnapshot(checkedAt: at, roots: [.claude: .ok, .codex: .missing], sessions: sessions)
        }
    }

    static func coordinator(wanted: @escaping () -> Bool) -> (AgentSessionCoordinator, FakeSource, PanelState) {
        let state = PanelPreviewRenderer.syntheticState()
        let source = FakeSource()
        let coordinator = AgentSessionCoordinator(state: state, read: { source.read($0) })
        coordinator.installsTimer = false
        coordinator.wanted = wanted
        coordinator.now = { now }
        return (coordinator, source, state)
    }

    /// 等异步的首次检查完成。
    static func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
        return condition()
    }

    static func cadence() async -> Bool {
        var wanted = false
        let (c, source, state) = coordinator(wanted: { wanted })
        // 未选：不运行，没有计时器，不读。
        c.apply()
        await c.check()
        guard !c.isRunning, c.interval == nil, c.nextFireAt == nil, source.reads == 0 else { return false }
        // 选了、没在跑：60 秒。
        wanted = true
        c.apply()
        guard await waitFor({ c.sequence == 1 }), c.interval == 60, c.nextFireAt == now.addingTimeInterval(60),
              state.agentSessions?.runningTotal == 0 else { return false }
        // 有在跑：10 秒。
        source.running = 2
        await c.check()
        guard c.interval == 10, c.nextFireAt == now.addingTimeInterval(10), state.agentSessions?.runningTotal == 2 else { return false }
        // 回到全部结束：60 秒。
        source.running = 0
        await c.check()
        guard c.interval == 60 else { return false }
        // 到点触发：检查一次。
        c.now = { now.addingTimeInterval(60) }
        await c.fire()
        guard c.sequence == 4, source.reads == 4 else { return false }
        // 关掉：停止并清空，之后不再读。
        state.agentSessionToasts = [.more(count: 2, ids: ["a", "b"])]
        wanted = false
        c.apply()
        await c.check()
        return !c.isRunning && c.interval == nil && c.nextFireAt == nil && state.agentSessions == nil
            && state.agentSessionToasts.isEmpty && source.reads == 4
    }

    static func sleepWake() async -> Bool {
        let (c, source, _) = coordinator(wanted: { true })
        c.apply()
        guard await waitFor({ c.sequence == 1 }) else { return false }
        // 休眠：暂停，没有计时器，检查不读。
        c.setSleeping(true)
        await c.check()
        await c.fire()
        guard c.paused, c.interval == nil, c.nextFireAt == nil, source.reads == 1 else { return false }
        // 唤醒：立即检查一次。
        c.setSleeping(false)
        guard await waitFor({ c.sequence == 2 }), c.interval == 60 else { return false }
        // 屏幕休眠同样暂停，屏幕唤醒立即检查。
        c.setScreensSleeping(true)
        guard c.nextFireAt == nil else { return false }
        c.setScreensSleeping(false)
        guard await waitFor({ c.sequence == 3 }) else { return false }
        c.stop()
        return source.reads == 3
    }

    static func logs() async -> Bool {
        let (c, source, _) = coordinator(wanted: { true })
        c.recordsLog = true
        c.apply()
        guard await waitFor({ c.sequence == 1 }) else { return false }
        await c.check()
        source.running = 1
        await c.check()
        await c.check()
        let notices = c.logLines.filter { $0.level == "notice" }.map(\.text)
        let debugs = c.logLines.filter { $0.level == "debug" }.map(\.text)
        // 计数变化时一条 notice；每次检查一条 debug，序号每次加 1。
        guard notices == ["claude=0 codex=0 unknown=0 state=ok", "claude=1 codex=0 unknown=0 state=ok"], debugs.count == 4 else {
            print("日志：\(c.logLines)"); return false
        }
        let pattern = try! NSRegularExpression(pattern: #"^check=(\d+) at=\d+ claude=\d+ codex=\d+ unknown=\d+ state=(ok|unavailable|missing)$"#)
        for (index, line) in debugs.enumerated() {
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line), Int(line[range]) == index + 1 else { return false }
        }
        // 停止后不再产生检查日志。
        c.stop()
        await c.check()
        await c.fire()
        return c.logLines.filter { $0.level == "debug" }.count == 4
    }

    // MARK: - 实机冒烟

    /// 对本机真实目录只读地跑一次。只输出耗时和会话数，不输出路径、标题和目录名；原值写到 `build/acceptance/desktop-cat-sessions/`。
    static func live() -> Bool {
        let reader = AgentSessionReader()
        let clock = ContinuousClock()
        var snapshot = AgentSessionSnapshot(checkedAt: Date(), roots: [:], sessions: [])
        let first = clock.measure { snapshot = reader.read(now: Date()) }
        var rounds: [Double] = []
        for _ in 0..<5 {
            // 保留 Codex 开头元数据，丢掉尾部缓存：每次都重新读尾部（最多 20 个文件）。
            reader.discardTailCache()
            let elapsed = clock.measure { snapshot = reader.read(now: Date()) }
            rounds.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        let cached = clock.measure { snapshot = reader.read(now: Date()) }
        func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let worst = rounds.max() ?? .infinity
        let line = String(format: "首次（含 Codex 开头）%.1f ms；重读尾部最慢 %.1f ms，平均 %.1f ms；全部命中缓存 %.1f ms；会话 %d 个，在跑 %d，未确认 %d；读尾部 %d 次，读开头 %d 次",
                          ms(first), worst, rounds.reduce(0, +) / Double(max(1, rounds.count)), ms(cached),
                          snapshot.sessions.count, snapshot.runningTotal, snapshot.unknownTotal, reader.counters.tailReads, reader.counters.headReads)
        print("会话读取：" + line)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/desktop-cat-sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8)
            .write(to: directory.appendingPathComponent("live-read-\(Int(Date().timeIntervalSince1970)).txt"))
        return snapshot.readable && worst <= 50
    }
}
