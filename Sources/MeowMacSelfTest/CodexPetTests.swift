import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MeowMacCore
import MeowMacUI

/// 桌面猫使用 Codex 宠物（docs/plans/2026-10-25-codex-pet）。图集在测试中合成，不用真实宠物。
@MainActor
enum CodexPetTests {
    static var tests: [(String, @MainActor () async -> Bool)] {
        var all: [(String, @MainActor () async -> Bool)] = [
            ("Core.CodexPet/清单解析与路径约束", { manifest() }),
            ("Core.CodexPet/档位与负载选行、取格", { pose() }),
            ("Core.CodexPet/配置字段往返与坏值回退", { config() }),
            ("UI.CodexPet/加载 v1、v2 图集并按共同范围裁剪", { load() }),
            ("UI.CodexPet/拒绝坏图集、缺动作和符号链接", { rejects() }),
            ("UI.CodexPet/列表只含有效宠物并排序", { list() }),
            ("UI.CodexPet/桌面猫按宠物绘制、缓存与投影", { render() }),
            ("UI.CodexPet/宠物不可用时回到当前猫", { fallback() }),
            ("UI.CodexPet/帧计数超过 5 继续递增", { counter() }),
        ]
        if ProcessInfo.processInfo.environment["MEOWMAC_LIVE"] == "1" {
            all.append(("Live.CodexPet/本机宠物加载并渲染到 build/acceptance", { live() }))
        }
        return all
    }

