import AppKit
import MeowMacCore

/// 菜单栏专用的位图准备缓存。一个内容代际最多保留 32 个绘制输入。
@MainActor
public final class MenuBarCatImage {
    public static let capacity = 32
    /// 宠物比剪影猫细节多、身形接近方形，按 22 pt 高画（菜单栏高 24 pt），比猫的 18 pt 大一号。
    public static let petHeight: CGFloat = 22
    private struct Generation: Equatable {
        let id: String
        let run: ObjectIdentifier?
        let severe: ObjectIdentifier?
        let pet: ObjectIdentifier?
    }
    private struct Key: Equatable {
        let frame: Int
        let level: HealthLevel
        let rendering: String
        let template: Bool
        let speedLines: Bool
        let reducedMotion: Bool
        let width: CGFloat
        let height: CGFloat
        let appearance: String
        let scale: CGFloat
    }
    private var generation: Generation?
    private var sourceCat: LoadedCat?
    private var entries: [(Key, NSImage)] = []
    public var observe: ((String, TimeInterval) -> Void)?
    public var count: Int { entries.count }
    public init() {}

    public func image(cat: LoadedCat?, pet: LoadedCodexPet? = nil, display: CatDisplay, frame: Int,
                      size: CGSize = CGSize(width: 50, height: 18),
                      appearance: NSAppearance, scale: CGFloat) -> NSImage {
        // 载入器每次接受新内容都会生成新 CGImage；逐帧不读文件或哈希猫包。
        let next = Generation(id: cat?.id ?? "vector", run: cat.map { ObjectIdentifier($0.run) }, severe: cat.map { ObjectIdentifier($0.severe) },
                              pet: pet.map(ObjectIdentifier.init))
        if generation != next { entries.removeAll(); generation = next; sourceCat = cat }
        // 宠物按跑步行自己的帧数取格；猫按 5 帧。
        let normalizedFrame = pet.map { CatRenderer.petFrame($0, display: display, frame: frame) }
            ?? (display.stopped || display.level == .severe ? 0 : display.frame(frame))
        let key = Key(frame: normalizedFrame, level: display.level, rendering: display.rendering,
                      template: display.template, speedLines: display.speedLines, reducedMotion: display.reducedMotion,
                      width: size.width, height: size.height, appearance: appearance.name.rawValue, scale: scale)
        if let cached = entries.first(where: { $0.0 == key })?.1 { return cached }
        let started = ProcessInfo.processInfo.systemUptime
        let observer = observe.map { observer in { observer("renderDraw", $0) } }
        let source = pet.map { CatRenderer.petImage($0, display: display, index: normalizedFrame, height: Self.petHeight, observeDraw: observer) }
            ?? CatRenderer.image(cat: cat, display: display, frame: normalizedFrame, size: size, observeDraw: observer)
        let prepared = Self.rasterize(source, appearance: appearance, scale: scale)
        if entries.count == Self.capacity { entries.removeFirst() }
        entries.append((key, prepared))
        observe?("imagePreparation", ProcessInfo.processInfo.systemUptime - started)
        return prepared
    }

    /// 与原绘图使用相同的点尺寸和有效显示尺度，不经 TIFF 隐式选择分辨率。
    public static func rasterize(_ source: NSImage, appearance: NSAppearance, scale: CGFloat) -> NSImage {
        let size = source.size
        let pixelsWide = Int((size.width * scale).rounded()), pixelsHigh = Int((size.height * scale).rounded())
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: pixelsWide * 4, bitsPerPixel: 32)!
        rep.size = size
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = source.isTemplate
        return image
    }

    public func assign(to button: NSStatusBarButton, cat: LoadedCat?, pet: LoadedCodexPet? = nil, display: CatDisplay, frame: Int) {
        let prepared = image(cat: cat, pet: pet, display: display, frame: frame, appearance: button.effectiveAppearance,
                             scale: button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        if button.image !== prepared {
            let started = ProcessInfo.processInfo.systemUptime
            button.image = prepared
            observe?("imageAssignment", ProcessInfo.processInfo.systemUptime - started)
        }
    }
}
