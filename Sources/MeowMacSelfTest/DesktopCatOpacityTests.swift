import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

/// 桌面猫的透明度（D48，plan `2026-10-26-desktop-cat-opacity`）。夹具全部虚构。
@MainActor
enum DesktopCatOpacityTests {
    static var tests: [(String, @MainActor () async -> Bool)] {
        [
            ("Core.DesktopCatOpacity/吸附、夹取与百分比文字", { pure() }),
            ("Core.DesktopCatOpacity/新建：缺省 1.0，第一次保存只新增对应的键", { created() }),
            ("Core.DesktopCatOpacity/编辑：吸附后只改这一个键", { edited() }),
            ("Core.DesktopCatOpacity/停用再启用保留透明度", { toggled() }),
            ("Core.DesktopCatOpacity/删除键回到 1.0 且没有诊断", { deleted() }),
            ("Core.DesktopCatOpacity/恢复默认一次写两个键", { restored() }),
            ("Core.DesktopCatOpacity/坏值按 1.0 读取且不改写文件", { broken() }),
        ]
    }

    /// 带未知字段的虚构配置。
    static let original = #"{"schemaVersion":1,"quotaRemainingWarn":0.15,"futureField":{"nested":[1,"示例"]},"desktopCat":{"enabled":true,"metrics":["example.future","system.cpu"],"placement":{"corner":"topLeft","display":"00000000-0000-0000-0000-00000000D048"},"pet":"example-pet","catHeight":80,"futureKey":"保留"}}"#

    /// 读回后去掉 `keys`，返回顶层其余字段和 `desktopCat` 的其余字段。
    static func split(_ url: URL, removing keys: [String]) -> (top: [String: Any], cat: [String: Any], removed: [String: Any])? {
        guard var top = DesktopCatConfigTests.json(url), var cat = top.removeValue(forKey: "desktopCat") as? [String: Any] else { return nil }
        var removed: [String: Any] = [:]
        for key in keys { removed[key] = cat.removeValue(forKey: key) }
        return (top, cat, removed)
    }

