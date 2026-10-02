import Foundation
import Darwin
import MeowMacCore
import os

public struct ReminderStoreLoad {
    public let records: [SnoozeRecord]
    public let recoveryReason: String?
}

@MainActor
public final class ReminderStore {
    public let rootURL: URL
    private let beforePublish: (() throws -> Void)?
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "reminders")
    private let filename = "reminder-snoozes.json"
    public init(rootURL: URL = CatStore.defaultRoot, beforePublish: (() throws -> Void)? = nil) {
        self.rootURL = rootURL; self.beforePublish = beforePublish
    }
    private func fail(_ message: String) -> SnoozeError { .invalid(message) }
    private func directory(create: Bool) throws -> Int32? {
        let parent = open(rootURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw fail("提醒目录的父目录无法安全打开") }
        defer { close(parent) }
        let name = rootURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw fail("提醒目录名无效") }
        if create && mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw fail("无法创建提醒目录") }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && !create && errno == ENOENT { return nil }
        guard fd >= 0 else { throw fail("提醒目录不是安全目录") }
        return fd
    }
    private func read(_ directory: Int32) throws -> [SnoozeRecord] {
        let fd = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return [] }
        guard fd >= 0 else { throw fail("暂缓文件无法安全打开") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 65_536 else { throw fail("暂缓文件类型或大小无效") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                offset += n
            }
            return offset
        }
        guard count == bytes.count else { throw fail("暂缓文件读取不完整") }
        let data = Data(bytes)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "records"],
              let version = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let rows = object["records"] as? [[String: Any]], rows.count <= 64 else {
            throw fail("暂缓文件版本或结构无效")
        }
        let required: Set<String> = ["key", "kind", "acknowledgedAt", "until"]
        for row in rows {
            guard required.isSubset(of: Set(row.keys)), Set(row.keys).isSubset(of: required.union(["cycleResetAt"])) else {
                throw fail("暂缓记录字段无效")
            }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        struct Envelope: Decodable { let records: [SnoozeRecord] }
        let records = try decoder.decode(Envelope.self, from: data).records
        try validate(records)
        return records
    }
    private func validate(_ records: [SnoozeRecord]) throws {
        guard records.count <= 64, Set(records.map(\.key)).count == records.count else {
            throw fail("暂缓记录数量或身份无效")
        }
        for record in records { try record.validate() }
    }
    public func load() -> ReminderStoreLoad {
        do {
            guard let fd = try directory(create: false) else { return ReminderStoreLoad(records: [], recoveryReason: nil) }
            defer { close(fd) }
            return ReminderStoreLoad(records: try read(fd), recoveryReason: nil)
        } catch {
            logger.error("提醒暂缓恢复失败：\(error.localizedDescription, privacy: .private)")
            return ReminderStoreLoad(records: [], recoveryReason: error.localizedDescription)
        }
    }
    public func save(_ records: [SnoozeRecord]) throws {
        try validate(records)
        struct Envelope: Encodable { let schemaVersion = 1; let records: [SnoozeRecord] }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(records: records.sorted { $0.key < $1.key }))
        guard data.count <= 65_536 else { throw fail("暂缓记录超过 64 KiB") }
        let dir = try directory(create: true)!
        defer { close(dir) }
        // 保留已有坏文件；禁止用新操作静默覆盖。
        _ = try read(dir)
        let temporary = ".reminders-" + UUID().uuidString
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw fail("无法创建暂缓暂存文件") }
        var published = false
        defer { close(fd); if !published { _ = unlinkat(dir, temporary, 0) } }
        let count = data.withUnsafeBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                offset += n
            }
            return offset
        }
        guard count == data.count, fsync(fd) == 0 else { throw fail("暂缓记录写入失败") }
        try beforePublish?()
        _ = try read(dir)
        guard renameat(dir, temporary, dir, filename) == 0 else { throw fail("暂缓记录原子替换失败") }
        published = true
        if fsync(dir) != 0 { logger.error("暂缓记录已发布，但目录同步失败") }
    }
}
