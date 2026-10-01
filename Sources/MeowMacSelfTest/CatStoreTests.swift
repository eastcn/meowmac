import AppKit
import Darwin
import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum CatStoreTests {
    private static let base = URL(fileURLWithPath: "build/acceptance/cat-tests/store", isDirectory: true)
    private static let manager = FileManager.default
    private static let sentinel = Data("合成哨兵".utf8)

    private static func prepare() throws -> (URL, URL, URL) {
        try manager.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: base.path) { try manager.removeItem(at: base) }
        try manager.createDirectory(at: base, withIntermediateDirectories: false)
        let source = base.appendingPathComponent("source.cat", isDirectory: true)
        let original = URL(fileURLWithPath: "Sources/MeowMacUI/Resources/Cats/builtin.slim.cat", isDirectory: true)
        try manager.copyItem(at: original, to: source)
        let manifest = source.appendingPathComponent("manifest.json")
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        value["id"] = "sample-cat"; value["name"] = "示例猫"
        try JSONSerialization.data(withJSONObject: value).write(to: manifest)
        let root = base.appendingPathComponent("app", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        try sentinel.write(to: outside.appendingPathComponent("marker"))
        return (source, root, outside)
    }

    private static func unchanged(_ outside: URL) -> Bool {
        (try? Data(contentsOf: outside.appendingPathComponent("marker"))) == sentinel
    }

    static func lifecycle() -> Bool {
        do {
            let (source, root, outside) = try prepare()
            let state = PanelPreviewRenderer.syntheticState()
            let store = CatStore(rootURL: root)
            guard store.loadSelection()?.id == "builtin.slim", !manager.fileExists(atPath: root.path) else { return false }
            let imported = try store.importCat(from: source, state: state)
            guard imported.id == "sample-cat", state.selectedCat?.id == "sample-cat",
                  manager.fileExists(atPath: root.appendingPathComponent("Cats/sample-cat.cat/manifest.json").path),
                  store.importedCats().map(\.id) == ["sample-cat"] else { return false }
            try manager.removeItem(at: source)
            guard CatStore(rootURL: root).loadSelection()?.id == "sample-cat" else { return false }
            try store.select("builtin.round", state: state)
            guard state.selectedCat?.id == "builtin.round",
                  CatStore(rootURL: root).loadSelection()?.id == "builtin.round" else { return false }
            try store.select("sample-cat", state: state)
            try store.select("builtin.round", state: state)
            let selection = root.appendingPathComponent("cat-selection.json")
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: selection)) as! [String: Any]
            return Set(object.keys) == ["schemaVersion", "selectedID"] &&
                object["selectedID"] as? String == "builtin.round" && unchanged(outside)
        } catch { print("猫配置生命周期失败：\(error)"); return false }
    }

    static func recovery() -> Bool {
        do {
            let (source, root, outside) = try prepare()
            let state = PanelPreviewRenderer.syntheticState()
            let store = CatStore(rootURL: root)
            try store.importCat(from: source, state: state)
            let selection = root.appendingPathComponent("cat-selection.json")
            try Data("broken".utf8).write(to: selection)
            let invalid = CatStore(rootURL: root)
            guard invalid.loadSelection()?.id == "builtin.slim", invalid.recoveryReason != nil,
                  (try? Data(contentsOf: selection)) == Data("broken".utf8) else { return false }
            try Data(#"{"schemaVersion":2,"selectedID":"sample-cat"}"#.utf8).write(to: selection)
            guard CatStore(rootURL: root).loadSelection()?.id == "builtin.slim" else { return false }
            try Data(#"{"schemaVersion":1,"selectedID":"sample-cat"}"#.utf8).write(to: selection)
            try manager.removeItem(at: root.appendingPathComponent("Cats/sample-cat.cat/run.png"))
            let missing = CatStore(rootURL: root)
            guard missing.loadSelection()?.id == "builtin.slim", missing.recoveryReason != nil,
                  (try? Data(contentsOf: selection)) == Data(#"{"schemaVersion":1,"selectedID":"sample-cat"}"#.utf8) else { return false }
            return unchanged(outside)
        } catch { print("猫配置恢复失败：\(error)"); return false }
    }

    static func links() -> Bool {
        do {
            let (source, root, outside) = try prepare()
            let state = PanelPreviewRenderer.syntheticState()
            try manager.createSymbolicLink(at: root, withDestinationURL: outside)
            guard (try? CatStore(rootURL: root).importCat(from: source, state: state)) == nil,
                  unchanged(outside) else { return false }
            try manager.removeItem(at: root)
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            let cats = root.appendingPathComponent("Cats")
            try manager.createSymbolicLink(at: cats, withDestinationURL: outside)
            guard (try? CatStore(rootURL: root).importCat(from: source, state: state)) == nil,
                  (try? CatStore(rootURL: root).select("builtin.round", state: state)) == nil,
                  unchanged(outside) else { return false }
            try manager.removeItem(at: cats)
            try manager.createDirectory(at: cats, withIntermediateDirectories: false)
            let selection = root.appendingPathComponent("cat-selection.json")
            try manager.createSymbolicLink(at: selection, withDestinationURL: outside.appendingPathComponent("marker"))
            guard (try? CatStore(rootURL: root).select("builtin.round", state: state)) == nil,
                  unchanged(outside) else { return false }
            try manager.removeItem(at: selection)
            let temp = cats.appendingPathComponent(".import-fixed")
            try manager.createSymbolicLink(at: temp, withDestinationURL: outside)
            guard (try? CatStore(rootURL: root, temporaryName: { ".import-fixed" }).importCat(from: source, state: state)) == nil,
                  manager.fileExists(atPath: temp.path), unchanged(outside) else { return false }
            return true
        } catch { print("目标符号链接测试失败：\(error)"); return false }
    }

    static func transactions() -> Bool {
        do {
            let (source, root, outside) = try prepare()
            let state = PanelPreviewRenderer.syntheticState()
            let store = CatStore(rootURL: root)
            try store.select("builtin.round", state: state)
            let before = try Data(contentsOf: root.appendingPathComponent("cat-selection.json"))
            let failing = CatStore(rootURL: root, temporaryName: { ".import-failed" },
                beforeSelectionSave: { throw CatPackageError.invalid("注入选择写入失败") })
            var importMessage = ""
            do { try failing.importCat(from: source, state: state) }
            catch { importMessage = error.localizedDescription }
            guard importMessage.contains("已导入，切换未保存"),
                  state.selectedCat?.id == "builtin.round",
                  (try? Data(contentsOf: root.appendingPathComponent("cat-selection.json"))) == before,
                  manager.fileExists(atPath: root.appendingPathComponent("Cats/sample-cat.cat/manifest.json").path),
                  !manager.fileExists(atPath: root.appendingPathComponent("Cats/.import-failed").path) else { return false }
            guard (try? failing.select("sample-cat", state: state)) == nil,
                  state.selectedCat?.id == "builtin.round" else { return false }
            guard (try? store.importCat(from: source, state: state)) == nil,
                  state.selectedCat?.id == "builtin.round" else { return false }
            let duplicate = root.appendingPathComponent("Cats/sample-cat.cat")
            try manager.removeItem(at: duplicate)
            let race = CatStore(rootURL: root, temporaryName: { ".import-race" }, beforePublish: {
                try Data("竞争目标".utf8).write(to: duplicate)
            })
            guard (try? race.importCat(from: source, state: state)) == nil,
                  (try? Data(contentsOf: duplicate)) == Data("竞争目标".utf8),
                  !manager.fileExists(atPath: root.appendingPathComponent("Cats/.import-race").path) else { return false }
            try manager.removeItem(at: duplicate)
            let raceDirectory = CatStore(rootURL: root, temporaryName: { ".import-race-directory" }, beforePublish: {
                try manager.createDirectory(at: duplicate, withIntermediateDirectories: false)
            })
            guard (try? raceDirectory.importCat(from: source, state: state)) == nil,
                  (try? manager.attributesOfItem(atPath: duplicate.path)[.type] as? FileAttributeType) == .typeDirectory,
                  !manager.fileExists(atPath: root.appendingPathComponent("Cats/.import-race-directory").path) else { return false }
            try manager.removeItem(at: duplicate)
            let raceLink = CatStore(rootURL: root, temporaryName: { ".import-race-link" }, beforePublish: {
                try manager.createSymbolicLink(at: duplicate, withDestinationURL: outside)
            })
            guard (try? raceLink.importCat(from: source, state: state)) == nil,
                  (try? manager.destinationOfSymbolicLink(atPath: duplicate.path)) == outside.path,
                  !manager.fileExists(atPath: root.appendingPathComponent("Cats/.import-race-link").path) else { return false }
            try manager.removeItem(at: duplicate)
            let unsupported = CatStore(rootURL: root, temporaryName: { ".import-unsupported" },
                publish: { _, _, _, _ in errno = ENOTSUP; return -1 })
            guard (try? unsupported.importCat(from: source, state: state)) == nil,
                  !manager.fileExists(atPath: duplicate.path),
                  !manager.fileExists(atPath: root.appendingPathComponent("Cats/.import-unsupported").path),
                  (try? Data(contentsOf: root.appendingPathComponent("cat-selection.json"))) == before,
                  unchanged(outside) else { return false }
            let manifest = source.appendingPathComponent("manifest.json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            object["id"] = "builtin.fake"
            try JSONSerialization.data(withJSONObject: object).write(to: manifest)
            guard (try? store.importCat(from: source, state: state)) == nil,
                  !manager.fileExists(atPath: root.appendingPathComponent("Cats/builtin.fake.cat").path),
                  state.selectedCat?.id == "builtin.round" else { return false }
            return true
        } catch { print("导入事务测试失败：\(error)"); return false }
    }
}
