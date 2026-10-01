import AppKit
import Darwin
import ImageIO
import MeowMacCore

public struct LoadedCat {
    public let package: CatPackage
    public let run: CGImage
    public let severe: CGImage
    public let files: [String: Data]
    public var id: String { package.id }
    public var name: String { package.name }
}

public enum CatPackageLoader {
    private static func invalid(_ reason: String) -> CatPackageError { .invalid(reason) }
    public static let builtinIDs = ["builtin.slim", "builtin.round", "builtin.american", "builtin.orange-white"]
    public static let defaultCat: LoadedCat? = try? builtin("builtin.slim")

    public static func builtin(_ id: String) throws -> LoadedCat {
        guard builtinIDs.contains(id), let resources = Bundle.module.resourceURL else { throw invalid("未知内置猫") }
        return try load(at: resources.appendingPathComponent("Cats/\(id).cat", isDirectory: true), builtin: true)
    }

    public static func load(at url: URL, builtin: Bool = false) throws -> LoadedCat {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw invalid("包目录无法安全打开") }
        defer { close(fd) }
        return try load(directoryFD: fd, builtin: builtin)
    }

    static func load(directoryFD fd: Int32, builtin: Bool = false) throws -> LoadedCat {
        guard let directory = fdopendir(dup(fd)) else { throw invalid("无法读取包目录") }
        defer { closedir(directory) }
        var names = Set<String>()
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.insert(name).inserted, names.count <= 3 else { throw invalid("包内文件超过 3 个") }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw invalid("包内只允许普通文件")
            }
        }
        guard names.contains("manifest.json") else { throw invalid("缺少 manifest.json") }
        func read(_ name: String, limit: Int) throws -> Data {
            let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard file >= 0 else { throw invalid("无法安全打开 \(name)") }
            defer { close(file) }
            var info = stat()
            guard fstat(file, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size >= 0,
                  info.st_size <= limit else { throw invalid("\(name) 类型或大小无效") }
            guard info.st_size > 0 else { throw invalid("\(name) 不能为空") }
            var result = Data(count: Int(info.st_size))
            let count = result.withUnsafeMutableBytes { buffer in readFully(file, buffer.baseAddress!, buffer.count) }
            guard count == result.count else { throw invalid("\(name) 读取不完整") }
            return result
        }
        let manifest = try read("manifest.json", limit: 65_536)
        let package = try CatPackage.parse(manifest, builtin: builtin)
        let expected = Set(["manifest.json", package.runImage, package.severeImage])
        guard names == expected else { throw invalid("包内有缺失或额外文件") }
        var files = ["manifest.json": manifest]
        for name in expected where name != "manifest.json" { files[name] = try read(name, limit: 8 * 1024 * 1024) }
        guard files.values.reduce(0, { $0 + $1.count }) <= 20 * 1024 * 1024 else { throw invalid("包超过 20 MiB") }
        let run = try decode(files[package.runImage]!, expected: package.runSize, label: "跑步图")
        guard package.runImage != package.severeImage || package.severeSize == package.runSize else {
            throw invalid("共用图片的声明尺寸不一致")
        }
        let severe = package.runImage == package.severeImage ? run : try decode(files[package.severeImage]!, expected: package.severeSize, label: "严重图")
        for (index, frame) in package.frames.enumerated() {
            guard hasOpaquePixel(run, in: frame.source) else { throw invalid("第 \(index + 1) 帧全透明") }
        }
        guard hasOpaquePixel(severe, in: package.severeBounds) else { throw invalid("严重图全透明") }
        return LoadedCat(package: package, run: run, severe: severe, files: files)
    }

    private static func readFully(_ fd: Int32, _ pointer: UnsafeMutableRawPointer, _ length: Int) -> Int {
        var offset = 0
        while offset < length {
            let count = Darwin.read(fd, pointer.advanced(by: offset), length - offset)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            offset += count
        }
        return offset
    }

    private static func decode(_ data: Data, expected: [Int], label: String) throws -> CGImage {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              width <= 8_388_608 / height, [width, height] == expected,
              let alpha = properties[kCGImagePropertyHasAlpha] as? Bool, alpha else { throw invalid("\(label) PNG 属性、尺寸或 alpha 无效") }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == width, image.height == height else {
            throw invalid("\(label) PNG 解码失败")
        }
        guard hasTransparentPixel(image) else { throw invalid("\(label) 缺少透明像素") }
        return image
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(data: memory.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? bytes : nil
    }

    private static func hasTransparentPixel(_ image: CGImage) -> Bool {
        guard let bytes = pixels(image) else { return false }
        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] < 255 }
    }

    private static func hasOpaquePixel(_ image: CGImage, in rect: CatRect) -> Bool {
        guard let bytes = pixels(image) else { return false }
        for y in rect.y..<(rect.y + rect.height) {
            for x in rect.x..<(rect.x + rect.width) where bytes[(y * image.width + x) * 4 + 3] > 0 { return true }
        }
        return false
    }
}
