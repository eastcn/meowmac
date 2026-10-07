import AppKit
import MeowMacCore
import MeowMacUI

@MainActor
enum MenuBarCatImageTests {
    static func display(_ cat: LoadedCat?, _ level: HealthLevel, _ load: Double, _ reduced: Bool) -> CatDisplay {
        CatDisplay(id: cat?.id ?? "vector", name: "测试", rendering: cat?.package.rendering ?? "vector", level: level,
            load: load, frameInterval: 0.2, speedLines: load >= 0.7 && level != .severe,
            template: level == .normal && cat?.package.rendering != "original", stopped: level == .severe, reducedMotion: reduced)
    }
    static func bytes(_ image: NSImage) -> Data? {
        guard let rep = image.representations.first as? NSBitmapImageRep, let pointer = rep.bitmapData else { return nil }
        return Data(bytes: pointer, count: rep.bytesPerRow * rep.pixelsHigh)
    }
    static func pixels() -> Bool {
        do {
            // 合成原色猫由现有方向夹具通过正式载入器生成。
            guard CatRenderTests.orientation() else { return false }
            var cats: [LoadedCat?] = [nil]
            cats += try CatPackageLoader.builtinIDs.map { try CatPackageLoader.builtin($0) }
            cats.append(try CatPackageLoader.load(at: URL(fileURLWithPath: "build/acceptance/cat-tests/orientation.cat")))
            for cat in cats {
                let cache = MenuBarCatImage()
                for name in [NSAppearance.Name.aqua, .darkAqua] {
                    let appearance = NSAppearance(named: name)!
                    for scale in [CGFloat(1), 2, 3] {
                        for size in [CGSize(width: 50, height: 18), CGSize(width: 75, height: 27)] {
                            for level in [HealthLevel.normal, .warn, .severe] {
                                for load in [0.2, 0.9] {
                                    for reduced in [false, true] {
                                        let value = display(cat, level, load, reduced)
                                        for frame in -1...5 {
                                            let cached = cache.image(cat: cat, display: value, frame: frame, size: size, appearance: appearance, scale: scale)
                                            let source = CatRenderer.image(cat: cat, display: value, frame: frame, size: size)
                                            let reference = MenuBarCatImage.rasterize(source, appearance: appearance, scale: scale)
                                            let output = MenuBarCatImage.rasterize(cached, appearance: appearance, scale: scale)
                                            guard bytes(output) == bytes(reference), cached.isTemplate == reference.isTemplate,
                                                  cache.count <= MenuBarCatImage.capacity else { return false }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return true
        } catch { return false }
    }
    static func reuse() -> Bool {
        do {
            let cache = MenuBarCatImage(), cat = try CatPackageLoader.builtin("builtin.slim")
            let appearance = NSAppearance(named: .aqua)!
            var preparations = 0, draws = 0
            cache.observe = { event, _ in if event == "imagePreparation" { preparations += 1 }; if event == "renderDraw" { draws += 1 } }
            let first = cache.image(cat: cat, display: display(cat, .normal, 0.2, false), frame: 0, appearance: appearance, scale: 2)
            let changedLoad = cache.image(cat: cat, display: display(cat, .normal, 0.3, false), frame: 5, appearance: appearance, scale: 2)
            guard first === changedLoad, preparations == 1, draws > 0 else { return false }
            for frame in 1...10 { _ = cache.image(cat: cat, display: display(cat, .normal, 0.2, false), frame: frame, appearance: appearance, scale: 2) }
            guard preparations == 5 else { return false }
            let stopped = cache.image(cat: cat, display: display(cat, .severe, 0.9, false), frame: 4, appearance: appearance, scale: 2)
            for frame in 0..<5 { guard stopped === cache.image(cat: cat, display: display(cat, .severe, 0.9, false), frame: frame, appearance: appearance, scale: 2) else { return false } }
            guard preparations == 6 else { return false }
            // 恢复必须显示准确首帧。重新载入相同 id 也会释放旧代准备结果。
            guard first === cache.image(cat: cat, display: display(cat, .normal, 0.2, false), frame: 0, appearance: appearance, scale: 2) else { return false }
            weak var old = first
            let replacement = try CatPackageLoader.builtin("builtin.slim")
            let new = cache.image(cat: replacement, display: display(replacement, .normal, 0.2, false), frame: 0, appearance: appearance, scale: 2)
            guard new !== first, cache.count == 1 else { return false }
            // 外部强引用仍存活，不把它计入缓存；容量按实际所有权核对。
            _ = old
            for width in 50..<90 { _ = cache.image(cat: replacement, display: display(replacement, .normal, 0.2, false), frame: 0, size: CGSize(width: width, height: 18), appearance: appearance, scale: 2) }
            return cache.count == MenuBarCatImage.capacity
        } catch { return false }
    }
    static func releaseGeneration() -> Bool {
        do {
            let cache = MenuBarCatImage(), appearance = NSAppearance(named: .aqua)!
            let cat = try CatPackageLoader.builtin("builtin.slim")
            var image: NSImage? = cache.image(cat: cat, display: display(cat, .normal, 0.2, false), frame: 0, appearance: appearance, scale: 2)
            weak var old = image
            image = nil
            guard old != nil else { return false }
            let other = try CatPackageLoader.builtin("builtin.round")
            _ = cache.image(cat: other, display: display(other, .normal, 0.2, false), frame: 0, appearance: appearance, scale: 2)
            return old == nil && cache.count == 1
        } catch { return false }
    }
    static func changedContent() -> Bool {
        do {
            guard CatRenderTests.orientation() else { return false }
            let root = URL(fileURLWithPath: "build/acceptance/cat-tests/orientation.cat")
            let first = try CatPackageLoader.load(at: root)
            let path = root.appendingPathComponent("run.png")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 40, bitsPerPixel: 32)!
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide { rep.setColor(NSColor(deviceRed: 0, green: 1, blue: 0, alpha: x % 2 == y ? 1 : 0), atX: x, y: y) } }
            try rep.representation(using: .png, properties: [:])!.write(to: path)
            let second = try CatPackageLoader.load(at: root)
            let cache = MenuBarCatImage(), appearance = NSAppearance(named: .aqua)!
            let old = cache.image(cat: first, display: display(first, .normal, 0.2, false), frame: 0, appearance: appearance, scale: 2)
            let new = cache.image(cat: second, display: display(second, .normal, 0.2, false), frame: 0, appearance: appearance, scale: 2)
            let reference = MenuBarCatImage.rasterize(CatRenderer.image(cat: second, display: display(second, .normal, 0.2, false), frame: 0), appearance: appearance, scale: 2)
            return first.id == second.id && bytes(old) != bytes(new) && bytes(new) == bytes(reference) && cache.count == 1
        } catch { print("同 id 内容夹具失败：\(error)"); return false }
    }
    static var tests: [(String, @MainActor () async -> Bool)] { [
        ("UI.MenuBarCatImage/原渲染器逐像素参照所有条件", { pixels() }),
        ("UI.MenuBarCatImage/帧归一化负载复用容量与恢复首帧", { reuse() }),
        ("UI.MenuBarCatImage/内容代际释放", { releaseGeneration() }),
        ("UI.MenuBarCatImage/同id新内容首帧", { changedContent() })
    ] }
}
