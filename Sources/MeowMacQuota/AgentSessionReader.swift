import Foundation
import MeowMacCore

/// 读取 Claude 和 Codex 的本地会话记录，得到每个主会话的状态（D46，plan D7）。
///
/// - 列文件只看修改时间：Claude 递归扫描 `~/.claude/projects`；Codex 扫描 `~/.codex/sessions` 下全部日期目录，
///   目录列表按目录修改时间缓存。D8 的 `AgentActivityScanner` 不受影响。
/// - 只解析 10 分钟内有写入的文件，按（路径、大小、修改时间、inode）缓存结果；每个文件最多读末尾 64 KB。
/// - 每次检查最多新读 20 个文件，从新到旧；没读到的记为未确认，下次接着读。有缓存的文件不占预算。
/// - Codex 开头的 `session_meta` 每个文件只读一次，按路径和 inode 缓存；文件消失时清掉。
/// - 只读，不写任何文件；不跟随目录内的符号链接。不是线程安全的，由调用方放在同一个串行队列上使用。
public final class AgentSessionReader: @unchecked Sendable {
    public static let readBudget = 20
    /// 开头一行最多读这么多字节；超过时当作没有元数据。
    static let headLimit = 262_144

    /// 读取次数，供离线用例断言缓存是否生效。
    public struct Counters: Equatable, Sendable {
        public var tailReads = 0
        public var headReads = 0
        public var directoryListings = 0
    }
    public private(set) var counters = Counters()

    private let claudeRoot: URL
    private let codexRoot: URL
    private let budget: Int

