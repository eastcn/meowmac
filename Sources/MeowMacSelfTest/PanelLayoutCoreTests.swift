import Foundation
import MeowMacCore
import MeowMacUI

enum PanelLayoutCoreTests {
    static func validation() -> Bool {
        let original = PanelLayout.default
        guard (try? original.validated()) == original,
              (try? PanelLayout.parse(try! JSONEncoder().encode(original))) == original else { return false }
        var extreme = original
        extreme.tabs.reverse()
        for tab in [PanelTab.quota, .network] {
            extreme.cards[tab.rawValue] = extreme.placements(for: tab).reversed().map {
                PanelCardPlacement(id: $0.id, visible: false)
            }
        }
        guard (try? extreme.validated()) == extreme,
              (try? PanelLayout.parse(try! JSONEncoder().encode(extreme))) == extreme else { return false }
        extreme.cards["quota"]?[1].visible = true
        guard extreme.visibleIDs(for: .quota) == ["quota.cost"] else { return false }
        var bad = original
        bad.cards["system"]?[0].visible = false
        guard (try? bad.validated()) == nil else { return false }
        bad = original; bad.cards["quota"]?[0].id = "system.chart"
        guard (try? bad.validated()) == nil else { return false }
        bad = original; bad.cards["network"]?.removeLast()
        guard (try? bad.validated()) == nil else { return false }
        bad = original; bad.cards["system"]?[1].id = "system.chart"
        guard (try? bad.validated()) == nil else { return false }
        bad = original; bad.tabs = [.system, .system, .network]
        guard (try? bad.validated()) == nil else { return false }
        let base = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        for change in [("schemaVersion", true as Any), ("schemaVersion", 2 as Any), ("extra", 1 as Any)] {
            var object = base; object[change.0] = change.1
            guard (try? PanelLayout.parse(try! JSONSerialization.data(withJSONObject: object))) == nil else { return false }
        }
        var object = base
        var cards = object["cards"] as! [String: Any]
        var system = cards["system"] as! [[String: Any]]
        system[1]["visible"] = 1
        cards["system"] = system; object["cards"] = cards
        guard (try? PanelLayout.parse(try! JSONSerialization.data(withJSONObject: object))) == nil else { return false }
        system[1]["visible"] = true; system[1]["extra"] = true
        cards["system"] = system; object["cards"] = cards
        return (try? PanelLayout.parse(try! JSONSerialization.data(withJSONObject: object))) == nil
    }

    @MainActor static func packageCompatibility() -> Bool {
        guard let builtin = try? CatPackageLoader.builtin("builtin.slim"),
              builtin.package.panel == .default,
              let source = try? JSONSerialization.jsonObject(with: builtin.files["manifest.json"]!) as? [String: Any] else { return false }
        var v2 = source
        v2["schemaVersion"] = 2
        var panel = PanelLayout.default
        panel.tabs.reverse()
        v2["panel"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(panel))
        guard let data = try? JSONSerialization.data(withJSONObject: v2),
              (try? CatPackage.parse(data, builtin: true))?.panel == panel else { return false }
        let directory = URL(fileURLWithPath: "build/acceptance/v0-2-layout/tests/v2.cat", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, bytes) in builtin.files {
                try (name == "manifest.json" ? data : bytes).write(to: directory.appendingPathComponent(name))
            }
            guard try CatPackageLoader.load(at: directory, builtin: true).package.panel == panel else { return false }
        } catch { print("v2 生产加载器测试失败：\(error)"); return false }
        v2["panel"] = ["schemaVersion": 1]
        guard let invalid = try? JSONSerialization.data(withJSONObject: v2),
              (try? CatPackage.parse(invalid, builtin: true)) == nil else { return false }
        do {
            try invalid.write(to: directory.appendingPathComponent("manifest.json"))
            guard (try? CatPackageLoader.load(at: directory, builtin: true)) == nil else { return false }
            let importRoot = directory.deletingLastPathComponent().appendingPathComponent("v2-import-app", isDirectory: true)
            if FileManager.default.fileExists(atPath: importRoot.path) { try FileManager.default.removeItem(at: importRoot) }
            v2["id"] = "sample-layout"
            let invalidImport = try JSONSerialization.data(withJSONObject: v2)
            try invalidImport.write(to: directory.appendingPathComponent("manifest.json"))
            let state = PanelPreviewRenderer.syntheticState()
            let before = state.selectedCat?.id
            guard (try? CatStore(rootURL: importRoot).importCat(from: directory, state: state)) == nil,
                  state.selectedCat?.id == before,
                  !FileManager.default.fileExists(atPath: importRoot.path),
                  (try? Data(contentsOf: directory.appendingPathComponent("manifest.json"))) == invalidImport else { return false }
        } catch { return false }
        return true
    }
}
