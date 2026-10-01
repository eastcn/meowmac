import AppKit
import Foundation
import ImageIO
import MeowMacCore
import MeowMacUI

enum CatBoundaryTests {
    private static let base = URL(fileURLWithPath: "build/acceptance/cat-tests/boundaries", isDirectory: true)

    private static func png(width: Int, height: Int, opaque: Bool = false,
                            missingFrame: Int? = nil, empty: Bool = false) -> Data? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        if !empty {
            if opaque {
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    bytes[offset] = 255; bytes[offset + 3] = 255
                }
            } else {
                for frame in 0..<min(5, width / 2) where frame != missingFrame {
                    let offset = frame * 2 * 4
                    bytes[offset] = 255; bytes[offset + 3] = 255
                }
            }
        }
        let image = bytes.withUnsafeMutableBytes { memory -> CGImage? in
            CGContext(data: memory.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func rgbPNG() -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 2,
                                            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func manifest() -> [String: Any] {
        [
            "schemaVersion": 1, "id": "boundary-cat", "name": "边界测试",
            "run": ["image": "run.png", "rendering": "original", "sheetSize": [10, 2],
                    "canvas": [2, 2], "noseAnchor": 1, "topPadding": 0,
                    "frames": (0..<5).map { ["source": [$0 * 2, 0, 2, 2], "noseX": $0 * 2 + 1] }],
            "severe": ["image": "severe.png", "sheetSize": [2, 2],
                       "bounds": [0, 0, 2, 2], "zzAnchorFraction": 0.5]
        ]
    }

    private static func fixture(_ name: String) throws -> URL {
        let root = base.appendingPathComponent(name + ".cat", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try JSONSerialization.data(withJSONObject: manifest()).write(to: root.appendingPathComponent("manifest.json"))
        try png(width: 10, height: 2)!.write(to: root.appendingPathComponent("run.png"))
        try png(width: 2, height: 2)!.write(to: root.appendingPathComponent("severe.png"))
        return root
    }

    private static func rewrite(_ root: URL, _ change: (inout [String: Any]) -> Void) throws {
        let file = root.appendingPathComponent("manifest.json")
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        change(&value)
        try JSONSerialization.data(withJSONObject: value).write(to: file)
    }

    private static func rejection(_ root: URL, containing text: String? = nil) -> Bool {
        do { _ = try CatPackageLoader.load(at: root); return false }
        catch {
            guard let text else { return true }
            return error.localizedDescription.contains(text)
        }
    }

    private static func forgedDimensions(_ original: Data, width: Int, height: Int) -> Data {
        var bytes = [UInt8](original)
        for (offset, value) in [(16, width), (20, height)] {
            bytes[offset] = UInt8((value >> 24) & 255)
            bytes[offset + 1] = UInt8((value >> 16) & 255)
            bytes[offset + 2] = UInt8((value >> 8) & 255)
            bytes[offset + 3] = UInt8(value & 255)
        }
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        crc ^= 0xffff_ffff
        for index in 0..<4 { bytes[29 + index] = UInt8((crc >> (24 - index * 8)) & 255) }
        return Data(bytes)
    }

    static func boundaries() -> Bool {
        do {
            try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: base.path) { try FileManager.default.removeItem(at: base) }
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
            let good = try fixture("valid")
            guard (try? CatPackageLoader.load(at: good))?.id == "boundary-cat" else { return false }
            let noAlpha = try fixture("no-alpha")
            try rgbPNG()!.write(to: noAlpha.appendingPathComponent("run.png"))
            guard rejection(noAlpha, containing: "alpha") else { return false }
            let opaque = try fixture("opaque")
            try png(width: 10, height: 2, opaque: true)!.write(to: opaque.appendingPathComponent("run.png"))
            guard rejection(opaque, containing: "缺少透明像素") else { return false }
            let emptyFrame = try fixture("empty-frame")
            try png(width: 10, height: 2, missingFrame: 2)!.write(to: emptyFrame.appendingPathComponent("run.png"))
            guard rejection(emptyFrame, containing: "第 3 帧全透明") else { return false }
            let emptySevere = try fixture("empty-severe")
            try png(width: 2, height: 2, empty: true)!.write(to: emptySevere.appendingPathComponent("severe.png"))
            guard rejection(emptySevere, containing: "严重图全透明") else { return false }
            let mismatch = try fixture("size-mismatch")
            try rewrite(mismatch) { value in
                var run = value["run"] as! [String: Any]
                run["sheetSize"] = [11, 2]; value["run"] = run
            }
            guard rejection(mismatch, containing: "尺寸") else { return false }
            let edge = try fixture("edge-limit")
            let edgePNG = forgedDimensions(try Data(contentsOf: edge.appendingPathComponent("run.png")), width: 4097, height: 2)
            try edgePNG.write(to: edge.appendingPathComponent("run.png"))
            try rewrite(edge) { value in
                var run = value["run"] as! [String: Any]
                run["sheetSize"] = [4097, 2]; value["run"] = run
            }
            guard rejection(edge, containing: "PNG 属性") else { return false }
            let pixels = try fixture("pixel-limit")
            let hugePNG = forgedDimensions(try Data(contentsOf: pixels.appendingPathComponent("run.png")), width: 4096, height: 2049)
            try hugePNG.write(to: pixels.appendingPathComponent("run.png"))
            try rewrite(pixels) { value in
                var run = value["run"] as! [String: Any]
                run["sheetSize"] = [4096, 2049]; value["run"] = run
            }
            guard rejection(pixels, containing: "PNG 属性") else { return false }
            let fileLimit = try fixture("file-limit")
            try Data(repeating: 0, count: 8 * 1024 * 1024 + 1).write(to: fileLimit.appendingPathComponent("run.png"))
            guard rejection(fileLimit, containing: "类型或大小") else { return false }
            return true
        } catch { print("独立图片负例失败：\(error)"); return false }
    }

    static func manifestCases() -> Bool {
        let baseline = manifest()
        func rejected(_ change: (inout [String: Any]) -> Void) -> Bool {
            var value = baseline; change(&value)
            guard let bytes = try? JSONSerialization.data(withJSONObject: value) else { return false }
            return (try? CatPackage.parse(bytes)) == nil
        }
        return rejected({ value in var run = value["run"] as! [String: Any]; run["image"] = "/tmp/run.png"; value["run"] = run }) &&
            rejected({ value in var run = value["run"] as! [String: Any]; run["image"] = "../run.png"; value["run"] = run }) &&
            rejected({ $0["id"] = "builtin.fake" }) && rejected({ $0["id"] = "Invalid-ID" }) &&
            rejected({ value in var run = value["run"] as! [String: Any]; run["script"] = "noop"; value["run"] = run }) &&
            rejected({ value in var run = value["run"] as! [String: Any]; run["topPadding"] = "0"; value["run"] = run }) &&
            rejected({ value in var run = value["run"] as! [String: Any]; run["topPadding"] = 0.5; value["run"] = run }) &&
            rejected({ value in var run = value["run"] as! [String: Any]
                var frames = run["frames"] as! [[String: Any]]
                frames[1]["source"] = [1, 0, 2, 2]; run["frames"] = frames; value["run"] = run
            }) &&
            rejected({ value in var run = value["run"] as! [String: Any]
                var frames = run["frames"] as! [[String: Any]]
                frames[4]["source"] = [9, 0, 2, 2]; run["frames"] = frames; value["run"] = run
            })
    }
}
