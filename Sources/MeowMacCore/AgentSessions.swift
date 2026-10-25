import Foundation

/// 一个会话这一刻的状态（D46，plan D5）。
public enum AgentSessionStatus: String, Equatable, Sendable {
    /// 本轮还没结束。
    case running
    /// 本轮已结束（正常结束或被用户中断）。
    case finished
    /// 超过 10 分钟没有写入，不计数，也不提示。
    case stopped
    /// 尾部找不到判定依据，或还没读到（读取预算），不计数，也不提示（plan D7）。
    case unknown
}

/// 一次本轮结束：完成标识、完成时间和本轮开始时间（plan D5a）。
public struct AgentSessionCompletion: Equatable, Sendable {
    /// Codex 是 `task_complete` 的 `turn_id`；Claude 是 `end_turn` 那条回复的 `message.id`（没有时用这一行的 `uuid`）。
    public let id: String
    public let completedAt: Date
    public let startedAt: Date?
    /// 本轮耗时（秒）；Codex 取 `duration_ms`，Claude 取开始和结束的时间差。不知道开始时间时为 nil。
    public let duration: TimeInterval?
    public init(id: String, completedAt: Date, startedAt: Date?, duration: TimeInterval?) {
        self.id = id; self.completedAt = completedAt; self.startedAt = startedAt; self.duration = duration
    }
}

/// 一个会话的状态。只含类型、时间、标识、标题和项目目录名，不含消息正文、工具输入输出和提示词（plan D8）。
public struct AgentSessionState: Equatable, Sendable {
    public let provider: QuotaProvider
    /// 会话标识：Claude 是记录文件名（会话 id），Codex 是线程 id。
    public let id: String
    /// 会话标题（Claude 的 `custom-title`）；没有时为 nil。
    public var title: String?
    /// 项目目录的最后一段。
    public var project: String?
    public var status: AgentSessionStatus
    /// 尾部读到的最新一次本轮结束。
    public var completion: AgentSessionCompletion?
    /// 正在跑的这一轮的开始时间；不知道时为 nil。
    public var turnStartedAt: Date?
    /// 记录文件最后写入的时间。Claude 含子 Agent 记录，Codex 含子线程。
    public var lastWriteAt: Date
    /// 所属主会话；nil 表示主会话（plan D6）。
    public var parentID: String?
    /// 尾部的判定依据（不含是否超时）。合并子线程后据此重新判定。
    public var phase: AgentSessionStatus

    public init(provider: QuotaProvider, id: String, title: String? = nil, project: String? = nil, phase: AgentSessionStatus,
                completion: AgentSessionCompletion? = nil, turnStartedAt: Date? = nil, lastWriteAt: Date, parentID: String? = nil,
                now: Date) {
        self.provider = provider; self.id = id; self.title = title; self.project = project; self.phase = phase
        self.completion = completion; self.turnStartedAt = turnStartedAt; self.lastWriteAt = lastWriteAt; self.parentID = parentID
        status = AgentSessionParser.status(phase: phase, lastWriteAt: lastWriteAt, now: now)
    }

    /// 提示和悬停里的名称：标题，没有就取项目目录名，再没有就写“渠道 会话”。
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        if let project, !project.isEmpty { return project }
        return provider.displayName + " 会话"
    }
    public var key: String { provider.rawValue + ":" + id }
}

/// 两个渠道记录根目录的情况：没装（不存在）、能读、读不了。
public enum AgentSessionRoot: String, Equatable, Sendable {
    case missing, ok, unavailable
}

/// 一次检查的结果：每个渠道的根目录情况和合并后的主会话。
public struct AgentSessionSnapshot: Equatable, Sendable {
    public static let providers: [QuotaProvider] = [.claude, .codex]
    public var checkedAt: Date
    public var roots: [QuotaProvider: AgentSessionRoot]
    /// 合并子会话后的主会话（plan D6）。
    public var sessions: [AgentSessionState]
    public init(checkedAt: Date, roots: [QuotaProvider: AgentSessionRoot], sessions: [AgentSessionState]) {
        self.checkedAt = checkedAt; self.roots = roots; self.sessions = sessions
    }

    public func running(_ provider: QuotaProvider) -> Int { sessions.filter { $0.provider == provider && $0.status == .running }.count }
    public var runningTotal: Int { sessions.filter { $0.status == .running }.count }
    public var unknownTotal: Int { sessions.filter { $0.status == .unknown }.count }
    /// 有一个渠道的根目录存在就算装了。
    public var installed: Bool { roots.values.contains { $0 != .missing } }
    /// 两个渠道都读不了（含一个没装、一个读不了），按 D2 写“—”。
    public var readable: Bool { roots.values.contains(.ok) }
}

