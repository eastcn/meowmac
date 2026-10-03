import Foundation
import Darwin
import MeowMacCore
import os

public struct StyleLoad {
    public let settings: StyleSettings
    public let recoveryReason: String?
}

@MainActor
public final class StyleStore {
    public let rootURL: URL
    private let beforePublish: (() throws -> Void)?
    private let directorySync: (Int32) -> Int32
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "style")

    public init(rootURL: URL = CatStore.defaultRoot, beforePublish: (() throws -> Void)? = nil,
                directorySync: @escaping (Int32) -> Int32 = { fsync($0) }) {
        self.rootURL = rootURL; self.beforePublish = beforePublish; self.directorySync = directorySync
    }
    private func invalid(_ reason: String) -> StyleError { .invalid(reason) }
    private func rootFD(create: Bool) throws -> Int32? {
        let parent = open(rootURL.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw invalid("应用目录的父目录无法安全打开") }
        defer { close(parent) }
        let name = rootURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw invalid("应用目录名无效") }
        if create && mkdirat(parent, name, 0o700) != 0 && errno != EEXIST { throw invalid("无法创建应用目录") }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if !create && fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw invalid("应用目录不是安全目录") }
        return fd
    }
    private func read(directory: Int32) throws -> StyleSettings? {
        let fd = openat(directory, "style.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw invalid("样式文件无法安全打开") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= 16_384 else { throw invalid("样式文件类型或大小无效") }
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
        guard count == bytes.count else { throw invalid("样式文件读取不完整") }
        return try StyleSettings.parse(Data(bytes))
    }
    public func load() -> StyleLoad {
        do {
            guard let root = try rootFD(create: false) else { return StyleLoad(settings: .default, recoveryReason: nil) }
            defer { close(root) }
            return StyleLoad(settings: try read(directory: root) ?? .default, recoveryReason: nil)
        } catch {
            logger.error("样式恢复失败：\(error.localizedDescription, privacy: .private)")
            return StyleLoad(settings: .default, recoveryReason: error.localizedDescription)
        }
    }
    public func save(_ settings: StyleSettings) throws {
        _ = try settings.validated()
        let data = try JSONEncoder().encode(settings)
        guard data.count <= 16_384 else { throw invalid("样式文件超过 16 KiB") }
        let root = try rootFD(create: true)!
        defer { close(root) }
        _ = try read(directory: root)
        let temporary = ".style-" + UUID().uuidString
        let fd = openat(root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw invalid("无法创建样式暂存文件") }
        var published = false
        defer {
            close(fd)
            if !published { _ = unlinkat(root, temporary, 0) }
        }
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
        guard count == data.count, fsync(fd) == 0 else { throw invalid("样式文件写入失败") }
        try beforePublish?()
        _ = try read(directory: root)
        guard renameat(root, temporary, root, "style.json") == 0 else { throw invalid("样式文件原子替换失败") }
        published = true
        if directorySync(root) != 0 { logger.error("样式已发布，但目录同步失败") }
    }
}