    /// 只读本机 `$CODEX_HOME/pets`，每只宠物每个用到的行渲染一张帧条，原图只写 build/acceptance/。
    static func live() -> Bool {
        let output = URL(fileURLWithPath: "build/acceptance/codex-pet", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = CodexPetLibrary.defaultRoot()
        let entries = CodexPetLibrary.list(root: root)
        print("宠物：\(entries.map(\.id))")
        guard !entries.isEmpty else { return false }
        let cache = DesktopCatImage()
        for entry in entries {
            guard let pet = try? CodexPetLibrary.load(entry.id, root: root) else { print("加载失败：\(entry.id)"); return false }
            let cases: [(String, CatDisplay)] = [("idle", display(level: .normal, load: 0.1)), ("run", display(level: .normal, load: 0.8)),
                                                 ("warn", display(level: .warn, load: 0.1)), ("severe", display(level: .severe, load: 0.1))]
            print("\(entry.id)：帧 \(Int(pet.frameSize.width))×\(Int(pet.frameSize.height))，" +
                  cases.map { "\($0.0) \(pet.frames(CodexPetPose.row(level: $0.1.level, load: $0.1.load)).count)" }.joined(separator: "、"))
            for dark in [false, true] {
                let size = DesktopCatLayout.catSize
                let strip = NSImage(size: NSSize(width: size.width * 8, height: size.height * 4), flipped: true) { _ in
                    (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
                    NSRect(x: 0, y: 0, width: size.width * 8, height: size.height * 4).fill()
                    for (row, item) in cases.enumerated() {
                        for frame in 0..<8 {
                            cache.image(cat: nil, pet: pet, display: item.1, frame: frame, dark: dark, scale: 2)
                                .draw(in: NSRect(x: CGFloat(frame) * size.width, y: CGFloat(row) * size.height, width: size.width, height: size.height))
                        }
                    }
                    return true
                }
                guard let tiff = strip.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
                try? png.write(to: output.appendingPathComponent("\(entry.id)-\(dark ? "dark" : "light").png"))
            }
        }
        return true
    }

    /// 合成的行帧数：待机 6、向右跑 8、失败 3、等待 4。
    nonisolated static let frameCounts: [CodexPetRow: Int] = [.idle: 6, .runningRight: 8, .failed: 3, .waiting: 4]

    static func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("meowmac-pets-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 每个非空格子画一块不透明色块，位置随列偏移，用来检验共同裁剪范围。
    static func atlas(version: Int, counts: [CodexPetRow: Int] = frameCounts, type: UTType = .png,
                      size: (width: Int, height: Int)? = nil) -> Data {
        let expected = size ?? CodexPetAtlas.size(version: version)
        let context = CGContext(data: nil, width: expected.width, height: expected.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.55, blue: 0.2, alpha: 1))
        for (row, count) in counts {
            for column in 0..<count {
                let cell = CodexPetAtlas.cell(row: row.rawValue, column: column)
                // 图集坐标原点在左上，CGContext 在左下。
                // 失败行第 2 格最扁，代表倒地；其余格子同一大小，逐列右移 2 px。
                let rect = row == .failed && column == 1 ? CGRect(x: cell.x + 20, y: cell.y + 120, width: 160, height: 60)
                    : CGRect(x: cell.x + 40 + column * 2, y: cell.y + 60, width: 100, height: 120)
                context.fill(CGRect(x: rect.minX, y: CGFloat(expected.height) - rect.maxY, width: rect.width, height: rect.height))
            }
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @discardableResult
    static func writePet(_ root: URL, id: String, name: String = "示例宠物", version: Int? = 2, sheet: String = "spritesheet.png",
                         image: Data? = nil) -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [String: Any] = ["id": id, "displayName": name, "description": "虚构的测试宠物。", "spritesheetPath": sheet, "kind": "object"]
        if let version { manifest["spriteVersionNumber"] = version }
        try? JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("pet.json"))
        try? (image ?? atlas(version: version ?? 1)).write(to: directory.appendingPathComponent(sheet))
        return directory
    }

    static func manifest() -> Bool {
        func parse(_ text: String) -> CodexPetManifest? { try? CodexPetManifest.parse(Data(text.utf8)) }
        guard let v2 = parse(#"{"id":"demo","displayName":" 示例 ","spritesheetPath":"sheet.webp","spriteVersionNumber":2,"extra":true}"#),
              v2 == CodexPetManifest(id: "demo", displayName: "示例", spritesheetPath: "sheet.webp", version: 2) else { return false }
        guard let v1 = parse(#"{"id":"demo","spritesheetPath":"sheet.png"}"#), v1.version == 1, v1.displayName == "demo" else { return false }
        let bad = [
            #"[1]"#, #"{"spritesheetPath":"a.png"}"#, #"{"id":"d"}"#,
            #"{"id":"d","spritesheetPath":"../a.png"}"#, #"{"id":"d","spritesheetPath":"a/b.png"}"#,
            #"{"id":"d","spritesheetPath":".a.png"}"#, #"{"id":"d","spritesheetPath":"a.gif"}"#,
            #"{"id":"d","spritesheetPath":"a.png","spriteVersionNumber":3}"#,
        ]
        guard bad.allSatisfy({ parse($0) == nil }) else { return false }
        guard (try? CodexPetManifest.parse(Data(repeating: 32, count: CodexPetManifest.maxBytes + 1))) == nil else { return false }
        return CodexPetManifest.isValidDirectoryName("nian-gao_2.v")
            && !CodexPetManifest.isValidDirectoryName("..") && !CodexPetManifest.isValidDirectoryName(".hidden")
            && !CodexPetManifest.isValidDirectoryName("a/b") && !CodexPetManifest.isValidDirectoryName("年糕")
            && !CodexPetManifest.isValidDirectoryName(String(repeating: "a", count: 65))
    }

    static func pose() -> Bool {
        guard CodexPetPose.row(level: .normal, load: 0) == .idle, CodexPetPose.row(level: .normal, load: 0.29) == .idle,
              CodexPetPose.row(level: .normal, load: 0.3) == .runningRight, CodexPetPose.row(level: .normal, load: .nan) == .idle,
              CodexPetPose.row(level: .warn, load: 0.9) == .waiting, CodexPetPose.row(level: .severe, load: 0.9) == .failed else { return false }
        return CodexPetPose.frame(row: .idle, counter: 7, frameCount: 6, frozen: false) == 1
            && CodexPetPose.frame(row: .idle, counter: 7, frameCount: 6, frozen: true) == 0
            && CodexPetPose.frame(row: .failed, counter: 7, frameCount: 3, frozen: false) == 2
            && CodexPetPose.frame(row: .failed, counter: 0, frameCount: 3, frozen: true) == 2
            && CodexPetPose.frame(row: .waiting, counter: -1, frameCount: 4, frozen: false) == 3
            && CodexPetPose.frame(row: .idle, counter: 3, frameCount: 0, frozen: false) == 0
    }

    static func config() -> Bool {
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Data(#"{"schemaVersion":1,"desktopCat":{"enabled":true,"pet":"demo"}}"#.utf8).write(to: url)
            let loaded = ConfigStore.load(from: url).config.desktopCat
            guard loaded.pet == "demo", loaded.enabled, loaded.diagnostics.isEmpty else { return false }
            try ConfigStore.saveDesktopCat(loaded.with(pet: "other"), to: url)
            guard (DesktopCatConfigTests.json(url)?["desktopCat"] as? [String: Any])?["pet"] as? String == "other" else { return false }
            try ConfigStore.saveDesktopCat(loaded.with(pet: nil), to: url)
            guard (DesktopCatConfigTests.json(url)?["desktopCat"] as? [String: Any])?["pet"] == nil else { return false }
            guard (try? DesktopCatConfig().with(pet: "../x").validated()) == nil else { return false }
            try Data(#"{"schemaVersion":1,"desktopCat":{"enabled":true,"pet":"../x"}}"#.utf8).write(to: url)
            let bad = ConfigStore.load(from: url).config.desktopCat
            return bad.pet == nil && bad.enabled && bad.diagnostics == ["桌面猫的宠物名无效，已跟随当前猫"]
        } catch { return false }
    }

    static func load() -> Bool {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        writePet(root, id: "v2", version: 2)
        writePet(root, id: "v1", version: nil, sheet: "spritesheet.webp", image: atlas(version: 1))
        guard let v2 = try? CodexPetLibrary.load("v2", root: root), let v1 = try? CodexPetLibrary.load("v1", root: root) else { return false }
        for pet in [v1, v2] {
            for (row, count) in frameCounts where pet.frames(row).count != (row == .failed ? 1 : count) { return false }
            // 共同范围：左边是倒地格的 20，右边是倒地格的 180，上下 60～180。没播放的失败格不计入。
            guard pet.frameSize == CGSize(width: 160, height: 120),
                  pet.rows.values.flatMap({ $0 }).allSatisfy({ CGFloat($0.width) == pet.frameSize.width && CGFloat($0.height) == pet.frameSize.height }) else { return false }
        }
        return v2.id == "v2" && v2.name == "示例宠物"
    }

    static func rejects() -> Bool {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        func error(_ id: String) -> String? {
            do { _ = try CodexPetLibrary.load(id, root: root); return nil } catch { return error.localizedDescription }
        }
        writePet(root, id: "size", version: 2, image: atlas(version: 1))
        writePet(root, id: "rows", image: atlas(version: 2, counts: [.idle: 6, .runningRight: 8, .failed: 3]))
        writePet(root, id: "gif", image: atlas(version: 2, type: .gif))
        let real = writePet(root, id: "real")
        try? FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: real)
        let sheetLink = root.appendingPathComponent("sheet-link", isDirectory: true)
        try? FileManager.default.createDirectory(at: sheetLink, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: real.appendingPathComponent("pet.json"), to: sheetLink.appendingPathComponent("pet.json"))
        try? FileManager.default.createSymbolicLink(at: sheetLink.appendingPathComponent("spritesheet.png"),
                                                    withDestinationURL: real.appendingPathComponent("spritesheet.png"))
        guard error("real") == nil,
              error("size")?.contains("1536×2288") == true,
              error("rows")?.contains("等待") == true,
              error("gif")?.contains("PNG 或 WebP") == true,
              error("linked") != nil, error("sheet-link") != nil,
              error("missing") == CodexPetError.missing.localizedDescription,
              error("../real") != nil else { return false }
        return true
    }

    static func list() -> Bool {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        writePet(root, id: "b", name: "乙")
        writePet(root, id: "a", name: "甲")
        let broken = root.appendingPathComponent("broken", isDirectory: true)
        try? FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try? Data("{".utf8).write(to: broken.appendingPathComponent("pet.json"))
        try? Data("zip".utf8).write(to: root.appendingPathComponent("c.zip"))
        let entries = CodexPetLibrary.list(root: root)
        return entries.map(\.id).sorted() == ["a", "b"] && Set(entries.map(\.name)) == ["甲", "乙"]
            && CodexPetLibrary.list(root: root.appendingPathComponent("none")).isEmpty
            && CodexPetLibrary.defaultRoot(environment: ["CODEX_HOME": "/tmp/codex-home"]).path == "/tmp/codex-home/pets"
            && CodexPetLibrary.defaultRoot(environment: [:]).path.hasSuffix("/.codex/pets")
    }

    static func display(level: HealthLevel, load: Double, reducedMotion: Bool = false) -> CatDisplay {
        CatDisplay(id: "builtin.slim", name: "标准瘦身", rendering: "template", level: level, load: load, frameInterval: 0.5,
                   speedLines: load >= 0.7, template: level == .normal, stopped: level == .severe, reducedMotion: reducedMotion)
    }

    static func render() -> Bool {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        writePet(root, id: "demo")
        guard let pet = try? CodexPetLibrary.load("demo", root: root) else { return false }
        let cache = DesktopCatImage()
        let idle = display(level: .normal, load: 0.1)
        let first = cache.image(cat: nil, pet: pet, display: idle, frame: 1, dark: false, scale: 2)
        // 待机 6 帧：计数 7 与 1 是同一格。
        guard first.size == DesktopCatLayout.catSize, cache.image(cat: nil, pet: pet, display: idle, frame: 7, dark: false, scale: 2) === first,
              cache.rasterizations == 1 else { return false }
        // 换到跑步行是新图。
        let running = cache.image(cat: nil, pet: pet, display: display(level: .normal, load: 0.8), frame: 1, dark: false, scale: 2)
        guard running !== first, cache.rasterizations == 2 else { return false }
        // 严重静止：任何计数都是同一张。
        let severe = display(level: .severe, load: 0.8)
        let sleeping = cache.image(cat: nil, pet: pet, display: severe, frame: 0, dark: false, scale: 2)
        guard cache.image(cat: nil, pet: pet, display: severe, frame: 5, dark: false, scale: 2) === sleeping else { return false }
        // 宠物不染色、不加速度线：像素保持原色。
        guard let rep = running.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let center = rep.colorAt(x: rep.pixelsWide - 40, y: rep.pixelsHigh / 2), center.alphaComponent > 0.9,
              center.redComponent > center.blueComponent + 0.3 else { return false }
        // 帧 160×120，缩到 52 pt 高约 69 pt 宽，靠右放；投影和左缘都跟随帧宽。
        let size = DesktopCatImage.petSize(pet, in: DesktopCatLayout.catSize)
        guard size == CGSize(width: 69, height: 52),
              cache.leadingTrim(cat: nil, pet: pet, display: idle, dark: false, scale: 2) == DesktopCatLayout.catSize.width - 69 else { return false }
        let shadow = cache.shadow(pet: pet)
        return shadow.x > DesktopCatLayout.catSize.width - 69 && shadow.x + shadow.width < DesktopCatLayout.catSize.width
            && cache.shadow(pet: nil) == .cat
    }

    static func fallback() -> Bool {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        writePet(root, id: "demo")
        let state = PanelPreviewRenderer.syntheticState()
        state.desktopCatConfigURL = url
        state.codexPetsRoot = root
        guard state.updateDesktopCat({ $0.with(pet: "demo") }) else { return false }
        state.syncDesktopPet()
        guard let loaded = state.desktopPet, loaded.id == "demo", state.desktopPetError == nil else { return false }
        // 同一只不重读。
        state.syncDesktopPet()
        guard state.desktopPet === loaded else { return false }
        // 宠物被删后换选：回到当前猫并写原因。
        try? FileManager.default.removeItem(at: root.appendingPathComponent("demo"))
        guard state.updateDesktopCat({ $0.with(pet: "gone") }) else { return false }
        state.syncDesktopPet()
        guard state.desktopPet == nil, state.desktopPetError?.contains("“gone”不可用") == true else { return false }
        let options = DesktopCatSettingsActions(state: state).petOptions
        guard options.first?.title == DesktopCatSettingsActions.followCatTitle, options.last?.title == "gone（不可用）" else { return false }
        // 换回跟随当前猫。
        DesktopCatSettingsActions(state: state).setPet(nil)
        state.syncDesktopPet()
        return state.desktopCat.pet == nil && state.desktopPet == nil && state.desktopPetError == nil
    }

    static func counter() -> Bool {
        let moving = display(level: .normal, load: 0.5)
        return moving.nextFrame(4, sleeping: false) == 5 && moving.nextFrame(839, sleeping: false) == 0
            && moving.frame(7) == 2
            && display(level: .normal, load: 0.5, reducedMotion: true).nextFrame(6, sleeping: false) == 0
            && display(level: .severe, load: 0.5).nextFrame(6, sleeping: false) == 6
    }
}
