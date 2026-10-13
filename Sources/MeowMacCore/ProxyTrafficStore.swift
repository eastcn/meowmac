import Foundation
import Darwin

public enum ProxyTrafficStorageError: Error {
    case unsafeFile, invalidRow, shortWrite, system(Int32)
}

/// 所有读写由采集协调器的串行队列调用。坏行跳过并计数，读取失败直接报告。
public protocol ProxyTrafficStoring {
    func loadCheckpoint() throws -> Data?
    func saveCheckpoint(_ data: Data) throws
    func append(_ row: ProxyTrafficRow) throws
    func loadRows(now: Date) throws -> [ProxyTrafficRow]
    func trim(now: Date) throws
}

public final class ProxyTrafficStore: ProxyTrafficStoring {
    public static var defaultDirectory: URL {
        ConfigStore.defaultURL.deletingLastPathComponent().appendingPathComponent("history/proxy-traffic", isDirectory: true)
    }
    public let directory: URL
    private let timeZone: TimeZone
    private let report: (String, Int) -> Void
    public init(directory: URL = defaultDirectory, timeZone: TimeZone = .current,
                report: @escaping (String, Int) -> Void = { _, _ in }) {
        self.directory = directory; self.timeZone = timeZone; self.report = report
    }
    public func loadCheckpoint() throws -> Data? {
        try ProxyTrafficFiles.readIfPresent(directory.appendingPathComponent("checkpoint.json"))
    }
    public func saveCheckpoint(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("checkpoint.json")
        // 已存在但不可读取的文件不能当作缺失，更不能覆盖符号链接。
        _ = try ProxyTrafficFiles.readIfPresent(target)
        let temporary = directory.appendingPathComponent("checkpoint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProxyTrafficStorageError.system(errno) }
        do {
            try ProxyTrafficFiles.writeOnce(data, fd: fd)
            guard Darwin.fsync(fd) == 0 else { throw ProxyTrafficStorageError.system(errno) }
        } catch { Darwin.close(fd); throw error }
        Darwin.close(fd)
        guard Darwin.rename(temporary.path, target.path) == 0 else { throw ProxyTrafficStorageError.system(errno) }
        let parent = Darwin.open(directory.path, O_RDONLY)
        guard parent >= 0 else { throw ProxyTrafficStorageError.system(errno) }
        defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0 else { throw ProxyTrafficStorageError.system(errno) }
    }
    public func append(_ row: ProxyTrafficRow) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ProxyTrafficFiles.append(row, directory: directory, report: report)
    }
    public func loadRows(now: Date) throws -> [ProxyTrafficRow] {
        try ProxyTrafficFiles.load(directory: directory, now: now, timeZone: timeZone, report: report)
    }
    public func trim(now: Date) throws {
        try ProxyTrafficFiles.trim(directory: directory, now: now, timeZone: timeZone)
    }
}

/// 本地和导出共用同一追加路径；完整扫描日文件，不截取尾部，也不覆盖已有行。
public enum ProxyTrafficFiles {
    static func readIfPresent(_ url: URL) throws -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ProxyTrafficStorageError.system(errno)
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ProxyTrafficStorageError.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }
    static func writeOnce(_ data: Data, fd: Int32) throws {
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard count >= 0 else { throw ProxyTrafficStorageError.system(errno) }
        guard count == data.count else { throw ProxyTrafficStorageError.shortWrite }
    }
    public static func append(_ row: ProxyTrafficRow, directory: URL,
                              report: (String, Int) -> Void = { _, _ in }) throws {
        let encoded = try row.encoded()
        guard row.source == "mac", let day = ProxyTrafficTime.day(row.hour), let date = row.date else {
            throw ProxyTrafficStorageError.invalidRow
        }
        let path = directory.appendingPathComponent(day + ".jsonl")
        let old = try readIfPresent(path) ?? Data()
        let existing = decode(old, day: day, report: report)
        let fd = Darwin.open(path.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ProxyTrafficStorageError.system(errno) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ProxyTrafficStorageError.unsafeFile }
        if !existing.contains(where: { $0.date == date }) {
            var payload = Data()
            if !old.isEmpty && old.last != 10 { payload.append(10) }
            payload.append(encoded); payload.append(10)
            try writeOnce(payload, fd: fd)
        }
        // 上次追加成功但 fsync 失败时，重试持久化；不再追加同一小时。
        guard Darwin.fsync(fd) == 0 else { throw ProxyTrafficStorageError.system(errno) }
    }
    public static func decode(_ data: Data, day: String, report: (String, Int) -> Void = { _, _ in }) -> [ProxyTrafficRow] {
        var rows: [ProxyTrafficRow] = [], seen = Set<Date>(), bad = 0, duplicate = 0
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if data.isEmpty { lines = [] }
        else if data.last == 10 { lines.removeLast() }
        for line in lines {
            guard let row = try? ProxyTrafficRow.decode(Data(line)), row.source == "mac",
                  ProxyTrafficTime.day(row.hour) == day, let date = row.date else { bad += 1; continue }
            if !seen.insert(date).inserted { duplicate += 1; continue }
            rows.append(row)
        }
        if bad > 0 { report("invalid_history_rows", bad) }
        if duplicate > 0 { report("duplicate_history_rows", duplicate) }
        return rows
    }
    static func datedFiles(_ directory: URL) throws -> [(URL, String)] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { throw ProxyTrafficStorageError.unsafeFile }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).compactMap { url in
            let name = url.lastPathComponent
            guard name.range(of: #"^\d{4}-\d{2}-\d{2}\.jsonl$"#, options: .regularExpression) != nil else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let day = String(name.prefix(10))
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard let date = formatter.date(from: day), formatter.string(from: date) == day else { return nil }
            return (url, day)
        }.sorted { $0.1 < $1.1 }
    }
    static func cutoff(now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let date = calendar.date(byAdding: .day, value: -30, to: now)!
        return String(ProxyTrafficTime.hour(date, timeZone: timeZone).prefix(10))
    }
    public static func load(directory: URL, now: Date, timeZone: TimeZone = .current,
                            report: (String, Int) -> Void = { _, _ in }) throws -> [ProxyTrafficRow] {
        let minimum = cutoff(now: now, timeZone: timeZone)
        var rows: [ProxyTrafficRow] = []
        for (url, day) in try datedFiles(directory) where day >= minimum {
            guard let data = try readIfPresent(url) else { throw CocoaError(.fileReadNoSuchFile) }
            rows.append(contentsOf: decode(data, day: day, report: report))
        }
        return rows.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }
    public static func trim(directory: URL, now: Date, timeZone: TimeZone = .current) throws {
        let minimum = cutoff(now: now, timeZone: timeZone)
        for (url, day) in try datedFiles(directory) where day < minimum { try FileManager.default.removeItem(at: url) }
    }
}
