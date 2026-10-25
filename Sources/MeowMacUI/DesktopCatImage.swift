import AppKit
import MeowMacCore

/// 桌面猫的大尺寸帧图缓存（D10）。键是（猫、帧、档位、外观、速度线、尺寸、显示尺度），同一帧不重复光栅化。
/// 缓存只留一个高度（plan D16）：换到新高度时清掉其他高度的帧图，拖把手经过很多高度也不会越积越多。
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
    /// 缓存里帧图的高度，供测试断言只留当前高度。
    public var cachedHeights: Set<CGFloat> { Set(entries.map(\.0.height)) }
    public init() {}

    private func store(_ key: Key, _ image: NSImage) {
        if entries.contains(where: { $0.0.height != key.height }) {
            entries.removeAll { $0.0.height != key.height }
            trims.removeAll()
        }
        rasterizations += 1
        if entries.count == Self.capacity { entries.removeFirst() }
        entries.append((key, image))
    }

    public func image(cat: LoadedCat?, pet: LoadedCodexPet? = nil, display: CatDisplay, frame: Int, dark: Bool, scale: CGFloat,
                      size: CGSize = DesktopCatLayout.catSize) -> NSImage {
        if let pet { return image(pet: pet, display: display, frame: frame, dark: dark, scale: scale, size: size) }
        let normalized = display.stopped || display.level == .severe ? 0 : display.frame(frame)
        let key = Key(cat: cat?.id ?? "vector", run: cat.map { ObjectIdentifier($0.run) }, frame: normalized, level: display.level,
                      rendering: display.rendering, template: display.template, speedLines: display.speedLines,
                      reducedMotion: display.reducedMotion, dark: dark, width: size.width, height: size.height, scale: scale)
        if let cached = entries.first(where: { $0.0 == key })?.1 { return cached }
        // 矢量回退猫按原稿 44×28 的比例放在右侧，不拉伸。
        let drawSize = cat == nil ? CGSize(width: (size.height * 44 / 28).rounded(), height: size.height) : size
        let source = CatRenderer.image(cat: cat, display: display, frame: normalized, size: drawSize)
        let prepared = Self.compose(source, in: size, dark: dark, scale: scale)
        store(key, prepared)
        return prepared
    }

    /// 宠物帧：按 plan P4 选行和格子，等比缩放到格子高度，靠右放，不染色、不加速度线。
    private func image(pet: LoadedCodexPet, display: CatDisplay, frame: Int, dark: Bool, scale: CGFloat, size: CGSize) -> NSImage {
        let row = CodexPetPose.row(level: display.level, load: display.load)
        let frames = pet.frames(row)
        let index = CodexPetPose.frame(row: row, counter: frame, frameCount: frames.count, frozen: display.reducedMotion)
        let key = Key(cat: "pet:" + pet.id, run: ObjectIdentifier(pet), frame: row.rawValue * 100 + index, level: display.level,
                      rendering: "pet", template: false, speedLines: false, reducedMotion: display.reducedMotion, dark: dark,
                      width: size.width, height: size.height, scale: scale)
        if let cached = entries.first(where: { $0.0 == key })?.1 { return cached }
        let drawSize = Self.petSize(pet, in: size)
        let source = NSImage(cgImage: frames[index], size: drawSize)
        let prepared = Self.compose(source, in: size, dark: dark, scale: scale)
        store(key, prepared)
        return prepared
    }

    /// 宠物帧在格子里的尺寸：先按高度缩放，太宽时再按宽度收。
    public static func petSize(_ pet: LoadedCodexPet, in size: CGSize) -> CGSize {
        let ratio = min(size.height / pet.frameSize.height, size.width / pet.frameSize.width)
        return CGSize(width: (pet.frameSize.width * ratio).rounded(), height: (pet.frameSize.height * ratio).rounded())
    }

    /// 脚下投影的横向位置和宽度（pt）。猫用设计稿的值，随大小等比缩放；宠物跟随帧宽，靠右放。
    public func shadow(pet: LoadedCodexPet?, size: CGSize = DesktopCatLayout.catSize) -> DesktopCatShadow {
        guard let pet else { return .cat(size: size) }
        let width = Self.petSize(pet, in: size).width
        return DesktopCatShadow(x: size.width - width + width * 0.12, width: width * 0.76)
    }

    private var trims: [(ObjectIdentifier, CGFloat)] = []

    /// 猫可见部分的左缘离格子左边多远（pt）：不带速度线时，跑动一周里最靠左的可见像素。
    /// 用一周的最小值而不是逐帧取，猫跑动时位置不抖；落在左边的角时用它让猫和气泡左对齐。
    public func leadingTrim(cat: LoadedCat?, pet: LoadedCodexPet? = nil, display: CatDisplay, dark: Bool, scale: CGFloat,
                            size: CGSize = DesktopCatLayout.catSize) -> CGFloat {
        if let pet {
            // 宠物各帧按共同可见范围裁过，帧宽就是可见宽度，左缘固定。
            return (size.width - Self.petSize(pet, in: size).width).rounded(.down)
        }
        let reference = CatDisplay(id: display.id, name: display.name, rendering: display.rendering, level: display.level, load: display.load,
                                   frameInterval: display.frameInterval, speedLines: false, template: display.template,
                                   stopped: display.stopped, reducedMotion: display.reducedMotion)
        let first = image(cat: cat, display: reference, frame: 0, dark: dark, scale: scale, size: size)
        let id = ObjectIdentifier(first)
        if let cached = trims.first(where: { $0.0 == id })?.1 { return cached }
        let frames = reference.stopped || reference.reducedMotion || reference.level == .severe ? [0] : Array(0..<5)
        let minimum = frames.map { Self.visibleMinX($0 == 0 ? first : image(cat: cat, display: reference, frame: $0, dark: dark, scale: scale, size: size)) }.min() ?? 0
        // 取整到点：窗口位置按整点落位，带小数会被取整而错开半点。
        let trim = minimum.rounded(.down)
        if trims.count == Self.capacity { trims.removeFirst() }
        trims.append((id, trim))
        return trim
    }

    /// 第一列有不透明像素的位置（pt）；整张透明时为 0。
    public static func visibleMinX(_ image: NSImage, threshold: UInt8 = 24) -> CGFloat {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first, let data = rep.bitmapData,
              rep.bitsPerPixel == 32, rep.samplesPerPixel == 4, rep.pixelsWide > 0 else { return 0 }
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where data[y * rep.bytesPerRow + x * 4 + 3] > threshold {
                return CGFloat(x) * rep.size.width / CGFloat(rep.pixelsWide)
            }
        }
        return 0
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

/// 猫脚下的投影。
public struct DesktopCatShadow: Equatable {
    public let x: CGFloat, width: CGFloat
    public init(x: CGFloat, width: CGFloat) { self.x = x; self.width = width }
    public static let cat = cat(size: DesktopCatLayout.catSize)
    /// 设计稿 52 pt 时 x 18、宽 92，随猫的大小等比缩放。
    public static func cat(size: CGSize) -> DesktopCatShadow {
        let ratio = size.height / DesktopCatSize.defaultHeight
        return DesktopCatShadow(x: 18 * ratio, width: (DesktopCatSize.defaultWidth - 28) * ratio)
    }
}
