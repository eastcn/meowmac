import AppKit
import MeowMacCore

/// 桌面猫的大尺寸帧图缓存（D10）。键是（猫、帧、档位、外观、速度线、尺寸、显示尺度），同一帧不重复光栅化。
@MainActor
public final class DesktopCatImage {
    public static let capacity = 32
    private struct Key: Equatable {
        let cat: String
        let run: ObjectIdentifier?
        let frame: Int
        let level: HealthLevel
        let rendering: String
        let template: Bool
        let speedLines: Bool
        let reducedMotion: Bool
        let dark: Bool
        let width: CGFloat, height: CGFloat
        let scale: CGFloat
    }
    private var entries: [(Key, NSImage)] = []
    /// 实际光栅化的次数，供测试断言缓存命中。
    public private(set) var rasterizations = 0
    public var count: Int { entries.count }
    public init() {}

    public func image(cat: LoadedCat?, display: CatDisplay, frame: Int, dark: Bool, scale: CGFloat,
                      size: CGSize = DesktopCatLayout.catSize) -> NSImage {
        let normalized = display.stopped || display.level == .severe ? 0 : display.frame(frame)
        let key = Key(cat: cat?.id ?? "vector", run: cat.map { ObjectIdentifier($0.run) }, frame: normalized, level: display.level,
                      rendering: display.rendering, template: display.template, speedLines: display.speedLines,
                      reducedMotion: display.reducedMotion, dark: dark, width: size.width, height: size.height, scale: scale)
        if let cached = entries.first(where: { $0.0 == key })?.1 { return cached }
        // 矢量回退猫按原稿 44×28 的比例放在右侧，不拉伸。
        let drawSize = cat == nil ? CGSize(width: (size.height * 44 / 28).rounded(), height: size.height) : size
        let source = CatRenderer.image(cat: cat, display: display, frame: normalized, size: drawSize)
        let prepared = Self.compose(source, in: size, dark: dark, scale: scale)
        rasterizations += 1
        if entries.count == Self.capacity { entries.removeFirst() }
        entries.append((key, prepared))
        return prepared
    }

    /// 单色模板在浅色外观染成近黑、深色外观染成近白；所有猫加 1 pt 反色描边，在任何壁纸上都看得见。
    static func compose(_ source: NSImage, in size: CGSize, dark: Bool, scale: CGFloat) -> NSImage {
        let pixelsWide = Int((size.width * scale).rounded()), pixelsHigh = Int((size.height * scale).rounded())
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: pixelsWide * 4, bitsPerPixel: 32)!
        rep.size = size
        let ink = dark ? NSColor(srgbRed: 240 / 255, green: 241 / 255, blue: 244 / 255, alpha: 1) : NSColor(srgbRed: 34 / 255, green: 35 / 255, blue: 38 / 255, alpha: 1)
        let outline = dark ? NSColor.black.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.85)
        let drawRect = NSRect(x: size.width - source.size.width, y: 0, width: source.size.width, height: source.size.height)
        func tinted(_ color: NSColor?) -> NSImage {
            let image = NSImage(size: size, flipped: false) { rect in
                source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
                if let color { color.setFill(); rect.fill(using: .sourceIn) }
                return true
            }
            return image
        }
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let edge = tinted(outline)
            for dx in [-1.0, 0, 1] { for dy in [-1.0, 0, 1] where dx != 0 || dy != 0 {
                edge.draw(in: NSRect(x: dx, y: dy, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1)
            } }
            tinted(source.isTemplate ? ink : nil).draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
