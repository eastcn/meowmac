import Foundation
import Darwin
import MeowMacCore
import os

public struct PanelLayoutLoad {
    public let layout: PanelLayout
    public let recoveryReason: String?
}

@MainActor
public final class PanelLayoutStore {
    public let rootURL: URL
    private let beforePublish: (() throws -> Void)?
    private let directorySync: (Int32) -> Int32
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "panel-layout")

    public init(rootURL: URL = CatStore.defaultRoot, beforePublish: (() throws -> Void)? = nil,
                directorySync: @escaping (Int32) -> Int32 = { fsync($0) }) {
        self.rootURL = rootURL
        self.beforePublish = beforePublish
        self.directorySync = directorySync
    }

    private func invalid(_ reason: String) -> PanelLayoutError { .invalid(reason) }
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

    private func layoutsFD(root: Int32, create: Bool) throws -> Int32? {
        if create && mkdirat(root, "PanelLayouts", 0o700) != 0 && errno != EEXIST {
            throw invalid("无法创建布局目录")
        }
        let fd = openat(root, "PanelLayouts", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if !create && fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw invalid("布局目录不是安全目录") }
        return fd
    }

    private func read(catID: String, directory: Int32) throws -> PanelLayout? {
        let name = catID + ".json"
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw invalid("本机布局无法安全打开") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= 16_384 else { throw invalid("本机布局类型或大小无效") }
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
        guard count == bytes.count, let value = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any],
              Set(value.keys) == ["schemaVersion", "catID", "layout"],
              let version = value["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue.isFinite, version.doubleValue == 1,
              let savedID = value["catID"] as? String, savedID == catID,
              let layoutObject = value["layout"],
              let layoutData = try? JSONSerialization.data(withJSONObject: layoutObject) else {
            throw invalid("本机布局版本、猫 id 或内容无效")
        }
        return try PanelLayout.parse(layoutData)
    }

    public func load(cat: LoadedCat?) -> PanelLayoutLoad {
        guard let cat else { return PanelLayoutLoad(layout: .default, recoveryReason: nil) }
        do {
            guard let root = try rootFD(create: false) else { return PanelLayoutLoad(layout: cat.package.panel, recoveryReason: nil) }
            defer { close(root) }
            guard let layouts = try layoutsFD(root: root, create: false) else { return PanelLayoutLoad(layout: cat.package.panel, recoveryReason: nil) }
            defer { close(layouts) }
            return PanelLayoutLoad(layout: try read(catID: cat.id, directory: layouts) ?? cat.package.panel, recoveryReason: nil)
        } catch {
            logger.error("本机布局恢复失败：\(error.localizedDescription, privacy: .private)")
            return PanelLayoutLoad(layout: cat.package.panel, recoveryReason: error.localizedDescription)
        }
    }

    public func save(_ layout: PanelLayout, cat: LoadedCat) throws {
        _ = try layout.validated()
        let layoutData = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout))
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "catID": cat.id, "layout": layoutData], options: [.sortedKeys])
        guard data.count <= 16_384 else { throw invalid("本机布局超过 16 KiB") }
        let root = try rootFD(create: true)!
        defer { close(root) }
        let directory = try layoutsFD(root: root, create: true)!
        defer { close(directory) }
        _ = try read(catID: cat.id, directory: directory)
        let temporary = ".layout-" + UUID().uuidString
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw invalid("无法创建布局暂存文件") }
        var published = false
        defer {
            close(fd)
            if !published { _ = unlinkat(directory, temporary, 0) }
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
        guard count == data.count, fsync(fd) == 0 else { throw invalid("本机布局写入失败") }
        try beforePublish?()
        guard renameat(directory, temporary, directory, cat.id + ".json") == 0 else {
            throw invalid("本机布局原子替换失败")
        }
        published = true
        if directorySync(directory) != 0 {
            logger.error("布局已发布，但目录同步失败")
        }
    }
}
