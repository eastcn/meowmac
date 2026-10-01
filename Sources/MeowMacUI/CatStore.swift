import Foundation
import Darwin
import MeowMacCore
import os

@MainActor
public final class CatStore {
    public nonisolated static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeowMac", isDirectory: true)
    }

    public let rootURL: URL
    public private(set) var recoveryReason: String?
    private let temporaryName: () -> String
    private let beforePublish: (() throws -> Void)?
    private let beforeSelectionSave: (() throws -> Void)?
    private let publish: (Int32, String, Int32, String) -> Int32
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "cat-store")

    public init(rootURL: URL = CatStore.defaultRoot,
                temporaryName: @escaping () -> String = { ".import-" + UUID().uuidString },
                beforePublish: (() throws -> Void)? = nil,
                beforeSelectionSave: (() throws -> Void)? = nil,
                publish: @escaping (Int32, String, Int32, String) -> Int32 = {
                    renameatx_np($0, $1, $2, $3, UInt32(RENAME_EXCL))
                }) {
        self.rootURL = rootURL
        self.temporaryName = temporaryName
        self.beforePublish = beforePublish
        self.beforeSelectionSave = beforeSelectionSave
        self.publish = publish
    }

    private func invalid(_ reason: String) -> CatPackageError { .invalid(reason) }
    private func validID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) &&
        id.first.map { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0) } == true &&
        id.allSatisfy { "abcdefghijklmnopqrstuvwxyz0123456789._-".contains($0) }
    }

    private func parentFD() throws -> Int32 {
        let parent = rootURL.deletingLastPathComponent()
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw invalid("应用目录的父目录无法安全打开") }
        return fd
    }

    private func rootFD(create: Bool) throws -> Int32? {
        let parent = try parentFD()
        defer { close(parent) }
        let name = rootURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw invalid("应用目录名无效") }
        if create && mkdirat(parent, name, 0o700) != 0 && errno != EEXIST {
            throw invalid("无法创建应用目录")
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if !create && fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw invalid("应用目录不是安全的普通目录") }
        return fd
    }

    private func catsFD(root: Int32, create: Bool) throws -> Int32? {
        if create && mkdirat(root, "Cats", 0o700) != 0 && errno != EEXIST {
            throw invalid("无法创建 Cats 目录")
        }
        let fd = openat(root, "Cats", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if !create && fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw invalid("Cats 目录不是安全的普通目录") }
        return fd
    }

    private func readSelection(root: Int32) throws -> String? {
        let fd = openat(root, "cat-selection.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw invalid("选择文件无法安全打开") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= 4096 else { throw invalid("选择文件类型或大小无效") }
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
        guard count == bytes.count, let value = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              Set(value.keys) == [ "schemaVersion", "selectedID" ],
              let version = value["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(version), version.doubleValue.isFinite, version.doubleValue == 1,
              let id = value["selectedID"] as? String,
              validID(id) else { throw invalid("选择文件版本或内容无效") }
        return id
    }

    private func loaded(_ id: String, root: Int32?) throws -> LoadedCat {
        guard validID(id) else { throw invalid("猫配置 id 无效") }
        if CatPackageLoader.builtinIDs.contains(id) { return try CatPackageLoader.builtin(id) }
        guard !id.hasPrefix("builtin.") else { throw invalid("保留的内置猫 id 无效") }
        guard let root, let cats = try catsFD(root: root, create: false) else { throw invalid("所选猫配置不存在") }
        defer { close(cats) }
        let fd = openat(cats, id + ".cat", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw invalid("所选猫配置不存在或无法安全打开") }
        defer { close(fd) }
        let cat = try CatPackageLoader.load(directoryFD: fd)
        guard cat.id == id else { throw invalid("目录名与清单 id 不一致") }
        return cat
    }

    public func loadSelection() -> LoadedCat? {
        recoveryReason = nil
        do {
            guard let root = try rootFD(create: false) else { return CatPackageLoader.defaultCat }
            defer { close(root) }
            guard let id = try readSelection(root: root) else { return CatPackageLoader.defaultCat }
            return try loaded(id, root: root)
        } catch {
            recoveryReason = error.localizedDescription
            logger.error("猫配置恢复失败，已回退标准瘦身：\(error.localizedDescription, privacy: .private)")
            return CatPackageLoader.defaultCat
        }
    }

    private func selectionData(_ id: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "selectedID": id], options: [.sortedKeys])
    }

    private func writeFile(_ data: Data, name: String, in directory: Int32) throws {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw invalid("无法创建 \(name)") }
        defer { close(fd) }
        let count = data.withUnsafeBytes { buffer -> Int in
            guard let pointer = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, pointer.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                offset += n
            }
            return offset
        }
        guard count == data.count, fsync(fd) == 0 else { throw invalid("写入 \(name) 失败") }
    }

    private func saveSelection(_ id: String, root: Int32) throws {
        try beforeSelectionSave?()
        var info = stat()
        if fstatat(root, "cat-selection.json", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw invalid("选择文件不是普通文件") }
        } else if errno != ENOENT { throw invalid("选择文件状态无法读取") }
        let temporary = ".selection-" + UUID().uuidString
        do {
            try writeFile(selectionData(id), name: temporary, in: root)
            guard renameat(root, temporary, root, "cat-selection.json") == 0 else { throw invalid("选择文件原子替换失败") }
            _ = fsync(root)
        } catch {
            _ = unlinkat(root, temporary, 0)
            throw error
        }
    }

    @discardableResult
    public func select(_ id: String, state: PanelState) throws -> LoadedCat {
        let existingRoot = try rootFD(create: false)
        defer { if let existingRoot { close(existingRoot) } }
        let selected = try loaded(id, root: existingRoot)
        let root = try rootFD(create: true)!
        defer { close(root) }
        if let cats = try catsFD(root: root, create: false) { close(cats) }
        try saveSelection(id, root: root)
        state.selectedCat = selected
        return selected
    }

    public func importedCats() -> [LoadedCat] {
        do {
            guard let root = try rootFD(create: false) else { return [] }
            defer { close(root) }
            guard let cats = try catsFD(root: root, create: false) else { return [] }
            defer { close(cats) }
            guard let directory = fdopendir(dup(cats)) else { throw invalid("Cats 目录无法读取") }
            defer { closedir(directory) }
            var loadedCats: [LoadedCat] = []
            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                guard name.hasSuffix(".cat") else { continue }
                let id = String(name.dropLast(4))
                do { loadedCats.append(try loaded(id, root: root)) }
                catch { logger.error("已导入猫配置无效：\(id, privacy: .private) \(error.localizedDescription, privacy: .private)") }
            }
            return loadedCats
        } catch {
            logger.error("读取 Cats 目录失败：\(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    public func catsDirectoryIfSafe() throws -> URL? {
        guard let root = try rootFD(create: false) else { return nil }
        defer { close(root) }
        guard let cats = try catsFD(root: root, create: false) else { return nil }
        close(cats)
        return rootURL.appendingPathComponent("Cats", isDirectory: true)
    }

    @discardableResult
    public func importCat(from source: URL, state: PanelState) throws -> LoadedCat {
        guard source.pathExtension == "cat" else { throw invalid("请选择 .cat 目录包") }
        let input = try CatPackageLoader.load(at: source)
        let root = try rootFD(create: true)!
        defer { close(root) }
        let cats = try catsFD(root: root, create: true)!
        defer { close(cats) }
        let target = input.id + ".cat"
        var info = stat()
        guard fstatat(cats, target, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT else {
            throw invalid("已有相同 id 的猫配置")
        }
        let temporary = temporaryName()
        guard temporary.hasPrefix(".import-"), !temporary.contains("/"), !temporary.contains("\\"),
              mkdirat(cats, temporary, 0o700) == 0 else { throw invalid("无法创建安全暂存目录") }
        let stage = openat(cats, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else {
            _ = unlinkat(cats, temporary, AT_REMOVEDIR)
            throw invalid("无法安全打开暂存目录")
        }
        var published = false
        defer {
            if !published {
                for name in input.files.keys { _ = unlinkat(stage, name, 0) }
                _ = unlinkat(cats, temporary, AT_REMOVEDIR)
            }
            close(stage)
        }
        for (name, data) in input.files { try writeFile(data, name: name, in: stage) }
        let copied = try CatPackageLoader.load(directoryFD: stage)
        guard copied.id == input.id else { throw invalid("暂存副本 id 不一致") }
        try beforePublish?()
        guard publish(cats, temporary, cats, target) == 0 else {
            throw invalid("文件系统未完成原子不覆盖发布：\(String(cString: strerror(errno)))")
        }
        published = true
        _ = fsync(cats)
        do {
            try saveSelection(copied.id, root: root)
        } catch {
            throw invalid("已导入，切换未保存：\(error.localizedDescription)")
        }
        state.selectedCat = copied
        return copied
    }
}