/// 会话记录尾部的判定（plan D5、D6、D8）。全部是纯函数：输入尾部文本、开头元数据和修改时间，输出会话状态。
/// 只解码判定需要的字段；坏行、字段缺失或类型不对的行跳过。
public enum AgentSessionParser {
    /// 超过 10 分钟没有写入算已停止。
    public static let staleInterval: TimeInterval = 600
    /// 每个文件最多读末尾 64 KB。
    public static let tailBytes = 65_536

    public static func status(phase: AgentSessionStatus, lastWriteAt: Date, now: Date) -> AgentSessionStatus {
        now.timeIntervalSince(lastWriteAt) > staleInterval ? .stopped : phase
    }

    /// 切成完整的行：不从文件开头读起时丢掉第一行（多半不完整），末尾没有换行的一行还没写完，也丢掉。
    public static func lines(_ tail: Data, fromStart: Bool) -> [Data] {
        var parts = tail.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if !fromStart, !parts.isEmpty { parts.removeFirst() }
        if !parts.isEmpty, tail.last != UInt8(ascii: "\n") { parts.removeLast() }
        return parts.filter { !$0.isEmpty }.map { Data($0) }
    }

    // MARK: - 时间

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    /// ISO 8601，带不带毫秒、`Z` 或时区偏移都可以。
    public static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return fractional.date(from: text) ?? whole.date(from: text)
    }

    static func lastComponent(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    // MARK: - Claude

    /// 只取类型、时间戳、`stop_reason`、`message.id`、内容块的类型、标题、`cwd` 和侧链标记，不取正文。
    struct ClaudeLine: Decodable {
        let type: String?
        let uuid: String?
        let timestamp: String?
        let isSidechain: Bool?
        let isMeta: Bool?
        let isApiErrorMessage: Bool?
        let cwd: String?
        let customTitle: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let stopReason: String?
            /// 内容块的类型；内容是字符串时记为 `text`。
            let kinds: [String]
            enum CodingKeys: String, CodingKey { case id, stopReason = "stop_reason", content }
            struct Block: Decodable { let type: String? }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try? c.decodeIfPresent(String.self, forKey: .id)
                stopReason = try? c.decodeIfPresent(String.self, forKey: .stopReason)
                if let blocks = try? c.decodeIfPresent([Block].self, forKey: .content) { kinds = blocks.compactMap(\.type) }
                else if c.contains(.content), (try? c.decodeNil(forKey: .content)) == false { kinds = ["text"] }
                else { kinds = [] }
            }
        }

        enum CodingKeys: String, CodingKey { case type, uuid, timestamp, isSidechain, isMeta, isApiErrorMessage, cwd, customTitle, message }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            uuid = try? c.decodeIfPresent(String.self, forKey: .uuid)
            timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
            isSidechain = try? c.decodeIfPresent(Bool.self, forKey: .isSidechain)
            isMeta = try? c.decodeIfPresent(Bool.self, forKey: .isMeta)
            isApiErrorMessage = try? c.decodeIfPresent(Bool.self, forKey: .isApiErrorMessage)
            cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
            customTitle = try? c.decodeIfPresent(String.self, forKey: .customTitle)
            message = try? c.decodeIfPresent(Message.self, forKey: .message)
        }
    }

    /// Claude Code 在用户中断时写入的固定标记。只在原始字节里查找，不解码正文。
    static let claudeInterruptMarker = Data(#""text":"[Request interrupted by user"#.utf8)

    /// Claude 主会话：最后一条非侧链回复的 `stop_reason == end_turn`，且之后没有新的用户输入，算本轮结束；否则算在跑。
    /// 用户中断（固定标记）和 API 错误回复也算本轮结束，但不产生完成标识，所以不提示。
    /// `previous` 是同一文件上一次的解析结果，尾部没有标题或开始时间时沿用。
    public static func claude(tail: Data, fromStart: Bool, sessionID: String, modifiedAt: Date, now: Date,
                              previous: AgentSessionState? = nil) -> AgentSessionState {
        var phase: AgentSessionStatus = .unknown
        var completion: AgentSessionCompletion?
        var turnStart: Date?
        var title: String?, project: String?
        let decoder = JSONDecoder()
        for raw in lines(tail, fromStart: fromStart) {
            guard let line = try? decoder.decode(ClaudeLine.self, from: raw) else { continue }
            if line.type == "custom-title", let value = line.customTitle, !value.isEmpty { title = value; continue }
            if let name = lastComponent(line.cwd), line.isSidechain != true { project = name }
            guard line.isSidechain != true else { continue }
            let at = date(line.timestamp)
            switch line.type {
            case "assistant":
                guard let message = line.message else { continue }
                if message.stopReason == "end_turn" {
                    phase = .finished
                    let id = message.id?.isEmpty == false ? message.id! : line.uuid ?? ""
                    guard !id.isEmpty, let at else { continue }
                    // 同一条回复可能分几行写（思考和正文各一行），完成标识取 `message.id`，不重复计。
                    if completion?.id != id {
                        let start = turnStart ?? (previous?.phase == .running ? previous?.turnStartedAt : nil)
                        completion = AgentSessionCompletion(id: id, completedAt: at, startedAt: start,
                                                            duration: start.map { max(0, at.timeIntervalSince($0)) })
                    }
                } else if line.isApiErrorMessage == true {
                    phase = .finished
                } else {
                    phase = .running
                }
            case "user":
                guard line.isMeta != true else { continue }
                if raw.range(of: claudeInterruptMarker) != nil { phase = .finished; turnStart = nil; continue }
                let kinds = line.message?.kinds ?? []
                let toolResult = !kinds.isEmpty && kinds.allSatisfy { $0 == "tool_result" }
                // 新的提问开始新一轮；在跑时插进来的提问不改开始时间。
                if !toolResult, phase != .running || turnStart == nil { turnStart = at }
                phase = .running
            default:
                continue
            }
        }
        var started: Date?
        if phase == .running {
            started = turnStart ?? (previous?.phase == .running ? previous?.turnStartedAt : nil)
        }
        return AgentSessionState(provider: .claude, id: sessionID, title: title ?? previous?.title, project: project ?? previous?.project,
                                 phase: phase, completion: completion ?? (phase == .unknown ? nil : previous?.completion),
                                 turnStartedAt: started, lastWriteAt: modifiedAt, now: now)
    }

    // MARK: - Codex

    /// Codex 文件开头一行 `session_meta` 里需要的部分：线程 id、目录和父线程。
    public struct CodexMeta: Equatable, Sendable {
        public let id: String?
        public let project: String?
        public let parentID: String?
        /// 父线程非空，或 `agent_role` 有值，或 `source` 写明是子 Agent。
        public let isChild: Bool
        public init(id: String?, project: String?, parentID: String?, isChild: Bool) {
            self.id = id; self.project = project; self.parentID = parentID; self.isChild = isChild
        }
    }

    struct CodexMetaLine: Decodable {
        let type: String?
        let payload: Payload?
        struct Payload: Decodable {
            let id: String?, cwd: String?, parent: String?, role: String?, subagentSource: Bool
            enum CodingKeys: String, CodingKey { case id, cwd, parent = "parent_thread_id", role = "agent_role", source }
            enum SourceKeys: String, CodingKey { case subagent }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try? c.decodeIfPresent(String.self, forKey: .id)
                cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
                parent = try? c.decodeIfPresent(String.self, forKey: .parent)
                role = try? c.decodeIfPresent(String.self, forKey: .role)
                subagentSource = (try? c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source))?.contains(.subagent) ?? false
            }
        }
    }

    /// 解析开头一行。不是 `session_meta` 或坏行时返回 nil。
    public static func codexMeta(firstLine: Data) -> CodexMeta? {
        guard let line = try? JSONDecoder().decode(CodexMetaLine.self, from: firstLine), line.type == "session_meta",
              let payload = line.payload else { return nil }
        let parent = payload.parent?.isEmpty == false ? payload.parent : nil
        let child = parent != nil || payload.role?.isEmpty == false || payload.subagentSource
        return CodexMeta(id: payload.id, project: lastComponent(payload.cwd), parentID: parent, isChild: child)
    }

    struct CodexLine: Decodable {
        let type: String?
        let timestamp: String?
        let payload: Payload?
        struct Payload: Decodable {
            let type: String?, turnID: String?, cwd: String?
            let startedAt: Double?, completedAt: Double?, durationMS: Double?
            enum CodingKeys: String, CodingKey {
                case type, turnID = "turn_id", cwd, startedAt = "started_at", completedAt = "completed_at", durationMS = "duration_ms"
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                type = try? c.decodeIfPresent(String.self, forKey: .type)
                turnID = try? c.decodeIfPresent(String.self, forKey: .turnID)
                cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
                startedAt = try? c.decodeIfPresent(Double.self, forKey: .startedAt)
                completedAt = try? c.decodeIfPresent(Double.self, forKey: .completedAt)
                durationMS = try? c.decodeIfPresent(Double.self, forKey: .durationMS)
            }
        }
        enum CodingKeys: String, CodingKey { case type, timestamp, payload }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
            payload = try? c.decodeIfPresent(Payload.self, forKey: .payload)
        }
    }

    /// `started_at`、`completed_at` 是秒；超过 10^11 时按毫秒处理。
    static func epoch(_ value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    /// Codex 线程：最后一个开始的轮次（`task_started`，或带 `turn_id` 的其他行）有对应的 `task_complete` 就算结束，否则算在跑。
    /// `turn_aborted`（用户中断）也算结束，但不产生完成标识。
    /// 名称没有标题可取：取开头元数据或 `turn_context` 里的目录名，都没有时写“Codex 会话”。
    public static func codex(tail: Data, fromStart: Bool, sessionID: String, meta: CodexMeta?, modifiedAt: Date, now: Date,
                             previous: AgentSessionState? = nil) -> AgentSessionState {
        var active: String?
        var ended = Set<String>()
        var evidence = false
        var completion: AgentSessionCompletion?
        var starts: [String: Date] = [:]
        var project: String?
        let decoder = JSONDecoder()
        for raw in lines(tail, fromStart: fromStart) {
            guard let line = try? decoder.decode(CodexLine.self, from: raw), let payload = line.payload else { continue }
            if line.type == "turn_context", let name = lastComponent(payload.cwd) { project = name }
            let at = date(line.timestamp)
            let turn = payload.turnID?.isEmpty == false ? payload.turnID : nil
            if line.type == "event_msg" {
                switch payload.type {
                case "task_started":
                    evidence = true
                    guard let turn else { continue }
                    active = turn
                    if let start = epoch(payload.startedAt) ?? at { starts[turn] = start }
                    continue
                case "task_complete":
                    evidence = true
                    let id = turn ?? active
                    if let id {
                        ended.insert(id)
                        if active == id { active = nil }
                        if let done = epoch(payload.completedAt) ?? at {
                            let start = epoch(payload.startedAt) ?? starts[id]
                                ?? (previous?.phase == .running ? previous?.turnStartedAt : nil)
                            let duration = payload.durationMS.map { $0 / 1000 } ?? start.map { max(0, done.timeIntervalSince($0)) }
                            completion = AgentSessionCompletion(id: id, completedAt: done, startedAt: start, duration: duration)
                        }
                    } else { active = nil }
                    continue
                case "turn_aborted":
                    evidence = true
                    if let id = turn ?? active { ended.insert(id); if active == id { active = nil } } else { active = nil }
                    continue
                default: break
                }
            }
            // 其他带 `turn_id` 的行（工具调用、令牌用量、`turn_context`）说明这一轮还在进行。
            if let turn, !ended.contains(turn) {
                evidence = true
                if active != turn { active = turn; if starts[turn] == nil, let at { starts[turn] = at } }
            }
        }
        let phase: AgentSessionStatus = active != nil ? .running : evidence ? .finished : .unknown
        var started: Date?
        if let active {
            started = starts[active]
            if previous?.phase == .running, let earlier = previous?.turnStartedAt { started = min(started ?? earlier, earlier) }
        }
        return AgentSessionState(provider: .codex, id: meta?.id ?? sessionID, title: nil,
                                 project: meta?.project ?? project ?? previous?.project, phase: phase,
                                 completion: completion ?? (phase == .unknown ? nil : previous?.completion),
                                 turnStartedAt: started, lastWriteAt: modifiedAt,
                                 parentID: meta?.isChild == true ? meta?.parentID : nil, now: now)
    }
}

/// 汇总（plan D6）：子会话合并到父会话，子会话的写入时间计入父会话的 10 分钟判定；找不到父会话的按独立会话计数。
public enum AgentSessionSummary {
    public static func merge(_ states: [AgentSessionState], now: Date) -> [AgentSessionState] {
        var mains: [String: AgentSessionState] = [:]
        var order: [String] = []
        for state in states where state.parentID == nil {
            if mains[state.key] == nil { order.append(state.key) }
            mains[state.key] = state
        }
        var orphans: [AgentSessionState] = []
        for child in states {
            guard let parent = child.parentID else { continue }
            let key = child.provider.rawValue + ":" + parent
            if var main = mains[key] {
                main.lastWriteAt = max(main.lastWriteAt, child.lastWriteAt)
                mains[key] = main
            } else {
                orphans.append(child)
            }
        }
        var result = order.compactMap { mains[$0] }
        // 核实不到父会话：按独立会话计数，按自己的尾部判定。
        result += orphans.map { var s = $0; s.parentID = nil; return s }
        return result.map { var s = $0; s.status = AgentSessionParser.status(phase: s.phase, lastWriteAt: s.lastWriteAt, now: now); return s }
    }
}
