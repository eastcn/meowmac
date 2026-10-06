import Foundation
import MeowMacCore
import os

public struct AIAgentInstallation: Equatable {
    public let agent: AIAgent
    public let location: URL
    public init(agent: AIAgent, location: URL) { self.agent = agent; self.location = location }
    public func displayDirectory(home: String) -> String? {
        guard agent.executableName != nil else { return nil }
        let directory = location.deletingLastPathComponent().path
        if directory == home { return "~" }
        return directory.hasPrefix(home + "/") ? "~" + directory.dropFirst(home.count) : directory
    }
}

/// 目录白名单，不执行 CLI，不读取 shell 配置，也不依赖 GUI 进程的 PATH。
public struct AIAgentDetector {
    private let home: String
    private let isExecutable: (String) -> Bool
    private let nodeVersions: (String) -> [String]
    private let findApplication: (String) -> URL?
    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                isExecutable: @escaping (String) -> Bool = { path in
                    var directory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                        && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
                }, nodeVersions: @escaping (String) -> [String] = { path in
                    do { return try FileManager.default.contentsOfDirectory(atPath: path) }
                    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
                    catch {
                        Logger(subsystem: AppIdentity.bundleID, category: "ai-agent").error("nvm 目录检测失败：\(error.localizedDescription, privacy: .private)")
                        return []
                    }
                },
                findApplication: @escaping (String) -> URL?) {
        self.home = home; self.isExecutable = isExecutable; self.nodeVersions = nodeVersions; self.findApplication = findApplication
    }
    public func detect() -> [AIAgentInstallation] {
        let nodeRoot = home + "/.nvm/versions/node"
        let versions = nodeVersions(nodeRoot).filter { $0.range(of: #"^v?\d+(\.\d+)*$"#, options: .regularExpression) != nil }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        let directories = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.npm-global/bin",
                           home + "/.bun/bin", home + "/.claude/local"] + versions.map { nodeRoot + "/" + $0 + "/bin" }
        return AIAgent.agents.compactMap { agent in
            if let name = agent.executableName {
                return directories.map { $0 + "/" + name }.first(where: isExecutable)
                    .map { AIAgentInstallation(agent: agent, location: URL(fileURLWithPath: $0)) }
            }
            return agent.bundleIDs.compactMap(findApplication).first.map { AIAgentInstallation(agent: agent, location: $0) }
        }
    }
}