    private struct FileInfo {
        let url: URL
        let modified: Date
        let size: Int
        /// 只对要判定的文件查 inode，其余文件只看修改时间。
        var inode: UInt64 = 0
    }
    /// 开头元数据的查找结果：已知（可能没有元数据），或预算用完还没读。
    private enum MetaLookup {
        case known(AgentSessionParser.CodexMeta?)
        case pending
    }
    private struct Parsed {
        let size: Int, modified: Date, inode: UInt64
        let state: AgentSessionState
    }
    private var parsed: [String: Parsed] = [:]
    private var metas: [String: (inode: UInt64, meta: AgentSessionParser.CodexMeta?)] = [:]
    private var dayListings: [String: (modified: Date, names: [String])] = [:]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, budget: Int = AgentSessionReader.readBudget) {
        claudeRoot = home.appendingPathComponent(".claude/projects", isDirectory: true)
        codexRoot = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.budget = budget
    }

    /// 两个渠道的记录根目录是否至少有一个存在（D11：都不存在算没装，目录里不列“AI 会话”）。只查目录是否存在，不读记录。
    public static func rootsExist(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        [".claude/projects", ".codex/sessions"].contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
    }

    /// 缓存的条目数（尾部解析加开头元数据），供离线用例断言文件消失后清掉。
    public var cachedFiles: Int { parsed.count + metas.count }

    /// 丢掉尾部解析的缓存，保留 Codex 开头元数据和目录列表。供实机测量单次读取的耗时。
    public func discardTailCache() { parsed.removeAll() }

    // MARK: - 读取

    public func read(now: Date) -> AgentSessionSnapshot {
        var roots: [QuotaProvider: AgentSessionRoot] = [:]
        var work: [(provider: QuotaProvider, info: FileInfo, lastWrite: Date)] = []
        var listed = Set<String>()
        var codexByID: [String: FileInfo] = [:]
        var codexPaths: [String: FileInfo] = [:]

        switch resolve(claudeRoot) {
        case .missing: roots[.claude] = .missing
        case .unusable: roots[.claude] = .unavailable
        case .directory(let root):
            if let files = listClaude(root: root) {
                roots[.claude] = .ok
                for (info, lastWrite) in files {
                    listed.insert(info.url.path)
                    if now.timeIntervalSince(lastWrite) <= AgentSessionParser.staleInterval { work.append((.claude, withInode(info), lastWrite)) }
                }
            } else { roots[.claude] = .unavailable }
        }
        switch resolve(codexRoot) {
        case .missing: roots[.codex] = .missing
        case .unusable: roots[.codex] = .unavailable
        case .directory(let root):
            if let files = listCodex(root: root) {
                roots[.codex] = .ok
                for info in files {
                    listed.insert(info.url.path)
                    codexByID[Self.threadID(info.url)] = info
                    codexPaths[info.url.path] = info
                    if now.timeIntervalSince(info.modified) <= AgentSessionParser.staleInterval { work.append((.codex, withInode(info), info.modified)) }
                }
            } else { roots[.codex] = .unavailable }
        }
        // 文件消失时清掉缓存。
        parsed = parsed.filter { listed.contains($0.key) }
        metas = metas.filter { listed.contains($0.key) }

        var remaining = budget
        var touched = Set<String>()
        func spend(_ path: String) -> Bool {
            if touched.contains(path) { return true }
            guard remaining > 0 else { return false }
            remaining -= 1; touched.insert(path); return true
        }

        var states: [AgentSessionState] = []
        var handled = Set<String>()
        var parents: [String: Date] = [:]
        for item in work.sorted(by: { $0.lastWrite > $1.lastWrite }) {
            let path = item.info.url.path
            if item.provider == .claude {
                states.append(state(claude: item.info, lastWrite: item.lastWrite, now: now, spend: spend))
                continue
            }
            handled.insert(path)
            guard case .known(let meta) = meta(item.info, spend: spend) else {
                // 预算用完、还没读开头：父子关系核实不到，按独立会话记为未确认。
                states.append(unknown(.codex, item.info, lastWrite: item.lastWrite, now: now)); continue
            }
            if let meta, meta.isChild, let parentID = meta.parentID {
                // 子线程不单独计数，只把写入时间交给父线程（plan D6）。父线程不在列表里时按独立会话计数。
                states.append(AgentSessionState(provider: .codex, id: meta.id ?? Self.threadID(item.info.url), phase: .unknown,
                                                lastWriteAt: item.lastWrite, parentID: parentID, now: now))
                if let parent = codexByID[parentID] {
                    parents[parent.url.path] = max(parents[parent.url.path] ?? .distantPast, item.lastWrite)
                } else {
                    states.removeLast()
                    states.append(state(codex: item.info, meta: meta, lastWrite: item.lastWrite, now: now, spend: spend))
                }
                continue
            }
            states.append(state(codex: item.info, meta: meta, lastWrite: item.lastWrite, now: now, spend: spend))
        }
        // 子线程刚写过、父线程本身超过 10 分钟没写：父线程也要判定，写入时间按子线程算。
        for (path, childWrite) in parents.sorted(by: { $0.value > $1.value }) where !handled.contains(path) {
            guard let listedInfo = codexPaths[path] else { continue }
            let info = withInode(listedInfo)
            let lastWrite = max(info.modified, childWrite)
            guard case .known(let meta) = meta(info, spend: spend) else { states.append(unknown(.codex, info, lastWrite: lastWrite, now: now)); continue }
            states.append(state(codex: info, meta: meta, lastWrite: lastWrite, now: now, spend: spend))
        }
        return AgentSessionSnapshot(checkedAt: now, roots: roots, sessions: AgentSessionSummary.merge(states, now: now))
    }

    private func unknown(_ provider: QuotaProvider, _ info: FileInfo, lastWrite: Date, now: Date) -> AgentSessionState {
        let previous = parsed[info.url.path]?.state
        let id = provider == .claude ? info.url.deletingPathExtension().lastPathComponent : (previous?.id ?? Self.threadID(info.url))
        return AgentSessionState(provider: provider, id: id, title: previous?.title, project: previous?.project, phase: .unknown,
                                 lastWriteAt: lastWrite, parentID: previous?.parentID, now: now)
    }

    private func cached(_ info: FileInfo) -> Parsed? {
        guard let entry = parsed[info.url.path], entry.size == info.size, entry.modified == info.modified, entry.inode == info.inode else { return nil }
        return entry
    }

    private func refreshed(_ state: AgentSessionState, lastWrite: Date, now: Date) -> AgentSessionState {
        var next = state
        next.lastWriteAt = lastWrite
        next.status = AgentSessionParser.status(phase: next.phase, lastWriteAt: lastWrite, now: now)
        return next
    }

    private func state(claude info: FileInfo, lastWrite: Date, now: Date, spend: (String) -> Bool) -> AgentSessionState {
        if let hit = cached(info) { return refreshed(hit.state, lastWrite: lastWrite, now: now) }
        guard spend(info.url.path), let tail = tail(info) else { return unknown(.claude, info, lastWrite: lastWrite, now: now) }
        let state = AgentSessionParser.claude(tail: tail.data, fromStart: tail.fromStart, sessionID: info.url.deletingPathExtension().lastPathComponent,
                                              modifiedAt: lastWrite, now: now, previous: parsed[info.url.path]?.state)
        parsed[info.url.path] = Parsed(size: info.size, modified: info.modified, inode: info.inode, state: state)
        return state
    }

    private func state(codex info: FileInfo, meta: AgentSessionParser.CodexMeta?, lastWrite: Date, now: Date,
                       spend: (String) -> Bool) -> AgentSessionState {
        if let hit = cached(info) { return refreshed(hit.state, lastWrite: lastWrite, now: now) }
        guard spend(info.url.path), let tail = tail(info) else { return unknown(.codex, info, lastWrite: lastWrite, now: now) }
        let state = AgentSessionParser.codex(tail: tail.data, fromStart: tail.fromStart, sessionID: Self.threadID(info.url), meta: meta,
                                             modifiedAt: lastWrite, now: now, previous: parsed[info.url.path]?.state)
        parsed[info.url.path] = Parsed(size: info.size, modified: info.modified, inode: info.inode, state: state)
        return state
    }

    /// 开头元数据：缓存里有（同一 inode）就用；否则在预算内读一次。返回 nil 表示预算用完、还没读。
    private func meta(_ info: FileInfo, spend: (String) -> Bool) -> MetaLookup {
        let path = info.url.path
        if let entry = metas[path], entry.inode == info.inode { return .known(entry.meta) }
        guard spend(path) else { return .pending }
        let meta = head(info).flatMap(AgentSessionParser.codexMeta(firstLine:))
        metas[path] = (info.inode, meta)
        return .known(meta)
    }

    // MARK: - 读文件（只读）

    private func tail(_ info: FileInfo) -> (data: Data, fromStart: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: info.url) else { return nil }
        defer { try? handle.close() }
        counters.tailReads += 1
        let offset = max(0, info.size - AgentSessionParser.tailBytes)
        do {
            try handle.seek(toOffset: UInt64(offset))
            return (try handle.read(upToCount: AgentSessionParser.tailBytes) ?? Data(), offset == 0)
        } catch { return nil }
    }

    private func head(_ info: FileInfo) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: info.url) else { return nil }
        defer { try? handle.close() }
        counters.headReads += 1
        var data = Data()
        while data.count < Self.headLimit {
            guard let chunk = try? handle.read(upToCount: 16_384), !chunk.isEmpty else { return nil }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                data.append(chunk[chunk.startIndex..<newline]); return data
            }
            data.append(chunk)
        }
        return nil
    }

    // MARK: - 列文件

    private enum Root { case missing, directory(URL), unusable }

    /// 根目录本身允许是符号链接，目录内部不跟随（同 `AgentActivityScanner`）。
    private func resolve(_ root: URL) -> Root {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .unusable }
        let resolved = root.resolvingSymlinksInPath()
        guard (try? FileManager.default.contentsOfDirectory(atPath: resolved.path)) != nil else { return .unusable }
        return .directory(resolved)
    }

    private static let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]

    private func info(_ url: URL) -> FileInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(Self.keys)), values.isSymbolicLink != true, values.isRegularFile == true,
              let modified = values.contentModificationDate else { return nil }
        return FileInfo(url: url, modified: modified, size: values.fileSize ?? 0)
    }

    private func withInode(_ info: FileInfo) -> FileInfo {
        var next = info
        next.inode = (try? FileManager.default.attributesOfItem(atPath: info.url.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return next
    }

    /// Claude 的主会话在 `<项目>/<会话>.jsonl`；子 Agent 在 `<项目>/<会话>/subagents/` 下，写入时间计入所属主会话（plan D6）。
    private func listClaude(root: URL) -> [(FileInfo, Date)]? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Self.keys, options: [.skipsHiddenFiles],
                                                              errorHandler: { _, _ in true }) else { return nil }
        let base = root.standardizedFileURL.pathComponents.count
        var mains: [String: FileInfo] = [:]
        var children: [String: Date] = [:]
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let info = info(url) else { continue }
            let parts = Array(url.standardizedFileURL.pathComponents.dropFirst(base))
            // 按相对路径对应主会话和子 Agent，不受根目录路径写法（例如 /var 与 /private/var）影响。
            if parts.count == 2 {
                mains[parts[0] + "/" + parts[1]] = info
            } else if parts.count >= 3 {
                let parent = parts[0] + "/" + parts[1] + ".jsonl"
                children[parent] = max(children[parent] ?? .distantPast, info.modified)
            }
        }
        return mains.map { key, info in (info, max(info.modified, children[key] ?? .distantPast)) }
    }

    /// Codex 的记录在 `sessions/年/月/日/` 下。扫描全部日期目录：旧日期目录里恢复的会话也会继续写入（plan D7）。
    private func listCodex(root: URL) -> [FileInfo]? {
        guard let years = children(of: root) else { return nil }
        var result: [FileInfo] = []
        var seenDays = Set<String>()
        for year in years where isNumber(year, digits: 4) {
            let yearURL = root.appendingPathComponent(year, isDirectory: true)
            guard isDirectory(yearURL) else { continue }
            for month in children(of: yearURL) ?? [] where isNumber(month, digits: 2) {
                let monthURL = yearURL.appendingPathComponent(month, isDirectory: true)
                guard isDirectory(monthURL) else { continue }
                for day in children(of: monthURL) ?? [] where isNumber(day, digits: 2) {
                    let dayURL = monthURL.appendingPathComponent(day, isDirectory: true)
                    guard isDirectory(dayURL), let modified = try? dayURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    else { continue }
                    seenDays.insert(dayURL.path)
                    let names: [String]
                    if let cached = dayListings[dayURL.path], cached.modified == modified { names = cached.names }
                    else {
                        counters.directoryListings += 1
                        names = (children(of: dayURL) ?? []).filter { $0.hasSuffix(".jsonl") }
                        dayListings[dayURL.path] = (modified, names)
                    }
                    result += names.compactMap { info(dayURL.appendingPathComponent($0)) }
                }
            }
        }
        dayListings = dayListings.filter { seenDays.contains($0.key) }
        return result
    }

    /// 目录且不是符号链接。
    private func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isNumber(_ name: String, digits: Int) -> Bool {
        name.count == digits && name.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    private func children(of directory: URL) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
    }

    /// 文件名 `rollout-<时间>-<线程 id>.jsonl` 里的线程 id；不是这个格式时用整个文件名。
    static func threadID(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count > 36 else { return name }
        let id = String(name.suffix(36))
        return id.filter { $0 == "-" }.count == 4 ? id : name
    }
}
