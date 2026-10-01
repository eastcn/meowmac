import AppKit
import Foundation
import ImageIO
import MeowMacCore
import MeowMacUI

@MainActor
enum CatRenderTests {
    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func states() -> Bool {
        let output = ProcessInfo.processInfo.environment["MEOWMAC_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        do {
            if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            for id in CatPackageLoader.builtinIDs {
                let cat = try CatPackageLoader.builtin(id)
                for level in [HealthLevel.normal, .warn, .severe] {
                    let display = CatDisplay(id: id, name: cat.name, rendering: cat.package.rendering, level: level,
                        load: 0.7, frameInterval: 0.131, speedLines: level != .severe,
                        template: level == .normal && cat.package.rendering == "template",
                        stopped: level == .severe, reducedMotion: false)
                    let rendered = CatRenderer.image(cat: cat, display: display, frame: 0)
                    guard rendered.isTemplate == display.template,
                          let bytes = png(rendered), let bitmap = NSBitmapImageRep(data: bytes),
                          bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1 < 0.1,
                          (0..<bitmap.pixelsWide).contains(where: { x in
                              (0..<bitmap.pixelsHigh).contains(where: { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 })
                          }) else { return false }
                    if let output { try bytes.write(to: output.appendingPathComponent("\(id)-\(level).png")) }
                    if level == .severe {
                        guard png(CatRenderer.image(cat: cat, display: display, frame: 4)) == bytes else { return false }
                    } else {
                        let still = CatDisplay(id: id, name: cat.name, rendering: cat.package.rendering, level: level,
                            load: 0.7, frameInterval: 0.131, speedLines: true, template: display.template,
                            stopped: false, reducedMotion: true)
                        guard png(CatRenderer.image(cat: cat, display: still, frame: 4)) == png(CatRenderer.image(cat: cat, display: still, frame: 0)) else { return false }
                    }
                }
            }
            return true
        } catch { print("猫图渲染失败：\(error)"); return false }
    }

    static func orientation() -> Bool {
        let root = URL(fileURLWithPath: "build/acceptance/cat-tests/orientation.cat", isDirectory: true)
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            var pixels = [UInt8](repeating: 0, count: 10 * 2 * 4)
            for frame in 0..<5 {
                let top = frame * 2 * 4
                let bottom = (10 + frame * 2 + 1) * 4
                pixels[top] = 255; pixels[top + 3] = 255
                pixels[bottom + 2] = 255; pixels[bottom + 3] = 255
            }
            let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
                let context = CGContext(data: buffer.baseAddress, width: 10, height: 2, bitsPerComponent: 8,
                                        bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                return context?.makeImage()
            }
            guard let image else { return false }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return false }
            try (encoded as Data).write(to: root.appendingPathComponent("run.png"))
            let manifest: [String: Any] = [
                "schemaVersion": 1, "id": "orientation", "name": "方向测试",
                "run": ["image": "run.png", "rendering": "original", "sheetSize": [10, 2],
                        "canvas": [2, 2], "noseAnchor": 1, "topPadding": 0,
                        "frames": (0..<5).map { ["source": [$0 * 2, 0, 2, 2], "noseX": $0 * 2 + 1] }],
                "severe": ["image": "run.png", "sheetSize": [10, 2], "bounds": [0, 0, 2, 2], "zzAnchorFraction": 0.5]
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
            let cat = try CatPackageLoader.load(at: root)
            let display = CatDisplay(id: cat.id, name: cat.name, rendering: "original", level: .normal,
                load: 0, frameInterval: 0.5, speedLines: false, template: false, stopped: false, reducedMotion: false)
            guard let data = png(CatRenderer.image(cat: cat, display: display, frame: 0)),
                  let rendered = NSBitmapImageRep(data: data) else { return false }
            var redRows: [Int] = [], blueRows: [Int] = []
            for y in 0..<rendered.pixelsHigh {
                for x in 0..<rendered.pixelsWide {
                    guard let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.7 else { continue }
                    if color.redComponent > 0.7 && color.blueComponent < 0.3 { redRows.append(y) }
                    if color.blueComponent > 0.7 && color.redComponent < 0.3 { blueRows.append(y) }
                }
            }
            return !redRows.isEmpty && !blueRows.isEmpty && Double(redRows.reduce(0, +)) / Double(redRows.count) <
                Double(blueRows.reduce(0, +)) / Double(blueRows.count)
        } catch { print("源坐标方向测试失败：\(error)"); return false }
    }

    static func threshold() -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        func setCPU(_ value: Double) {
            state.snapshot = SystemSnapshot(timestamp: Date(), cpuUsage: value, memoryPressure: .normal,
                swapUsedBytes: nil, diskAvailableBytes: nil, diskTotalBytes: nil,
                networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
                battery: BatteryMetrics(temperatureCelsius: nil, systemPowerWatts: nil), thermal: .nominal)
        }
        setCPU(0.699)
        guard !state.catDisplay(reducedMotion: false).speedLines else { return false }
        setCPU(0.7)
        guard state.catDisplay(reducedMotion: false).speedLines else { return false }
        state.networkTone = .red
        return state.catDisplay(reducedMotion: false).stopped && !state.catDisplay(reducedMotion: false).speedLines
    }

    static func extremeGeometry() -> Bool {
        let root = URL(fileURLWithPath: "build/acceptance/cat-tests/extreme.cat", isDirectory: true)
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            var pixels = [UInt8](repeating: 0, count: 10 * 4096 * 4)
            for frame in 0..<5 {
                let offset = frame * 2 * 4
                pixels[offset] = 255; pixels[offset + 3] = 255
            }
            let image = pixels.withUnsafeMutableBytes { memory -> CGImage? in
                CGContext(data: memory.baseAddress, width: 10, height: 4096, bitsPerComponent: 8,
                          bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
            guard let image else { return false }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return false }
            try (output as Data).write(to: root.appendingPathComponent("run.png"))
            let manifest: [String: Any] = [
                "schemaVersion": 1, "id": "extreme", "name": "边界测试",
                "run": ["image": "run.png", "rendering": "original", "sheetSize": [10, 4096],
                        "canvas": [2, Int.max - 1024], "noseAnchor": 1, "topPadding": Int.max - 2048,
                        "frames": (0..<5).map { ["source": [$0 * 2, 0, 2, 4096], "noseX": $0 * 2 + 1] }],
                "severe": ["image": "run.png", "sheetSize": [10, 4096], "bounds": [0, 0, 2, 4096], "zzAnchorFraction": 0.5]
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
            let cat = try CatPackageLoader.load(at: root)
            let display = CatDisplay(id: cat.id, name: cat.name, rendering: "original", level: .normal,
                load: 0, frameInterval: 0.5, speedLines: false, template: false, stopped: false, reducedMotion: false)
            return png(CatRenderer.image(cat: cat, display: display, frame: 0)) != nil
        } catch { print("极端几何测试失败：\(error)"); return false }
    }
}
