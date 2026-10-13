import Foundation

/// 只在用户指定的已有父目录下创建 mac；导出文件只追加，不使用临时文件或重命名。
public final class ProxyTrafficExporter {
    private let root: URL
    private let timeZone: TimeZone
    private let report: (String, Int) -> Void
    public init(root: URL, timeZone: TimeZone = .current, report: @escaping (String, Int) -> Void = { _, _ in }) {
        self.root = root; self.timeZone = timeZone; self.report = report
    }
    public func synchronize(rows: [ProxyTrafficRow], now: Date) throws {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else { throw ProxyTrafficStorageError.unsafeFile }
        let directory = root.appendingPathComponent("mac", isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ProxyTrafficStorageError.unsafeFile }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let cutoff = ProxyTrafficFiles.cutoff(now: now, timeZone: timeZone)
        let current = ProxyTrafficTime.start(now, timeZone: timeZone)
        var firstError: Error?
        for row in rows where (ProxyTrafficTime.day(row.hour) ?? "") >= cutoff && (row.date ?? .distantFuture) < current {
            do { try ProxyTrafficFiles.append(row, directory: directory, report: report) }
            catch { if firstError == nil { firstError = error }; report("export_append_failed", 1) }
        }
        // 失败小时仍保留在本地历史。下一次结算重新扫描，已有行不会重复。
        do { try ProxyTrafficFiles.trim(directory: directory, now: now, timeZone: timeZone) }
        catch { if firstError == nil { firstError = error }; report("export_retention_failed", 1) }
        if let firstError { throw firstError }
    }
}
