import Foundation
import MeowMacCore
import MeowMacSystem

/// 全部使用合成文件，不运行真实 Mole。
enum CleaningTests {
    static func paths() -> Bool {
        let defaultPath = LocalConfig().moPath
        let available = Set(["/usr/local/bin/mo", "/example/tools/mo"])
        let check = { available.contains($0) }
        return MoExecutable.resolve(configuredPath: defaultPath, searchPath: "/example/tools", isExecutable: check) == "/usr/local/bin/mo"
            && MoExecutable.resolve(configuredPath: defaultPath, searchPath: "/example/tools", isExecutable: { $0 == "/example/tools/mo" }) == "/example/tools/mo"
            && MoExecutable.resolve(configuredPath: "/missing/custom/mo", searchPath: "/example/tools", isExecutable: check) == nil
            && MoExecutable.resolve(configuredPath: defaultPath, searchPath: ":relative", isExecutable: { $0 == "relative/mo" }) == nil
            && MoExecutable.resolve(configuredPath: defaultPath, isExecutable: { $0 == defaultPath }) == defaultPath
    }

    static func filesAndHistory() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("tool with ' quote")
            try Data("#!/bin/sh\nprintf '%s' '{\"sessions\":[]}'\n".utf8).write(to: executable)
            guard !MoExecutable.usableFile(executable.path), !MoExecutable.usableFile(root.path) else { return false }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            guard MoExecutable.resolve(configuredPath: executable.path) == executable.path else { return false }
            switch try MoHistoryReader.read(configuredPath: executable.path) {
            case .available(nil): break
            default: return false
            }
            switch try MoHistoryReader.read(configuredPath: root.appendingPathComponent("missing").path) {
            case .notInstalled: return true
            default: return false
            }
        } catch { print("清理路径测试失败：\(error)"); return false }
    }
}
