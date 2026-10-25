import AppKit
import Darwin
import ImageIO
import MeowMacCore

/// 加载好的 Codex 宠物。每行只保留非空格子，按共同的可见范围裁好，逐帧播放不做文件 I/O。
public final class LoadedCodexPet {
    /// `$CODEX_HOME/pets` 下的目录名，也是配置里存的值。
    public let id: String
    public let name: String
    /// 每个用到的动作行的帧，所有帧尺寸相同，位置一致。
    public let rows: [CodexPetRow: [CGImage]]
    /// 帧的像素尺寸。
    public let frameSize: CGSize

    init(id: String, name: String, rows: [CodexPetRow: [CGImage]], frameSize: CGSize) {
        self.id = id; self.name = name; self.rows = rows; self.frameSize = frameSize
    }

    public func frames(_ row: CodexPetRow) -> [CGImage] { rows[row] ?? [] }
}

public struct CodexPetEntry: Equatable, Identifiable {
    public let id: String
    public let name: String
}

/// 只读 `$CODEX_HOME/pets`（plan P1、P3）。不写、不复制，目录和文件都不跟随符号链接。
public enum CodexPetLibrary {
    /// 桌面猫用到的动作行，缺任何一行都不能用。
    public static let requiredRows: [CodexPetRow] = [.idle, .runningRight, .waiting, .failed]
    /// 一格里不透明像素少于这个数视为空格，忽略边缘的零星残留。
    static let emptyCellPixels = 200

    public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("pets", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/pets", isDirectory: true)
    }

