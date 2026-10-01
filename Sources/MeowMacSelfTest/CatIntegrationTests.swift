import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum CatIntegrationTests {
    static func snapshotAndSwitch() -> Bool {
        let base = URL(fileURLWithPath: "build/acceptance/cat-tests/integration", isDirectory: true)
        let root = base.appendingPathComponent("app", isDirectory: true)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: base.path) { try manager.removeItem(at: base) }
            try manager.createDirectory(at: base, withIntermediateDirectories: false)
            let store = CatStore(rootURL: root)
            let state = PanelPreviewRenderer.syntheticState()
            CatRuntime.initialize(state: state, store: store, environment: [:])
            guard state.selectedCat?.id == "builtin.slim" else { return false }
            for id in CatPackageLoader.builtinIDs {
                try store.select(id, state: state)
                let data = try JSONEncoder().encode(PanelSnapshot(state: state))
                let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                guard let cat = object["cat"] as? [String: Any],
                      cat["id"] as? String == id,
                      cat["name"] as? String == state.selectedCat?.name,
                      cat["rendering"] as? String == state.selectedCat?.package.rendering,
                      cat["template"] as? Bool == (state.selectedCat?.package.rendering == "template") else { return false }
                let image = CatRenderer.image(cat: state.selectedCat, display: state.catDisplay(), frame: 0)
                guard image.isTemplate == (cat["template"] as? Bool) else { return false }
            }
            let restarted = PanelPreviewRenderer.syntheticState()
            CatRuntime.initialize(state: restarted, store: CatStore(rootURL: root),
                                  environment: ["MEOWMAC_FORCE_LEVEL": "severe"])
            guard restarted.selectedCat?.id == "builtin.orange-white",
                  restarted.catDisplay().level == .severe,
                  restarted.catDisplay().stopped,
                  !restarted.catDisplay().template,
                  restarted.catDisplay().nextFrame(3, sleeping: false) == 3 else { return false }
            restarted.catLevelOverride = .normal
            guard restarted.catDisplay(reducedMotion: false).nextFrame(3, sleeping: true) == 3,
                  restarted.catDisplay(reducedMotion: false).nextFrame(3, sleeping: false) == 4,
                  restarted.catDisplay(reducedMotion: true).nextFrame(3, sleeping: false) == 0 else { return false }
            restarted.catLevelOverride = .severe
            let severe0 = CatRenderer.image(cat: restarted.selectedCat, display: restarted.catDisplay(), frame: 0)
            let severe4 = CatRenderer.image(cat: restarted.selectedCat, display: restarted.catDisplay(), frame: 4)
            guard severe0.tiffRepresentation == severe4.tiffRepresentation else { return false }
            let selection = root.appendingPathComponent("cat-selection.json")
            try Data(#"{"schemaVersion":1,"selectedID":"missing-cat"}"#.utf8).write(to: selection)
            let fallback = PanelPreviewRenderer.syntheticState()
            CatRuntime.initialize(state: fallback, store: CatStore(rootURL: root), environment: [:])
            let fallbackData = try JSONEncoder().encode(PanelSnapshot(state: fallback))
            let fallbackObject = try JSONSerialization.jsonObject(with: fallbackData) as! [String: Any]
            return fallback.selectedCat?.id == "builtin.slim" &&
                (fallbackObject["cat"] as? [String: Any])?["id"] as? String == "builtin.slim"
        } catch { print("猫配置应用快照接入失败：\(error)"); return false }
    }

    static func menuDuplicates() -> Bool {
        let base = URL(fileURLWithPath: "build/acceptance/cat-tests/menu", isDirectory: true)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: base.path) { try manager.removeItem(at: base) }
            try manager.createDirectory(at: base, withIntermediateDirectories: false)
            let store = CatStore(rootURL: base.appendingPathComponent("app"))
            let state = PanelPreviewRenderer.syntheticState()
            CatRuntime.initialize(state: state, store: store, environment: [:])
            for id in ["demo-two", "demo-one"] {
                let source = base.appendingPathComponent(id + ".cat", isDirectory: true)
                try manager.copyItem(at: URL(fileURLWithPath: "Sources/MeowMacUI/Resources/Cats/builtin.slim.cat"), to: source)
                let manifest = source.appendingPathComponent("manifest.json")
                var value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
                value["id"] = id; value["name"] = "重复名称"
                try JSONSerialization.data(withJSONObject: value).write(to: manifest)
                try store.importCat(from: source, state: state)
            }
            guard let cats = SettingsMenu.make(state: state).items[3].submenu else { return false }
            return cats.items[4].title == "重复名称（demo-one）" &&
                cats.items[5].title == "重复名称（demo-two）" &&
                cats.items[4].state == .on && cats.items[5].state == .off
        } catch { print("重名菜单测试失败：\(error)"); return false }
    }
}
