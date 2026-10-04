import Foundation
import MeowMacCore

/// 本地扫描 Claude 和 Codex 的会话记录，判断各渠道最近是否有写入（D8）。
///
/// 只读修改时间，不读文件内容，不写文件，不跟随目录内的符号链接。
public struct AgentActivityScanner {
    public static let activeWindow: TimeInterval = 120
    static let codexDateDirectories = 3

    private let claudeRoot: URL
    private let codexRoot: URL
    private let activeWindow: TimeInterval

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, activeWindow: TimeInterval = AgentActivityScanner.activeWindow) {
        claudeRoot = home.appendingPathComponent(".claude/projects", isDirectory: true)
        codexRoot = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        self.activeWindow = activeWindow
    }

    public func scan(now: Date) -> [QuotaProvider: AgentActivity] {
        [.claude: classify(latestClaudeWrite(), now: now), .codex: classify(latestCodexWrite(), now: now)]
    }

    private enum Latest {
        case none
        case at(Date)
        case unavailable
    }

    private func classify(_ latest: Latest, now: Date) -> AgentActivity {
        switch latest {
        case .none: return .idle
        case .unavailable: return .unavailable
        case .at(let date): return now.timeIntervalSince(date) < activeWindow ? .active : .idle
        }
    }

    private enum Root {
        case missing
        case directory(URL)
        case unusable
    }

    /// 根目录本身允许是符号链接（例如用 dotfiles 管理的 `~/.claude`），目录内部不跟随。
    private func resolve(_ root: URL) -> Root {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .unusable }
        return .directory(root.resolvingSymlinksInPath())
    }

    /// Claude 的 transcript 在 `projects/<项目>/` 下，子 Agent 的记录在 `<会话>/subagents/` 里，必须递归。
    private func latestClaudeWrite() -> Latest {
        switch resolve(claudeRoot) {
        case .missing: return .none
        case .unusable: return .unavailable
        case .directory(let root):
            guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) != nil else { return .unavailable }
            return newest(in: root, recursive: true)
        }
    }

    /// Codex 的 transcript 在 `sessions/年/月/日/` 下。按名称取最新的几个日期目录，不推算日期，不受时区影响。
    private func latestCodexWrite() -> Latest {
        switch resolve(codexRoot) {
        case .missing: return .none
        case .unusable: return .unavailable
        case .directory(let root):
            guard let years = children(of: root) else { return .unavailable }
            let dates = dateDirectories(root: root, years: years)
            if dates.isEmpty { return years.isEmpty ? .none : .unavailable }
            var latest: Date?
            for directory in dates.prefix(Self.codexDateDirectories) {
                if case .at(let date) = newest(in: directory, recursive: false), latest.map({ date > $0 }) ?? true { latest = date }
            }
            return latest.map(Latest.at) ?? .none
        }
    }

    /// 按年月日降序排列的日期目录。目录名不是数字的条目忽略。
    private func dateDirectories(root: URL, years: [String]) -> [URL] {
        var result: [(key: String, url: URL)] = []
        for year in years where isNumber(year, digits: 4) {
            let yearURL = root.appendingPathComponent(year, isDirectory: true)
            for month in children(of: yearURL) ?? [] where isNumber(month, digits: 2) {
                let monthURL = yearURL.appendingPathComponent(month, isDirectory: true)
                for day in children(of: monthURL) ?? [] where isNumber(day, digits: 2) {
                    result.append(("\(year)/\(month)/\(day)", monthURL.appendingPathComponent(day, isDirectory: true)))
                }
            }
        }
        return result.sorted { $0.key > $1.key }.map(\.url)
    }

    private func isNumber(_ name: String, digits: Int) -> Bool {
        name.count == digits && name.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    private func children(of directory: URL) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: directory.path).filter { !$0.hasPrefix(".") }
    }

    private func newest(in directory: URL, recursive: Bool) -> Latest {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let options: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: options,
                                                              errorHandler: { _, _ in true }) else { return .unavailable }
        var latest: Date?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true,
                  values.isRegularFile == true, let modified = values.contentModificationDate else { continue }
            if latest.map({ modified > $0 }) ?? true { latest = modified }
        }
        return latest.map(Latest.at) ?? .none
    }
}