    /// 列出清单有效的宠物，按名称排序。只读清单，不解码图集。
    public static func list(root: URL) -> [CodexPetEntry] {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return [] }
        defer { close(rootFD) }
        guard let directory = fdopendir(dup(rootFD)) else { return [] }
        defer { closedir(directory) }
        var entries: [CodexPetEntry] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard CodexPetManifest.isValidDirectoryName(name),
                  let manifest = try? withPetDirectory(rootFD: rootFD, id: name, { try readManifest(in: $0) }) else { continue }
            entries.append(CodexPetEntry(id: name, name: manifest.displayName))
            if entries.count >= 64 { break }
        }
        return entries.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    public static func load(_ id: String, root: URL) throws -> LoadedCodexPet {
        guard CodexPetManifest.isValidDirectoryName(id) else { throw CodexPetError.invalid("宠物名无效") }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw CodexPetError.missing }
        defer { close(rootFD) }
        return try withPetDirectory(rootFD: rootFD, id: id) { fd in
            let manifest = try readManifest(in: fd)
            let data = try read(manifest.spritesheetPath, in: fd, limit: CodexPetAtlas.maxBytes)
            let atlas = try decode(data, version: manifest.version)
            return try slice(atlas, id: id, name: manifest.displayName)
        }
    }

    private static func withPetDirectory<T>(rootFD: Int32, id: String, _ body: (Int32) throws -> T) throws -> T {
        let fd = openat(rootFD, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? CodexPetError.missing : CodexPetError.invalid("宠物目录无法安全打开") }
        defer { close(fd) }
        return try body(fd)
    }

    private static func readManifest(in fd: Int32) throws -> CodexPetManifest {
        try CodexPetManifest.parse(read("pet.json", in: fd, limit: CodexPetManifest.maxBytes))
    }

    private static func read(_ name: String, in fd: Int32, limit: Int) throws -> Data {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw CodexPetError.invalid("无法安全打开 \(name)") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size > 0,
              info.st_size <= limit else { throw CodexPetError.invalid("\(name) 类型或大小无效") }
        var result = Data(count: Int(info.st_size))
        let count = result.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.read(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                offset += n
            }
            return offset
        }
        guard count == result.count else { throw CodexPetError.invalid("\(name) 读取不完整") }
        return result
    }

    private static func decode(_ data: Data, version: Int) throws -> CGImage {
        let expected = CodexPetAtlas.size(version: version)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, ["public.png", "org.webmproject.webp"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw CodexPetError.invalid("图集不是有效的 PNG 或 WebP")
        }
        guard width == expected.width, height == expected.height else {
            throw CodexPetError.invalid("图集尺寸应为 \(expected.width)×\(expected.height)，实际 \(width)×\(height)")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == width, image.height == height else {
            throw CodexPetError.invalid("图集解码失败")
        }
        return image
    }

    /// 统计每行的非空格子，再按实际播放的帧的共同可见范围裁剪，保证帧与帧之间位置不跳。
    private static func slice(_ atlas: CGImage, id: String, name: String) throws -> LoadedCodexPet {
        let width = atlas.width, height = atlas.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(atlas, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw CodexPetError.invalid("图集解码失败") }
        // 位图按行自上而下存放，与图集坐标一致。
        func bounds(row: Int, column: Int) -> (count: Int, rect: CGRect) {
            let cell = CodexPetAtlas.cell(row: row, column: column)
            var count = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in cell.y..<(cell.y + cell.height) {
                let line = y * width * 4
                for x in cell.x..<(cell.x + cell.width) where bytes[line + x * 4 + 3] > 16 {
                    count += 1
                    minX = min(minX, x - cell.x); maxX = max(maxX, x - cell.x)
                    minY = min(minY, y - cell.y); maxY = max(maxY, y - cell.y)
                }
            }
            return (count, count == 0 ? .null : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        }
        var columns: [CodexPetRow: [Int]] = [:]
        var union = CGRect.null
        for row in requiredRows {
            var used: [(column: Int, rect: CGRect)] = []
            for column in 0..<CodexPetAtlas.columns {
                let result = bounds(row: row.rawValue, column: column)
                if result.count >= emptyCellPixels { used.append((column, result.rect)) }
            }
            guard !used.isEmpty else { throw CodexPetError.invalid("图集缺少 \(rowTitle(row)) 动作") }
            // 严重只用一帧：取可见范围最扁的一格，通常是趴下或倒地（plan P4）。
            if row == .failed, let flattest = used.max(by: { $0.rect.width / $0.rect.height < $1.rect.width / $1.rect.height }) {
                used = [flattest]
            }
            columns[row] = used.map(\.column)
            for item in used { union = union.union(item.rect) }
        }
        let crop = union.integral
        var rows: [CodexPetRow: [CGImage]] = [:]
        for (row, used) in columns {
            rows[row] = try used.map { column in
                let cell = CodexPetAtlas.cell(row: row.rawValue, column: column)
                guard let image = atlas.cropping(to: crop.offsetBy(dx: CGFloat(cell.x), dy: CGFloat(cell.y))) else {
                    throw CodexPetError.invalid("图集裁剪失败")
                }
                return image
            }
        }
        return LoadedCodexPet(id: id, name: name, rows: rows, frameSize: crop.size)
    }

    static func rowTitle(_ row: CodexPetRow) -> String {
        switch row {
        case .idle: return "待机"
        case .runningRight: return "向右跑"
        case .waiting: return "等待"
        case .failed: return "失败"
        default: return "第 \(row.rawValue + 1) 行"
        }
    }
}

public extension PanelState {
    /// 按配置加载桌面猫用的宠物。已是同一只就不重读；不可用时回到当前猫并记原因（plan P1）。
    func syncDesktopPet() {
        guard let id = desktopCat.pet else { desktopPet = nil; desktopPetError = nil; return }
        if desktopPet?.id == id { return }
        do {
            desktopPet = try CodexPetLibrary.load(id, root: codexPetsRoot)
            desktopPetError = nil
        } catch {
            desktopPet = nil
            desktopPetError = "宠物“\(id)”不可用：\(error.localizedDescription)，已用当前猫"
        }
    }

    /// 关闭桌面猫时释放宠物帧图。
    func releaseDesktopPet() { if desktopPet != nil { desktopPet = nil } }
}
