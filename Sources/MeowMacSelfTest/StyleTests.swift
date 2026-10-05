import Foundation
import MeowMacCore
import MeowMacUI

enum StyleTests {
    static func core() -> Bool {
        let standard = StyleSettings.default
        guard standard.quotaBasis == .remaining, standard.email == .full, standard.chartMinutes == 60,
              QuotaProvider.defaults.allSatisfy({ standard.color(for: $0) == .default }),
              EmailDisplay.mask("name@example.com") == "n***@e***",
              EmailDisplay.mask("a@b") == "a***@b***",
              EmailDisplay.mask("plain") == "plain", EmailDisplay.mask("") == "",
              (try? StyleSettings.parse(JSONEncoder().encode(standard))) == standard else { return false }
        let data = try! JSONEncoder().encode(standard)
        var root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        for (key, value) in [("schemaVersion", 2 as Any), ("chartMinutes", true as Any),
                             ("email", "invalid" as Any), ("extra", 1 as Any)] {
            var bad = root; bad[key] = value
            guard let bytes = try? JSONSerialization.data(withJSONObject: bad),
                  (try? StyleSettings.parse(bytes)) == nil else { return false }
        }
        root["colors"] = ["claude": "blue"]
        guard let bytes = try? JSONSerialization.data(withJSONObject: root),
              (try? StyleSettings.parse(bytes)) == nil else { return false }
        func luminance(_ hex: String) -> Double {
            let values = stride(from: 1, through: 5, by: 2).map { index -> Double in
                let start = hex.index(hex.startIndex, offsetBy: index)
                let end = hex.index(start, offsetBy: 2)
                let value = Double(Int(hex[start..<end], radix: 16)!) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return zip(values, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let dark = luminance("#1E1E1E")
        return ThemeColor.allCases.filter { $0 != .default }.allSatisfy { color in
            guard let hex = color.hexPair else { return false }
            return (1.05 / (luminance(hex.light) + 0.05)) >= 3
                && ((luminance(hex.dark) + 0.05) / (dark + 0.05)) >= 3
        }
    }

    static func layout() -> Bool {
        var layout = PanelLayout.default
        guard layout.schemaVersion == 2, layout.overview.order == OverviewItem.allCases,
              layout.overview.hidden.isEmpty, layout.overview.quota.provider == .claude,
              layout.overview.quota.window == "minutes:300" else { return false }
        let object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(layout)) as! [String: Any]
        var legacy = object; legacy["schemaVersion"] = 1; legacy.removeValue(forKey: "overview")
        guard let old = try? PanelLayout.parse(JSONSerialization.data(withJSONObject: legacy)),
              old == .default,
              old.schemaVersion == 2 else { return false }
        layout.overview.order.reverse()
        layout.overview.hidden = [.cpu, .memory]
        layout.overview.quota = OverviewQuota(provider: .codex, window: "auto")
        guard (try? PanelLayout.parse(JSONEncoder().encode(layout))) == layout else { return false }
        for mutation in ["missing", "duplicate", "allHidden", "unknownProvider", "badWindow", "extra"] {
            var bad = object
            var overview = bad["overview"] as! [String: Any]
            switch mutation {
            case "missing": overview["order"] = ["cpu", "memory", "quota"]
            case "duplicate": overview["order"] = ["cpu", "cpu", "quota", "network"]
            case "allHidden": overview["hidden"] = ["cpu", "memory", "quota", "network"]
            case "unknownProvider": overview["quota"] = ["provider": "unknown", "window": "auto"]
            case "badWindow": overview["quota"] = ["provider": "claude", "window": "minutes:0"]
            default: overview["extra"] = true
            }
            bad["overview"] = overview
            guard let data = try? JSONSerialization.data(withJSONObject: bad),
                  (try? PanelLayout.parse(data)) == nil else { return false }
        }
        let first = QuotaWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil, identifier: "first")
        let second = QuotaWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil, identifier: "second")
        let snapshot = QuotaSnapshot(provider: .claude, source: "合成", updatedAt: Date(), windows: [first, second], paceSummary: nil, credits: nil)
        return OverviewQuota.selector(for: first, among: [first, second]) == "id:first"
            && OverviewQuota(window: "id:second").selectedWindow(in: snapshot)?.identifier == "second"
            && OverviewQuota(window: "minutes:300").selectedWindow(in: snapshot) == nil
            && OverviewQuota(window: "auto").selectedWindow(in: snapshot)?.identifier == "first"
    }
}

