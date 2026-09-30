import Foundation
import Darwin
import MeowMacCore

/// 只读目录项和文件元数据。采用已分配字节，与 du 的统计口径相同。
public enum LocalStorageCollector {
    public static func scan(directory: URL, provider: QuotaProvider, now: Date = Date()) throws -> LocalStorageSnapshot {
        var sessions: UInt64 = 0, cache: UInt64 = 0, other: UInt64 = 0, count = 0
        var seen: Set<String> = []
        let sessionDirectories: Set<String> = provider == .codex ? ["sessions", "archived_sessions"] : ["projects", "sessions"]
        let cacheDirectories: Set<String> = provider == .claude ? ["cache", "file-history"] : ["cache"]
        func visit(_ url: URL, section: String) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let regular = (info.st_mode & S_IFMT) == S_IFREG
            let folder = (info.st_mode & S_IFMT) == S_IFDIR
            if regular && sessionDirectories.contains(section) { count += 1 }
            let key = "\(info.st_dev):\(info.st_ino)"
            if seen.insert(key).inserted {
                let size = UInt64(max(0, info.st_blocks)) * 512
                if sessionDirectories.contains(section) { sessions += size }
                else if cacheDirectories.contains(section) { cache += size }
                else { other += size }
            }
            if folder {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, section: section.isEmpty ? child.lastPathComponent : section)
                }
            }
        }
        try visit(directory, section: "")
        return LocalStorageSnapshot(sampledAt: now, sessionsBytes: sessions, cacheBytes: cache,
                                    otherBytes: other, sessionFileCount: count)
    }
}