    static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }

    static func pure() -> Bool {
        let resolved = [0.43, 0.12, 1.3, 0.4, 0.2, 1.0, 0.33, 0.98, -1].map(DesktopCatOpacity.resolved)
        guard resolved == [0.45, 0.2, 1.0, 0.4, 0.2, 1.0, 0.35, 1.0, 0.2], DesktopCatOpacity.resolved(.nan) == 1,
              DesktopCatOpacity.resolved(.infinity) == 1 else { print("吸附结果：\(resolved)"); return false }
        guard DesktopCatOpacity.isValid(0.2), DesktopCatOpacity.isValid(1), DesktopCatOpacity.isValid(0.33),
              !DesktopCatOpacity.isValid(0.19), !DesktopCatOpacity.isValid(1.01), !DesktopCatOpacity.isValid(.nan) else { return false }
        let texts = [0.2, 0.33, 0.4, 1.0, 0.6, 0.1, 1.5].map(DesktopCatOpacity.percentText)
        guard texts == ["20%", "35%", "40%", "100%", "60%", "100%", "100%"] else { print("百分比文字：\(texts)"); return false }
        return DesktopCatOpacity.sliderValue(0.33) == 0.35 && DesktopCatOpacity.rendered(0.33) == 0.33 && DesktopCatOpacity.rendered(5) == 1
    }

    static func created() -> Bool {
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            // 缺省都是 1.0，没有诊断。
            guard DesktopCatConfig().catOpacity == 1, DesktopCatConfig().bubbleOpacity == 1 else { return false }
            try Data(original.utf8).write(to: url)
            let loaded = ConfigStore.load(from: url).config.desktopCat
            // 夹具里的未知指标会记一条诊断；不透明度不产生诊断。
            guard loaded.catOpacity == 1, loaded.bubbleOpacity == 1, !loaded.diagnostics.contains(where: { $0.contains("不透明度") }),
                  loaded.catHeight == 80 else { return false }
            guard let before = split(url, removing: []) else { return false }
            // 第一次保存猫的不透明度：只新增 catOpacity，其他字段（含未知字段）的值不变。
            try ConfigStore.saveDesktopCatOpacity([.cat: 0.6], fallback: loaded, to: url)
            guard let after = split(url, removing: ["catOpacity"]), after.removed["catOpacity"] as? Double == 0.6,
                  after.cat["bubbleOpacity"] == nil, same(before.top, after.top), same(before.cat, after.cat) else { return false }
            let reloaded = ConfigStore.load(from: url).config.desktopCat
            guard reloaded.catOpacity == 0.6, reloaded.bubbleOpacity == 1, !reloaded.diagnostics.contains(where: { $0.contains("不透明度") }) else { return false }
            // 文件里没有 desktopCat 时整组写入界面正在用的配置。
            try Data(#"{"schemaVersion":1}"#.utf8).write(to: url)
            try ConfigStore.saveDesktopCatOpacity([.bubble: 0.5], fallback: DesktopCatConfig(enabled: true), to: url)
            let whole = ConfigStore.load(from: url).config.desktopCat
            guard whole.enabled, whole.bubbleOpacity == 0.5, whole.catOpacity == 1, whole.diagnostics.isEmpty else { return false }
            // desktopCat 不是对象时同样整组写入。
            try Data(#"{"schemaVersion":1,"desktopCat":[1]}"#.utf8).write(to: url)
            try ConfigStore.saveDesktopCatOpacity([.cat: 0.3], fallback: DesktopCatConfig(enabled: true), to: url)
            let repaired = ConfigStore.load(from: url).config.desktopCat
            return repaired.enabled && repaired.catOpacity == 0.3 && repaired.bubbleOpacity == 1 && repaired.diagnostics.isEmpty
        } catch { print("桌面猫透明度新建用例失败：\(error)"); return false }
    }

    static func edited() -> Bool {
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Data(original.utf8).write(to: url)
            let loaded = ConfigStore.load(from: url).config.desktopCat
            try ConfigStore.saveDesktopCatOpacity([.bubble: 0.4], fallback: loaded, to: url)
            guard let before = split(url, removing: ["bubbleOpacity"]), before.removed["bubbleOpacity"] as? Double == 0.4,
                  ConfigStore.load(from: url).config.desktopCat.bubbleOpacity == 0.4 else { return false }
            // 吸附再夹取：0.43 → 0.45，0.12 → 0.2，1.3 → 1.0。每次只改这一个键。
            for (input, expected) in [(0.43, 0.45), (0.12, 0.2), (1.3, 1.0)] {
                try ConfigStore.saveDesktopCatOpacity([.bubble: input], fallback: loaded, to: url)
                guard let after = split(url, removing: ["bubbleOpacity"]), after.removed["bubbleOpacity"] as? Double == expected,
                      same(before.top, after.top), same(before.cat, after.cat),
                      ConfigStore.load(from: url).config.desktopCat.bubbleOpacity == expected else { print("写入 \(input) 未得到 \(expected)"); return false }
            }
            // 整个文件无效时拒绝，不覆盖。
            try Data("{broken".utf8).write(to: url)
            guard (try? ConfigStore.saveDesktopCatOpacity([.cat: 0.5], fallback: loaded, to: url)) == nil,
                  (try? Data(contentsOf: url)) == Data("{broken".utf8) else { return false }
            // 整组校验：越界的值拒绝。
            return (try? DesktopCatConfig().with(catOpacity: 0.1).validated()) == nil
                && (try? DesktopCatConfig().with(bubbleOpacity: .nan).validated()) == nil
                && (try? DesktopCatConfig().with(bubbleOpacity: 0.33).validated()) != nil
        } catch { print("桌面猫透明度编辑用例失败：\(error)"); return false }
    }

    static func toggled() -> Bool {
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Data(original.utf8).write(to: url)
            try ConfigStore.saveDesktopCatOpacity([.cat: 0.4, .bubble: 0.6], fallback: ConfigStore.load(from: url).config.desktopCat, to: url)
            // 开关走整组保存：关掉再打开，两个透明度不变。
            try ConfigStore.saveDesktopCat(ConfigStore.load(from: url).config.desktopCat.with(enabled: false), to: url)
            let off = ConfigStore.load(from: url).config.desktopCat
            guard !off.enabled, off.catOpacity == 0.4, off.bubbleOpacity == 0.6 else { return false }
            try ConfigStore.saveDesktopCat(off.with(enabled: true), to: url)
            let on = ConfigStore.load(from: url).config.desktopCat
            return on.enabled && on.catOpacity == 0.4 && on.bubbleOpacity == 0.6 && on.diagnostics.isEmpty
        } catch { print("桌面猫透明度停用用例失败：\(error)"); return false }
    }

    static func deleted() -> Bool {
        let base = #"{"schemaVersion":1,"desktopCat":{"enabled":true,"catOpacity":0.4,"bubbleOpacity":0.6}}"#
        guard DesktopCatConfigTests.load(base, check: { config, _, _ in config.catOpacity == 0.4 && config.bubbleOpacity == 0.6 }) else { return false }
        // 手动删掉键：回到 1.0，不产生诊断。
        return DesktopCatConfigTests.load(#"{"schemaVersion":1,"desktopCat":{"enabled":true,"bubbleOpacity":0.6}}"#) { config, _, _ in
            config.catOpacity == 1 && config.bubbleOpacity == 0.6 && config.diagnostics.isEmpty
        } && DesktopCatConfigTests.load(#"{"schemaVersion":1,"desktopCat":{"enabled":true}}"#) { config, _, _ in
            config.catOpacity == 1 && config.bubbleOpacity == 1 && config.diagnostics.isEmpty
        }
    }

    static func restored() -> Bool {
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Data(original.utf8).write(to: url)
            try ConfigStore.saveDesktopCatOpacity([.cat: 0.4, .bubble: 0.6], fallback: ConfigStore.load(from: url).config.desktopCat, to: url)
            guard let before = split(url, removing: ["catOpacity", "bubbleOpacity"]) else { return false }
            // 恢复默认：一次调用（一次写盘）把两个键都写成 1.0，其他字段不变。
            try ConfigStore.saveDesktopCatOpacity([.cat: 1, .bubble: 1], fallback: ConfigStore.load(from: url).config.desktopCat, to: url)
            guard let after = split(url, removing: ["catOpacity", "bubbleOpacity"]), after.removed["catOpacity"] as? Double == 1,
                  after.removed["bubbleOpacity"] as? Double == 1, same(before.top, after.top), same(before.cat, after.cat) else { return false }
            let config = ConfigStore.load(from: url).config.desktopCat
            return config.catOpacity == 1 && config.bubbleOpacity == 1 && config.catHeight == 80 && config.pet == "example-pet"
        } catch { print("桌面猫透明度恢复默认用例失败：\(error)"); return false }
    }

    static func broken() -> Bool {
        let base = #"{"schemaVersion":1,"quotaRemainingWarn":0.15,"desktopCat":{"enabled":true,"metrics":["system.power","system.cpu"],"placement":{"corner":"topLeft"},"catHeight":80,"#
        let bad = [#""abc""#, "null", "-0.5", "0.1", "1.5", "[0.5]"]
        for (index, value) in bad.enumerated() {
            for part in DesktopCatOpacityPart.allCases {
                let text = base + "\"\(part.rawValue)\":\(value)}}"
                let note = part == .cat ? "桌面猫的猫不透明度无效，已按 100% 显示" : "桌面猫的气泡不透明度无效，已按 100% 显示"
                // `load` 断言读取不改写文件；其他字段照常读取，诊断不含路径。
                let ok = DesktopCatConfigTests.load(text) { config, _, url in
                    config.catOpacity == 1 && config.bubbleOpacity == 1 && config.diagnostics == [note]
                        && !config.diagnostics.contains { $0.contains(url.path) || $0.contains("/") }
                        && config.enabled && config.metrics == ["system.power", "system.cpu"] && config.placement.corner == .topLeft && config.catHeight == 80
                }
                guard ok else { print("桌面猫透明度坏值第 \(index + 1) 例（\(part.rawValue)）未通过"); return false }
            }
        }
        // 两项都坏：各记一条。合法但不在 5% 步长上的值原样读取。
        return DesktopCatConfigTests.load(base + #""catOpacity":"x","bubbleOpacity":9}}"#) { config, _, _ in
            config.catOpacity == 1 && config.bubbleOpacity == 1 && config.diagnostics.count == 2
        } && DesktopCatConfigTests.load(base + #""catOpacity":0.33,"bubbleOpacity":0.2}}"#) { config, _, _ in
            config.catOpacity == 0.33 && config.bubbleOpacity == 0.2 && config.diagnostics.isEmpty
        }
    }
}