@MainActor
enum StyleStoreTests {
    private static let base = URL(fileURLWithPath: "build/acceptance/style-tests", isDirectory: true)
    private static let manager = FileManager.default
    private static let sentinel = Data("合成哨兵".utf8)
    static func boundaries() -> Bool {
        guard transactions() else { return false }
        do {
            try manager.createDirectory(at: base, withIntermediateDirectories: true)
            let root = base.appendingPathComponent("app", isDirectory: true)
            let outside = base.appendingPathComponent("outside", isDirectory: true)
            for url in [root, outside] where manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            try manager.createDirectory(at: outside, withIntermediateDirectories: true)
            let marker = outside.appendingPathComponent("marker")
            try sentinel.write(to: marker)
            let store = StyleStore(rootURL: root)
            guard store.load().settings == .default, !manager.fileExists(atPath: root.path) else { return false }
            var style = StyleSettings.default; style.chartMinutes = 15
            try store.save(style)
            let file = root.appendingPathComponent("style.json")
            guard store.load().settings == style else { return false }
            let original = try Data(contentsOf: file)
            let failed = StyleStore(rootURL: root, beforePublish: { throw StyleError.invalid("合成失败") })
            guard (try? failed.save(.default)) == nil, (try Data(contentsOf: file)) == original else { return false }
            for mutation in ["version", "json"] {
                let contents: Data
                if mutation == "version" {
                    var value = try JSONSerialization.jsonObject(with: original) as! [String: Any]
                    value["schemaVersion"] = 2
                    contents = try JSONSerialization.data(withJSONObject: value)
                } else { contents = Data("{".utf8) }
                try contents.write(to: file)
                guard store.load().recoveryReason != nil, (try? store.save(style)) == nil,
                      (try Data(contentsOf: file)) == contents else { return false }
            }
            try original.write(to: file)
            try Data("{".utf8).write(to: file)
            guard store.load().recoveryReason != nil, store.load().settings == .default,
                  (try? store.save(style)) == nil else { return false }
            try Data("{".utf8).write(to: file)
            try manager.removeItem(at: file)
            try manager.createSymbolicLink(at: file, withDestinationURL: marker)
            guard store.load().recoveryReason != nil, (try? store.save(style)) == nil,
                  (try Data(contentsOf: marker)) == sentinel else { return false }
            try manager.removeItem(at: file)
            try Data(repeating: 0, count: 16_385).write(to: file)
            guard store.load().recoveryReason != nil, (try? store.save(style)) == nil else { return false }
            try manager.removeItem(at: root)
            try manager.createSymbolicLink(at: root, withDestinationURL: outside)
            guard store.load().recoveryReason != nil, (try? store.save(style)) == nil,
                  (try Data(contentsOf: marker)) == sentinel else { return false }
            try manager.removeItem(at: root)
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: root.appendingPathComponent("style.json"), withDestinationURL: marker)
            guard (try Data(contentsOf: marker)) == sentinel else { return false }
            try manager.removeItem(at: root)
            let nested = base.appendingPathComponent("nested", isDirectory: true)
            if manager.fileExists(atPath: nested.path) { try manager.removeItem(at: nested) }
            try manager.createDirectory(at: nested, withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: nested.appendingPathComponent("app"), withDestinationURL: outside)
            let nestedStore = StyleStore(rootURL: nested.appendingPathComponent("app"))
            let markerUnchanged = try Data(contentsOf: marker) == sentinel
            return nestedStore.load().recoveryReason != nil && (try? nestedStore.save(style)) == nil
                && markerUnchanged
        } catch { print("样式存储边界失败：\(error)"); return false }
    }
    private static func transactions() -> Bool {
        do {
            let folder = base.appendingPathComponent("transactions", isDirectory: true)
            if manager.fileExists(atPath: folder.path) { try manager.removeItem(at: folder) }
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let root = folder.appendingPathComponent("app", isDirectory: true)
            let outside = folder.appendingPathComponent("outside", isDirectory: true)
            try manager.createDirectory(at: outside, withIntermediateDirectories: true)
            let marker = outside.appendingPathComponent("marker")
            try sentinel.write(to: marker)
            let store = StyleStore(rootURL: root)
            try store.save(.default)
            let file = root.appendingPathComponent("style.json")
            let race = StyleStore(rootURL: root, beforePublish: {
                try manager.removeItem(at: file)
                try manager.createSymbolicLink(at: file, withDestinationURL: marker)
            })
            var changed = StyleSettings.default; changed.chartMinutes = 15
            guard (try? race.save(changed)) == nil, (try Data(contentsOf: marker)) == sentinel,
                  try manager.destinationOfSymbolicLink(atPath: file.path) == marker.path,
                  !(try manager.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".style-") }) else {
                print("发布前符号链接竞态未拒绝"); return false
            }
            try manager.removeItem(at: file)
            try manager.createDirectory(at: file, withIntermediateDirectories: false)
            guard store.load().recoveryReason != nil, (try? store.save(changed)) == nil else { return false }
            try manager.removeItem(at: file)
            try StyleStore(rootURL: root, directorySync: { _ in -1 }).save(changed)
            guard store.load().settings == changed else { return false }
            // 中间父目录为链接时，也不得写到外部目标。
            let link = folder.appendingPathComponent("link")
            try manager.createSymbolicLink(at: link, withDestinationURL: outside)
            let nested = StyleStore(rootURL: link.appendingPathComponent("app"))
            guard nested.load().recoveryReason != nil, (try? nested.save(changed)) == nil,
                  !manager.fileExists(atPath: outside.appendingPathComponent("app").path),
                  (try Data(contentsOf: marker)) == sentinel else { return false }
            let state = PanelPreviewRenderer.syntheticState()
            CatRuntime.initialize(state: state, store: CatStore(rootURL: root))
            let layouts = root.appendingPathComponent("PanelLayouts")
            try manager.createDirectory(at: layouts, withIntermediateDirectories: false)
            let layoutFile = layouts.appendingPathComponent("builtin.slim.json")
            let layoutStore = PanelLayoutStore(rootURL: root, beforePublish: {
                try manager.createSymbolicLink(at: layoutFile, withDestinationURL: marker)
            })
            guard let cat = state.selectedCat, (try? layoutStore.save(.default, cat: cat)) == nil,
                  (try Data(contentsOf: marker)) == sentinel else { return false }
            return !(try manager.contentsOfDirectory(atPath: layouts.path)).contains(where: { $0.hasPrefix(".layout-") })
        } catch { print("样式发布边界失败：\(error)"); return false }
    }

}
