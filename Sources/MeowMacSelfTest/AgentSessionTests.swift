import Foundation
import MeowMacCore

/// AI 会话的记录解析与结束提示（D46，plan 条目 3：D5、D5a、D6、D8）。夹具全部虚构，正文都是“示例正文”一类的占位文字。
enum AgentSessionTests {
    static var tests: [(String, @MainActor () async -> Bool)] {
        [
            ("Core.AgentSessions/Claude 本轮结束、工具调用与新提问", { claudeTurns() }),
            ("Core.AgentSessions/Claude 侧链、标题、目录名与中断", { claudeDetails() }),
            ("Core.AgentSessions/Codex 轮次配对与 turn_id 不一致", { codexTurns() }),
            ("Core.AgentSessions/Codex 子线程合并与名称回退", { codexMeta() }),
            ("Core.AgentSessions/不完整行、坏行、超长行与空文件", { robustness() }),
            ("Core.AgentSessions/时间戳、10 分钟停止与未确认", { timing() }),
            ("Core.AgentSessions/结束提示的产生与去重", { noticesOnce() }),
            ("Core.AgentSessions/提示合并、过期与手动关闭", { noticeDisplay() }),
            ("Core.AgentSessions/解析结果不含正文", { privacy() }),
        ]
    }

    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static func iso(_ offset: TimeInterval) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: base.addingTimeInterval(offset))
    }
    static func text(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    // MARK: - Claude 夹具

    static let cwd = "/Users/example/projects/demo-app"
    static func cUser(_ t: TimeInterval, sidechain: Bool = false, meta: Bool = false) -> String {
        #"{"type":"user","uuid":"u-\#(Int(t))","timestamp":"\#(iso(t))","isSidechain":\#(sidechain),"#
            + (meta ? #""isMeta":true,"# : "") + #""cwd":"\#(cwd)","message":{"role":"user","content":"示例提问正文"}}"#
    }
    static func cToolResult(_ t: TimeInterval) -> String {
        #"{"type":"user","uuid":"r-\#(Int(t))","timestamp":"\#(iso(t))","isSidechain":false,"cwd":"\#(cwd)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_example","content":"示例工具输出"}]}}"#
    }
    static func cAssistant(_ t: TimeInterval, stop: String, id: String = "msg_example", sidechain: Bool = false, block: String = "text") -> String {
        #"{"type":"assistant","uuid":"a-\#(Int(t))","timestamp":"\#(iso(t))","isSidechain":\#(sidechain),"cwd":"\#(cwd)","message":{"id":"\#(id)","role":"assistant","stop_reason":"\#(stop)","content":[{"type":"\#(block)","text":"示例回复正文"}]}}"#
    }
    static func cInterrupt(_ t: TimeInterval) -> String {
        #"{"type":"user","uuid":"i-\#(Int(t))","timestamp":"\#(iso(t))","isSidechain":false,"cwd":"\#(cwd)","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    }
    static func cTitle(_ title: String) -> String { #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"s-example"}"# }

    static func claude(_ lines: [String], age: TimeInterval = 5, now: TimeInterval = 1000, fromStart: Bool = true,
                       previous: AgentSessionState? = nil) -> AgentSessionState {
        AgentSessionParser.claude(tail: text(lines), fromStart: fromStart, sessionID: "s-example",
                                  modifiedAt: base.addingTimeInterval(now - age), now: base.addingTimeInterval(now), previous: previous)
    }

    static func claudeTurns() -> Bool {
        // end_turn 算本轮结束，完成标识是 message.id；同一条回复分两行写也只算一次。
        let done = claude([cUser(100), cAssistant(200, stop: "tool_use", id: "msg_1", block: "tool_use"), cToolResult(250),
                           cAssistant(400, stop: "end_turn", id: "msg_2", block: "thinking"), cAssistant(401, stop: "end_turn", id: "msg_2")])
        guard done.status == .finished, done.completion?.id == "msg_2", done.completion?.completedAt == base.addingTimeInterval(400),
              done.completion?.duration == 300 else { print("Claude end_turn：\(done)"); return false }
        // 停在 tool_use，后面有 tool_result：在跑。
        let tool = claude([cUser(100), cAssistant(200, stop: "tool_use", block: "tool_use"), cToolResult(250)])
        guard tool.status == .running, tool.completion == nil, tool.turnStartedAt == base.addingTimeInterval(100) else { return false }
        // end_turn 之后又来了新的提问：在跑；最新完成标识仍是上一轮的。
        let again = claude([cUser(100), cAssistant(200, stop: "end_turn", id: "msg_a"), cUser(300)])
        guard again.status == .running, again.completion?.id == "msg_a", again.turnStartedAt == base.addingTimeInterval(300) else { return false }
        // isMeta 的用户行（本地命令）不算新提问。
        let meta = claude([cUser(100), cAssistant(200, stop: "end_turn", id: "msg_a"), cUser(300, meta: true)])
        guard meta.status == .finished else { return false }
        // 尾部没有本轮开头：沿用上一次解析到的开始时间。
        let running = claude([cUser(100), cAssistant(200, stop: "tool_use", block: "tool_use")])
        let later = claude([cAssistant(500, stop: "end_turn", id: "msg_z")], previous: running)
        let tailOnly = claude(["{\"partial", cAssistant(500, stop: "end_turn", id: "msg_z")], fromStart: false, previous: running)
        return later.completion?.duration == 400 && tailOnly.completion?.duration == 400 && tailOnly.status == .finished
    }

    static func claudeDetails() -> Bool {
        // 侧链（子 Agent）行被忽略：主会话最后一条非侧链回复是 end_turn。
        let side = claude([cUser(100), cAssistant(200, stop: "end_turn", id: "msg_main"), cAssistant(300, stop: "tool_use", sidechain: true, block: "tool_use"),
                           cUser(310, sidechain: true)])
        guard side.status == .finished, side.completion?.id == "msg_main" else { return false }
        // 有 custom-title 用它；没有时用 cwd 的最后一段；尾部没有时沿用上一次的标题。
        let titled = claude([cTitle("示例标题"), cUser(100), cAssistant(200, stop: "end_turn")])
        let untitled = claude([cUser(100), cAssistant(200, stop: "end_turn")])
        let kept = claude([cAssistant(300, stop: "end_turn", id: "msg_k")], fromStart: false, previous: titled)
        guard titled.displayName == "示例标题", untitled.displayName == "demo-app", untitled.title == nil,
              kept.displayName == "示例标题" else { return false }
        // 用户中断：本轮结束，但没有新的完成标识，不会提示。
        let interrupted = claude([cUser(100), cAssistant(200, stop: "end_turn", id: "msg_old"), cUser(300),
                                  cAssistant(350, stop: "tool_use", id: "msg_new", block: "tool_use"), cInterrupt(360)])
        guard interrupted.status == .finished, interrupted.completion?.id == "msg_old" else { return false }
        var board = AgentSessionNoticeBoard(startedAt: base)
        board.update([claude([cUser(100), cAssistant(200, stop: "end_turn", id: "msg_old"), cUser(300)], now: 320)], now: base.addingTimeInterval(320))
        let before = board.notices.count
        board.update([interrupted], now: base.addingTimeInterval(370))
        guard board.notices.count == before else { return false }
        // 没有前一轮时中断也不产生完成。
        let bare = claude([cUser(100), cInterrupt(150)])
        return bare.status == .finished && bare.completion == nil
    }

    // MARK: - Codex 夹具

    static func xStarted(_ turn: String, _ t: TimeInterval) -> String {
        #"{"timestamp":"\#(iso(t))","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(turn)","started_at":\#(Int(base.timeIntervalSince1970 + t))}}"#
    }
    static func xComplete(_ turn: String, _ t: TimeInterval, start: TimeInterval) -> String {
        let s = Int(base.timeIntervalSince1970 + start), c = Int(base.timeIntervalSince1970 + t)
        return #"{"timestamp":"\#(iso(t))","type":"event_msg","payload":{"type":"task_complete","turn_id":"\#(turn)","started_at":\#(s),"completed_at":\#(c),"duration_ms":\#(Int((t - start) * 1000)),"last_agent_message":"示例回复正文"}}"#
    }
    static func xItem(_ turn: String, _ t: TimeInterval) -> String {
        #"{"timestamp":"\#(iso(t))","type":"event_msg","payload":{"type":"item_completed","turn_id":"\#(turn)","item":{"type":"agent_message","text":"示例正文"}}}"#
    }
    static func xAborted(_ turn: String, _ t: TimeInterval) -> String {
        #"{"timestamp":"\#(iso(t))","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"\#(turn)","reason":"interrupted"}}"#
    }
    static func xContext(_ turn: String, _ t: TimeInterval) -> String {
        #"{"timestamp":"\#(iso(t))","type":"turn_context","payload":{"turn_id":"\#(turn)","cwd":"/Users/example/work/notes-app"}}"#
    }
    static func xMeta(id: String, parent: String? = nil, role: String? = nil) -> String {
        #"{"timestamp":"\#(iso(0))","type":"session_meta","payload":{"id":"\#(id)","cwd":"/Users/example/work/sample-service","#
            + #""parent_thread_id":\#(parent.map { "\"\($0)\"" } ?? "null"),"agent_role":\#(role.map { "\"\($0)\"" } ?? "null"),"base_instructions":{"text":"示例指令"}}}"#
    }

    static func codex(_ lines: [String], meta: AgentSessionParser.CodexMeta? = nil, age: TimeInterval = 5, now: TimeInterval = 1000,
                      fromStart: Bool = true, previous: AgentSessionState? = nil, id: String = "t-example") -> AgentSessionState {
        AgentSessionParser.codex(tail: text(lines), fromStart: fromStart, sessionID: id, meta: meta,
                                 modifiedAt: base.addingTimeInterval(now - age), now: base.addingTimeInterval(now), previous: previous)
    }

    static func codexTurns() -> Bool {
        // task_started 没有配对：在跑；配对后：结束，耗时取 duration_ms。
        let running = codex([xStarted("turn-1", 100), xItem("turn-1", 150)])
        guard running.status == .running, running.turnStartedAt == base.addingTimeInterval(100), running.completion == nil else { return false }
        let done = codex([xStarted("turn-1", 100), xItem("turn-1", 150), xComplete("turn-1", 400, start: 100)])
        guard done.status == .finished, done.completion?.id == "turn-1", done.completion?.duration == 300,
              done.completion?.completedAt == base.addingTimeInterval(400) else { return false }
        // turn_id 不一致：最后开始的 turn-2 没有配对，仍在跑。
        let mismatch = codex([xStarted("turn-2", 100), xComplete("turn-x", 200, start: 50)])
        guard mismatch.status == .running else { return false }
        // 尾部只剩这一轮中间的行（开头的 task_started 不在尾部）：带 turn_id 的行说明在跑。
        let middle = codex([xItem("turn-3", 500), xItem("turn-3", 510)], fromStart: false)
        guard middle.status == .running else { return false }
        // 完成之后又写了同一轮的行：仍算结束。
        let late = codex([xStarted("turn-4", 100), xComplete("turn-4", 200, start: 100), xItem("turn-4", 201)])
        guard late.status == .finished else { return false }
        // 用户中断（turn_aborted）：结束，不产生完成标识。
        let aborted = codex([xStarted("turn-5", 100), xAborted("turn-5", 150)])
        guard aborted.status == .finished, aborted.completion == nil else { return false }
        // 新的一轮开始：最新完成标识仍是上一轮。
        let next = codex([xStarted("turn-6", 100), xComplete("turn-6", 200, start: 100), xContext("turn-7", 300), xStarted("turn-7", 300)])
        return next.status == .running && next.completion?.id == "turn-6" && next.project == "notes-app"
    }

    static func codexMeta() -> Bool {
        guard let parentMeta = AgentSessionParser.codexMeta(firstLine: Data(xMeta(id: "thread-parent").utf8)),
              let childMeta = AgentSessionParser.codexMeta(firstLine: Data(xMeta(id: "thread-child", parent: "thread-parent").utf8)),
              let roleMeta = AgentSessionParser.codexMeta(firstLine: Data(xMeta(id: "thread-role", role: "explorer").utf8)),
              AgentSessionParser.codexMeta(firstLine: Data(xStarted("turn-1", 0).utf8)) == nil,
              AgentSessionParser.codexMeta(firstLine: Data("{\"type\":\"session_meta\",\"payload\":".utf8)) == nil else { return false }
        guard !parentMeta.isChild, parentMeta.project == "sample-service", childMeta.isChild, childMeta.parentID == "thread-parent",
              roleMeta.isChild, roleMeta.parentID == nil else { return false }
        // 父线程 10 分钟没写，子线程刚写：合并后父线程仍在跑，子线程不单独计数。
        let parent = codex([xStarted("turn-1", 100)], meta: parentMeta, age: 700, id: "thread-parent")
        let child = codex([xStarted("turn-c", 300)], meta: childMeta, age: 3, id: "thread-child")
        guard parent.status == .stopped, child.parentID == "thread-parent" else { return false }
        let merged = AgentSessionSummary.merge([parent, child], now: base.addingTimeInterval(1000))
        guard merged.count == 1, merged[0].id == "thread-parent", merged[0].status == .running,
              merged[0].lastWriteAt == base.addingTimeInterval(997) else { return false }
        // 找不到父线程：按独立会话计数。
        let orphan = AgentSessionSummary.merge([child], now: base.addingTimeInterval(1000))
        guard orphan.count == 1, orphan[0].status == .running, orphan[0].parentID == nil else { return false }
        let snapshot = AgentSessionSnapshot(checkedAt: base, roots: [.claude: .missing, .codex: .ok], sessions: merged)
        guard snapshot.running(.codex) == 1, snapshot.runningTotal == 1, snapshot.installed, snapshot.readable else { return false }
        // 读不到 session_meta：名称取 turn_context 的目录名；也没有时写“Codex 会话”。
        let context = codex(["{\"partial", xContext("turn-1", 100), xStarted("turn-1", 100)], fromStart: false)
        let bare = codex([xStarted("turn-1", 100)], fromStart: false)
        return context.displayName == "notes-app" && bare.displayName == "Codex 会话" && bare.id == "t-example"
    }

    // MARK: - 公共

    static func robustness() -> Bool {
        let complete = cAssistant(200, stop: "end_turn", id: "msg_ok")
        // 第一行不完整（不从文件开头读起）：丢掉；最后一行写到一半：丢掉。
        let partialFirst = Data((String(cAssistant(100, stop: "tool_use").dropFirst(10)) + "\n" + complete + "\n").utf8)
        let s1 = AgentSessionParser.claude(tail: partialFirst, fromStart: false, sessionID: "s", modifiedAt: base.addingTimeInterval(995),
                                           now: base.addingTimeInterval(1000))
        guard s1.completion?.id == "msg_ok", s1.status == .finished else { return false }
        let halfLast = Data((complete + "\n" + String(cUser(300).prefix(40))).utf8)
        let s2 = AgentSessionParser.claude(tail: halfLast, fromStart: true, sessionID: "s", modifiedAt: base.addingTimeInterval(995),
                                           now: base.addingTimeInterval(1000))
        guard s2.status == .finished else { return false }
        guard AgentSessionParser.lines(Data("a\nb\nc".utf8), fromStart: false) == [Data("b".utf8)],
              AgentSessionParser.lines(Data("a\nb\n".utf8), fromStart: true) == [Data("a".utf8), Data("b".utf8)] else { return false }
        // 坏 JSON 行和字段类型不对的行跳过，不影响其他行。
        let bad = claude(["{not json", #"{"type":"assistant","timestamp":12,"message":"示例"}"#,
                          #"{"type":"assistant","isSidechain":"no","timestamp":"\#(iso(150))","message":{"stop_reason":7,"content":"示例"}}"#,
                          complete])
        guard bad.status == .finished, bad.completion?.id == "msg_ok" else { return false }
        // stop_reason 类型不对的那行算普通回复（在跑），之后的 end_turn 结束本轮。
        let wrongType = claude([#"{"type":"assistant","timestamp":"\#(iso(150))","message":{"stop_reason":7}}"#])
        guard wrongType.status == .running else { return false }
        let codexBad = codex(["[1,2]", #"{"type":"event_msg","payload":{"type":"task_started","turn_id":5}}"#, xStarted("turn-1", 100), "{{"])
        guard codexBad.status == .running else { return false }
        // 超长行（大于 64 KB）：尾部只有这一行的后半段，丢掉后没有判定依据，记为未确认。
        let long = Data((String(repeating: "x", count: AgentSessionParser.tailBytes) + "\n").utf8)
        let s3 = AgentSessionParser.claude(tail: long, fromStart: false, sessionID: "s", modifiedAt: base.addingTimeInterval(995),
                                           now: base.addingTimeInterval(1000))
        let s4 = AgentSessionParser.codex(tail: long, fromStart: false, sessionID: "t", meta: nil, modifiedAt: base.addingTimeInterval(995),
                                          now: base.addingTimeInterval(1000))
        guard s3.status == .unknown, s4.status == .unknown else { return false }
        // 空文件：未确认。
        let empty = AgentSessionParser.claude(tail: Data(), fromStart: true, sessionID: "s", modifiedAt: base, now: base)
        let emptyCodex = AgentSessionParser.codex(tail: Data(), fromStart: true, sessionID: "t", meta: nil, modifiedAt: base, now: base)
        return empty.status == .unknown && emptyCodex.status == .unknown && empty.completion == nil
    }

    static func timing() -> Bool {
        // 带时区偏移、带毫秒、不带毫秒都能解析。
        let a = AgentSessionParser.date("2027-01-15T08:00:00.123Z"), b = AgentSessionParser.date("2027-01-15T16:00:00.123+08:00")
        let c = AgentSessionParser.date("2027-01-15T08:00:00Z")
        guard let a, let b, let c, a == b, abs(a.timeIntervalSince(c) - 0.123) < 0.001,
              AgentSessionParser.date("2027-01-15 08:00") == nil, AgentSessionParser.date(nil) == nil else { return false }
        let offset = #"{"type":"assistant","timestamp":"2027-01-15T16:00:00+08:00","message":{"id":"msg_tz","stop_reason":"end_turn"}}"#
        guard claude([offset]).completion?.completedAt == c else { return false }
        // 10 分钟没有写入：已停止，不计数；正好 10 分钟仍算。
        let stale = claude([cUser(100), cAssistant(200, stop: "tool_use", block: "tool_use")], age: 601)
        let edge = claude([cUser(100), cAssistant(200, stop: "tool_use", block: "tool_use")], age: 600)
        guard stale.status == .stopped, edge.status == .running else { return false }
        // 尾部找不到依据：未确认，不计数，也不提示。
        let unknown = claude([cTitle("示例"), #"{"type":"attachment","timestamp":"\#(iso(10))"}"#])
        let snapshot = AgentSessionSnapshot(checkedAt: base, roots: [.claude: .ok, .codex: .ok], sessions: [unknown, edge, stale])
        guard unknown.status == .unknown, snapshot.runningTotal == 1, snapshot.unknownTotal == 1 else { return false }
        var board = AgentSessionNoticeBoard(startedAt: base)
        return board.update([unknown], now: base.addingTimeInterval(1000)).isEmpty
    }

    // MARK: - 提示

    static func session(_ id: String, _ status: AgentSessionStatus, completion: String? = nil, at: TimeInterval = 0, name: String = "示例项目",
                        provider: QuotaProvider = .codex, duration: TimeInterval? = 720, lastWrite: TimeInterval? = nil, now: TimeInterval) -> AgentSessionState {
        let done = completion.map { AgentSessionCompletion(id: $0, completedAt: base.addingTimeInterval(at), startedAt: nil, duration: duration) }
        let phase: AgentSessionStatus = status == .stopped ? .finished : status
        return AgentSessionState(provider: provider, id: id, project: name, phase: phase, completion: done,
                                 lastWriteAt: base.addingTimeInterval(lastWrite ?? (status == .stopped ? now - 700 : max(at, now - 5))),
                                 now: base.addingTimeInterval(now))
    }

    static func noticesOnce() -> Bool {
        let start: TimeInterval = 100
        var board = AgentSessionNoticeBoard(startedAt: base.addingTimeInterval(start))
        func check(_ sessions: [AgentSessionState], _ t: TimeInterval) -> Int { board.update(sessions, now: base.addingTimeInterval(t)).count }
        // 启动后第一次检查：之前完成的轮次只记录，不提示。
        guard check([session("a", .finished, completion: "c0", at: 50, now: 110), session("b", .running, now: 110)], 110) == 0 else { return false }
        // 在跑 → 结束：提示一次；再检查一次不重复。
        guard check([session("b", .finished, completion: "c1", at: 150, now: 160)], 160) == 1,
              check([session("b", .finished, completion: "c1", at: 150, now: 170)], 170) == 0 else { return false }
        // 同一会话新一轮开始再结束：再提示一次。
        guard check([session("b", .running, completion: "c1", at: 150, now: 180)], 180) == 0,
              check([session("b", .finished, completion: "c2", at: 190, now: 200)], 200) == 1 else { return false }
        // 前后两次都是结束，但完成标识不同（两次检查之间跑完一轮）：提示一次。
        guard check([session("b", .finished, completion: "c3", at: 205, now: 210)], 210) == 1 else { return false }
        // 新会话在两次检查之间开始又结束：提示一次。
        guard check([session("n", .finished, completion: "n1", at: 215, now: 220)], 220) == 1 else { return false }
        // 因读取预算延后一轮才读到：第一次是未确认，第二次读到完成，仍提示一次。
        guard check([session("d", .unknown, now: 230)], 230) == 0,
              check([session("d", .finished, completion: "d1", at: 225, now: 240)], 240) == 1,
              check([session("d", .finished, completion: "d1", at: 225, now: 250)], 250) == 0 else { return false }
        // 协调器开始运行前已完成的轮次（第一次见到）不提示。
        guard check([session("e", .finished, completion: "e1", at: 99, now: 260)], 260) == 0 else { return false }
        // 已停止的会话不提示。
        guard check([session("f", .stopped, completion: "f1", at: 255, now: 1000)], 1000) == 0 else { return false }
        // 同一渠道下不同会话的同名完成标识互不影响。
        return check([session("g", .finished, completion: "c1", at: 990, now: 1000)], 1000) == 1
    }

    static func noticeDisplay() -> Bool {
        var board = AgentSessionNoticeBoard(startedAt: base)
        board.update([session("a", .finished, completion: "a1", at: 10, name: "示例项目", now: 20)], now: base.addingTimeInterval(20))
        guard board.toasts.count == 1, case .single = board.toasts[0],
              board.toasts[0].text == "✓ 示例项目 · Codex · 已完成 · 12 分钟" else { return false }
        board.update([session("b", .finished, completion: "b1", at: 30, name: "notes-app", provider: .claude, duration: 180, now: 40)], now: base.addingTimeInterval(40))
        // 2 条：新的在第 0 条（贴着气泡）。
        guard board.toasts.map(\.text) == ["✓ notes-app · Claude · 已完成 · 3 分钟", "✓ 示例项目 · Codex · 已完成 · 12 分钟"] else { return false }
        // 3 条以上：离猫远的那条合并成“另有 n 个会话完成”。
        board.update([session("c", .finished, completion: "c1", at: 50, name: "示例三", duration: nil, now: 60),
                      session("d", .finished, completion: "d1", at: 55, name: "示例四", duration: 3900, now: 60)], now: base.addingTimeInterval(60))
        let toasts = board.toasts
        guard toasts.count == 2, toasts[0].text == "✓ 示例四 · Codex · 已完成 · 1 小时 5 分", toasts[1].text == "另有 3 个会话完成",
              toasts[1].ids.count == 3 else { return false }
        // 手动关闭：只关这一条；关掉合并的那条，它包含的全部关掉。
        board.dismiss(toasts[0].ids)
        guard board.toasts.map(\.text) == ["✓ 示例三 · Codex · 已完成", "另有 2 个会话完成"] else { return false }
        guard board.notices.count == 3 else { return false }
        board.dismiss(board.toasts[1].ids)
        guard board.notices.map(\.name) == ["示例三"] else { return false }
        // 5 分钟过期：到期前还在，到期时消失。
        guard board.nextExpiry == base.addingTimeInterval(360) else { return false }
        board.expire(now: base.addingTimeInterval(359))
        guard board.notices.count == 1 else { return false }
        board.expire(now: base.addingTimeInterval(360))
        return board.notices.isEmpty && board.nextExpiry == nil
    }

    static func privacy() -> Bool {
        let secret = "示例私密正文-7f3a"
        let lines = [
            #"{"type":"user","timestamp":"\#(iso(100))","cwd":"\#(cwd)","message":{"role":"user","content":"\#(secret)"}}"#,
            #"{"type":"assistant","timestamp":"\#(iso(200))","cwd":"\#(cwd)","message":{"id":"msg_p","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"\#(secret)"}}]}}"#,
            #"{"type":"user","timestamp":"\#(iso(210))","cwd":"\#(cwd)","message":{"role":"user","content":[{"type":"tool_result","content":"\#(secret)"}]}}"#,
            #"{"type":"assistant","timestamp":"\#(iso(300))","cwd":"\#(cwd)","message":{"id":"msg_q","stop_reason":"end_turn","content":[{"type":"text","text":"\#(secret)"}]}}"#,
            #"{"type":"last-prompt","lastPrompt":"\#(secret)","sessionId":"s"}"#,
        ]
        let state = claude(lines)
        let codexState = codex([xStarted("turn-1", 100),
                                #"{"timestamp":"\#(iso(150))","type":"response_item","payload":{"type":"function_call","turn_id":"turn-1","arguments":"\#(secret)"}}"#,
                                #"{"timestamp":"\#(iso(160))","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"\#(secret)","completed_at":\#(Int(base.timeIntervalSince1970) + 160)}}"#])
        var board = AgentSessionNoticeBoard(startedAt: base)
        board.update([state, codexState], now: base.addingTimeInterval(400))
        let dumps = [String(describing: state), String(describing: codexState), String(describing: board), String(reflecting: state)]
        guard state.status == .finished, codexState.status == .finished, board.notices.count == 2 else { return false }
        return dumps.allSatisfy { !$0.contains(secret) }
    }
}
