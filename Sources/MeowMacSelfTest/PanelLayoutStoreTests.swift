import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum PanelLayoutStoreTests {
    private static let base = URL(fileURLWithPath: "build/acceptance/v0-2-layout/tests/store", isDirectory: true)
    private static let manager = FileManager.default
    private static let sentinel = Data("合成哨兵".utf8)

    private static func prepare() throws -> (URL, URL) {
        try manager.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: base.path) { try manager.removeItem(at: base) }
        try manager.createDirectory(at: base, withIntermediateDirectories: false)
        let root = base.appendingPathComponent("app", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        try sentinel.write(to: outside.appendingPathComponent("marker"))
        return (root, outside)
    }

    private static func state(root: URL, layoutStore: PanelLayoutStore? = nil) -> (PanelState, CatStore) {
        let state = PanelPreviewRenderer.syntheticState()
        let catStore = CatStore(rootURL: root)
        CatRuntime.initialize(state: state, store: catStore, layoutStore: layoutStore)
        return (state, catStore)
    }

    static func lifecycle() -> Bool {
        do {
            let (root, outside) = try prepare()
            let (panel, cats) = state(root: root)
            guard panel.selectedCat?.id == "builtin.slim", panel.panelLayout == .default,
                  !manager.fileExists(atPath: root.path) else { return false }
            var slim = PanelLayout.default
            slim.tabs.reverse()
            slim.cards["system"]?[1].visible = false
            try panel.saveLayout(slim, for: "builtin.slim")
            guard panel.panelLayout == slim else { return false }
            let slimFile = root.appendingPathComponent("PanelLayouts/builtin.slim.json")
            let original = try Data(contentsOf: slimFile)
            for (index, catID) in ["builtin.round", "builtin.american", "builtin.orange-white"].enumerated() {
                try cats.select(catID, state: panel)
                guard panel.panelLayout == .default else { return false }
                var layout = PanelLayout.default
                layout.tabs = Array(layout.tabs.dropFirst(index % 2 + 1)) + Array(layout.tabs.prefix(index % 2 + 1))
                layout.cards["quota"]?[index].visible = false
                try panel.saveLayout(layout, for: catID)
                guard panel.panelLayout == layout else { return false }
            }
            let (restarted, restoredCats) = state(root: root)
            guard restarted.selectedCat?.id == "builtin.orange-white",
                  restarted.panelLayout == panel.panelLayout else { return false }
            try restoredCats.select("builtin.slim", state: restarted)
            guard restarted.panelLayout == slim && (try? Data(contentsOf: slimFile)) == original else { return false }
            let source = base.appendingPathComponent("custom.cat", isDirectory: true)
            try manager.copyItem(at: URL(fileURLWithPath: "Sources/MeowMacUI/Resources/Cats/builtin.slim.cat", isDirectory: true), to: source)
            let manifest = source.appendingPathComponent("manifest.json")
            var value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            var packaged = PanelLayout.default; packaged.cards["network"]?[2].visible = false
            value["schemaVersion"] = 2; value["id"] = "sample-layout"
            value["panel"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(packaged))
            try JSONSerialization.data(withJSONObject: value).write(to: manifest)
            try restoredCats.importCat(from: source, state: restarted)
            guard restarted.panelLayout == packaged else { return false }
            var local = packaged; local.tabs.reverse()
            try restarted.saveLayout(local, for: "sample-layout")
            let (again, _) = state(root: root)
            return again.selectedCat?.id == "sample-layout" && again.panelLayout == local
                && (try? Data(contentsOf: outside.appendingPathComponent("marker"))) == sentinel
        } catch { print("布局生命周期失败：\(error)"); return false }
    }

    static func recovery() -> Bool {
        do {
            let (root, outside) = try prepare()
            let (panel, cats) = state(root: root)
            try cats.select("builtin.round", state: panel)
            let folder = root.appendingPathComponent("PanelLayouts", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let bad = folder.appendingPathComponent("builtin.round.json")
            let validLayout = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PanelLayout.default))
            func saved(_ version: Int, _ id: String) throws -> Data {
                try JSONSerialization.data(withJSONObject: ["schemaVersion": version, "catID": id, "layout": validLayout])
            }
            for contents in [Data("{broken".utf8),
                             try saved(2, "builtin.round"),
                             try saved(1, "builtin.slim")] {
                try contents.write(to: bad)
                panel.loadLayoutForSelectedCat()
                guard panel.selectedCat?.id == "builtin.round", panel.panelLayout == .default,
                      panel.layoutRecoveryReason != nil, (try Data(contentsOf: bad)) == contents,
                      PanelSnapshot(state: panel).layout.fallback,
                      PanelSnapshot(state: panel).layout.effective == .default else { return false }
                var draft = PanelLayout.default; draft.tabs.reverse()
                guard (try? panel.saveLayout(draft, for: "builtin.round")) == nil,
                      panel.panelLayout == .default, (try Data(contentsOf: bad)) == contents else { return false }
            }
            try cats.select("builtin.slim", state: panel)
            guard panel.layoutRecoveryReason == nil else { return false }
            try manager.removeItem(at: bad)
            let other = outside.appendingPathComponent("marker")
            try manager.createSymbolicLink(at: bad, withDestinationURL: other)
            try cats.select("builtin.round", state: panel)
            var draft = PanelLayout.default; draft.tabs.reverse()
            return panel.layoutRecoveryReason != nil
                && (try? panel.saveLayout(draft, for: "builtin.round")) == nil
                && (try? Data(contentsOf: other)) == sentinel
        } catch { print("布局恢复测试失败：\(error)"); return false }
    }

    static func transactions() -> Bool {
        do {
            let (root, outside) = try prepare()
            let (panel, cats) = state(root: root)
            var old = PanelLayout.default; old.tabs.reverse()
            try panel.saveLayout(old, for: "builtin.slim")
            let file = root.appendingPathComponent("PanelLayouts/builtin.slim.json")
            let oldBytes = try Data(contentsOf: file)
            var next = old; next.cards["network"]?[0].visible = false
            let failedStore = PanelLayoutStore(rootURL: root, beforePublish: { throw PanelLayoutError.invalid("合成发布前失败") })
            panel.layoutStore = failedStore
            guard (try? panel.saveLayout(next, for: "builtin.slim")) == nil,
                  panel.panelLayout == old, (try Data(contentsOf: file)) == oldBytes else { return false }
            let files = try manager.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            guard !files.contains(where: { $0.hasPrefix(".layout-") }) else { return false }
            let failedSelection = CatStore(rootURL: root, beforeSelectionSave: { throw PanelLayoutError.invalid("合成选择保存失败") })
            guard (try? failedSelection.select("builtin.round", state: panel)) == nil,
                  panel.selectedCat?.id == "builtin.slim", panel.panelLayout == old else { return false }
            try cats.select("builtin.round", state: panel)
            guard (try? panel.saveLayout(next, for: "builtin.slim")) == nil,
                  panel.panelLayout == .default else { return false }
            panel.layoutStore = PanelLayoutStore(rootURL: root, directorySync: { _ in -1 })
            try cats.select("builtin.slim", state: panel)
            try panel.saveLayout(next, for: "builtin.slim")
            guard panel.panelLayout == next, (try Data(contentsOf: file)) != oldBytes else { return false }
            let layouts = root.appendingPathComponent("PanelLayouts")
            try manager.removeItem(at: layouts)
            try manager.createSymbolicLink(at: layouts, withDestinationURL: outside)
            guard (try? panel.saveLayout(old, for: "builtin.slim")) == nil,
                  panel.panelLayout == next,
                  (try Data(contentsOf: outside.appendingPathComponent("marker"))) == sentinel else { return false }
            try manager.removeItem(at: root)
            try manager.createSymbolicLink(at: root, withDestinationURL: outside)
            guard (try? panel.saveLayout(old, for: "builtin.slim")) == nil,
                  (try? Data(contentsOf: outside.appendingPathComponent("marker"))) == sentinel else { return false }
            return true
        } catch { print("布局事务测试失败：\(error)"); return false }
    }
}
