import AppKit
import MeowMacUI

@MainActor
enum AppIconTests {
    static func sizes() -> Bool {
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            let data = AppIcon.png(size: size)
            guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide == size, bitmap.pixelsHigh == size,
                  let corner = bitmap.colorAt(x: 0, y: 0), corner.alphaComponent < 0.05,
                  let tile = bitmap.colorAt(x: size / 2, y: size / 4)?.usingColorSpace(.deviceRGB),
                  tile.alphaComponent > 0.95, tile.blueComponent > tile.redComponent + 0.06,
                  tile.blueComponent > tile.greenComponent + 0.025,
                  let cat = bitmap.colorAt(x: size / 2, y: size / 2)?.usingColorSpace(.deviceRGB),
                  cat.redComponent > 0.9, cat.greenComponent > 0.9 else { return false }
            if let path = ProcessInfo.processInfo.environment["MEOWMAC_ICON_PREVIEW_DIR"] {
                do {
                    let directory = URL(fileURLWithPath: path, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appendingPathComponent("icon-\(size).png"))
                } catch { print("图标预览保存失败：\(error)"); return false }
            }
        }
        return AppIcon.png(size: 0).isEmpty && AppIcon.png(size: 2048).isEmpty
    }
}
