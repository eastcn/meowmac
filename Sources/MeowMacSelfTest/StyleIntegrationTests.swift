import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum StyleIntegrationTests {
    static func lifecycle() -> Bool {
        let base = URL(fileURLWithPath: "build/acceptance/style-tests/integration", isDirectory: true)
        let root = base.appendingPathComponent("app", isDirectory: true)
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: base.path) { try manager.removeItem(at: base) }
            try manager.createDirectory(at: base, withIntermediateDirectories: true)
            var style = StyleSettings.default
            style.quotaBasis = .used; style.email = .hidden; style.chartMinutes = 15; style.colors["codex"] = .green
            try StyleStore(rootURL: root).save(style)
            let cats = CatStore(rootURL: root)
            let state = PanelPreviewRenderer.syntheticState()
            CatRuntime.initialize(state: state, store: cats, environment: [:])
            guard state.style == style, state.chartMinutes == 15 else { return false }
            var slim = PanelLayout.default
            slim.overview.hidden = [.cpu]; slim.overview.quota = OverviewQuota(provider: .codex, window: "auto")
            try state.saveLayout(slim, for: "builtin.slim")
            let bytes = try Data(contentsOf: root.appendingPathComponent("style.json"))
            try cats.select("builtin.round", state: state)
            guard state.panelLayout.overview == .default, state.style == style else { return false }
            try cats.select("builtin.slim", state: state)
            guard state.panelLayout == slim, state.style == style,
                  PanelSnapshot(state: state).overview.metrics.first(where: { $0.item == .quota })?.value == "40%",
                  PanelSnapshot(state: state).quota.first(where: { $0.provider == .codex })?.accountEmail != nil else { return false }
            let restarted = PanelPreviewRenderer.syntheticState()
            CatRuntime.initialize(state: restarted, store: CatStore(rootURL: root), environment: [:])
            guard restarted.style == style, restarted.panelLayout == slim else { return false }
            let source = base.appendingPathComponent("sample.cat", isDirectory: true)
            try manager.copyItem(at: URL(fileURLWithPath: "Sources/MeowMacUI/Resources/Cats/builtin.slim.cat"), to: source)
            let manifest = source.appendingPathComponent("manifest.json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            var packaged = PanelLayout.default
            packaged.overview.order.reverse(); packaged.overview.hidden = [.memory]
            packaged.overview.quota = OverviewQuota(provider: .codex, window: "id:synthetic-window")
            object["schemaVersion"] = 2; object["id"] = "style-sample"
            object["panel"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(packaged))
            try JSONSerialization.data(withJSONObject: object).write(to: manifest)
            try cats.importCat(from: source, state: state)
            guard state.panelLayout == packaged, state.style == style else { return false }
            let layoutFile = root.appendingPathComponent("PanelLayouts/style-sample.json")
            try Data("{".utf8).write(to: layoutFile)
            let styleFile = root.appendingPathComponent("style.json")
            guard (try Data(contentsOf: styleFile)) == bytes else { return false }
            try Data("{".utf8).write(to: styleFile)
            let recovered = PanelPreviewRenderer.syntheticState()
            CatRuntime.initialize(state: recovered, store: CatStore(rootURL: root), environment: [:])
            guard recovered.panelLayout == packaged, recovered.style == .default,
                  recovered.layoutRecoveryReason != nil, recovered.styleRecoveryReason != nil,
                  (try Data(contentsOf: styleFile)) == Data("{".utf8),
                  (try Data(contentsOf: layoutFile)) == Data("{".utf8) else { return false }
            // 旧本机 v1 文件读取时不改写，显式保存才升级内层布局。
            let legacyFile = root.appendingPathComponent("PanelLayouts/builtin.slim.json")
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(slim)) as! [String: Any]
            legacy["schemaVersion"] = 1; legacy.removeValue(forKey: "overview")
            let oldBytes = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "catID": "builtin.slim", "layout": legacy])
            try oldBytes.write(to: legacyFile)
            try cats.select("builtin.slim", state: state)
            guard state.panelLayout.overview == .default, (try Data(contentsOf: legacyFile)) == oldBytes else { return false }
            try state.saveLayout(state.panelLayout, for: "builtin.slim")
            let upgraded = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as! [String: Any]
            return (upgraded["layout"] as? [String: Any])?["schemaVersion"] as? Int == 2
        } catch { print("样式集成失败：\(error)"); return false }
    }
}
