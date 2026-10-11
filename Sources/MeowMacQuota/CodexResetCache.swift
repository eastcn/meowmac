import Foundation
import Darwin
import MeowMacCore

struct CodexResetCache: Codable {
    var schemaVersion = 1
    var actorID = UUID()
    var body: Data?
    var etag: String?
    var fetchedAt: Date?
    var nextAttemptAt: Date?
    var schedulingVersion: Int?
    var manualNotBeforeAt: Date?
    var serverNotBeforeAt: Date?
    var failures = 0
    var error: String?
}

/// 与账号配置隔离。坏文件保留；目录句柄固定发布位置。
final class CodexResetCacheStore {
    let root: URL
    private let filename = "codex-reset-monitor.json"
    private let maximumBytes = 400_000
    init(root: URL) { self.root = root }
    private func directory(create: Bool) throws -> Int32? {
        let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw CodexResetError.invalid("重置缓存父目录无法安全打开") }
        defer { close(parent) }
        let name = root.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw CodexResetError.invalid("重置缓存目录名无效") }
        if create && mkdirat(parent, name, 0o700) != 0 && errno != EEXIST {
            throw CodexResetError.invalid("重置缓存目录创建失败")
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && !create && errno == ENOENT { return nil }
        guard fd >= 0 else { throw CodexResetError.invalid("重置缓存目录无法安全打开") }
        return fd
    }
    private func read(_ dir: Int32) throws -> CodexResetCache? {
        let fd = openat(dir, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw CodexResetError.invalid("重置缓存无法安全打开") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_size > 0, info.st_size <= maximumBytes else {
            throw CodexResetError.invalid("重置缓存类型或大小无效")
        }
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
        guard count == bytes.count else { throw CodexResetError.invalid("重置缓存读取不完整") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(CodexResetCache.self, from: Data(bytes))
        guard value.schemaVersion == 1, value.schedulingVersion == nil || value.schedulingVersion == 2,
              (0...1_000_000).contains(value.failures),
              value.etag.map({ Self.validETag($0) }) ?? true,
              value.body != nil || value.etag == nil,
              value.body != nil || value.fetchedAt == nil else {
            throw CodexResetError.invalid("重置缓存内容无效")
        }
        if let body = value.body { _ = try CodexResetFeed.parse(body) }
        return value
    }
    static func validETag(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    func load() throws -> CodexResetCache? {
        guard let dir = try directory(create: false) else { return nil }
        defer { close(dir) }
        return try read(dir)
    }
    func save(_ value: CodexResetCache) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw CodexResetError.invalid("重置缓存超过大小上限") }
        let dir = try directory(create: true)!
        defer { close(dir) }
        _ = try read(dir)
        let name = ".codex-reset-" + UUID().uuidString
        let fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CodexResetError.invalid("重置缓存暂存失败") }
        var published = false
        defer { close(fd); if !published { _ = unlinkat(dir, name, 0) } }
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
        guard count == data.count, fsync(fd) == 0 else { throw CodexResetError.invalid("重置缓存写入失败") }
        _ = try read(dir)
        guard renameat(dir, name, dir, filename) == 0 else { throw CodexResetError.invalid("重置缓存原子发布失败") }
        published = true
        guard fsync(dir) == 0 else { throw CodexResetError.invalid("重置缓存目录同步失败") }
    }
}
