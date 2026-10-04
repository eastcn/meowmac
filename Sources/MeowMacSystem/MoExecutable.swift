import Foundation
import MeowMacCore

/// 清理与历史共用路径解析。只检测文件，不执行探测命令。
public enum MoExecutable {
    public static func resolve(configuredPath: String, searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                               isExecutable: (String) -> Bool = usableFile) -> String? {
        if configuredPath.hasPrefix("/"), isExecutable(configuredPath) { return configuredPath }
        // 用户指定的路径失败时不替换，避免误用另一份工具。
        guard configuredPath == LocalConfig().moPath else { return nil }
        let candidates = ["/usr/local/bin/mo"] + searchPath.split(separator: ":").compactMap { component -> String? in
            guard component.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: String(component), isDirectory: true).appendingPathComponent("mo").path
        }
        return candidates.first(where: isExecutable)
    }

    public static func usableFile(_ path: String) -> Bool {
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}

public enum CleaningHistoryResult {
    case notInstalled
    case available(CleaningRecord?)
}
