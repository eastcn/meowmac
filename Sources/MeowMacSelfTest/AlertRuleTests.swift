import Foundation
import MeowMacCore

enum AlertRuleTests {
    static func decode(_ json: String) throws -> LocalConfig { try JSONDecoder().decode(LocalConfig.self, from: Data(json.utf8)) }
    static func disk(_ config: LocalConfig) -> Double { config.alertRules.effective(.disk, config: config).threshold! }
    static var tests: [(String, () throws -> Bool)] { [
        ("Core.AlertRules/旧字段、新字段与优先级", {
            let old = try decode(#"{"diskRemainingWarn":0.3,"runawayCPU":120}"#)
            let new = try decode(#"{"alertRules":{"builtin":{"system.disk":{"threshold":25}}}}"#)
            let both = try decode(#"{"diskRemainingWarn":0.3,"alertRules":{"builtin":{"system.disk":{"threshold":15}}}}"#)
            return disk(old) == 30 && disk(new) == 25 && disk(both) == 15
                && old.alertRules.effective(.process, config: old).threshold == 120
                && old.alertRules.detectorConfig(old).diskRemainingWarn == 0.3
        }),
        ("Core.AlertRules/越界回退默认，不回退旧值", {
            let c = try decode(#"{"diskRemainingWarn":0.3,"alertRules":{"builtin":{"system.disk":{"threshold":99},"system.memory":{"durationSeconds":-1},"source.failure":{"threshold":2.5}}}}"#)
            return c.alertRules.diagnostics.count == 3 && disk(c) == 10 && c.alertRules.memoryRule(config: c).durationSeconds == 600
                && c.alertRules.effective(.source, config: c).threshold == 2
        }),
        ("Core.AlertRules/未知指标保留，坏单条丢弃", {
            let c = try decode(#"{"alertRules":{"builtin":{"system.disk":"bad"},"custom":[{"id":"u-12345678","name":"未来指标","metric":"future.metric","comparison":"gte","threshold":1},{"id":"bad","name":"坏规则","metric":"cpu.usage","comparison":"gte","threshold":1}]}}"#)
            return c.alertRules.custom.count == 1 && !c.alertRules.custom[0].available && c.alertRules.diagnostics.count == 2
        }),
        ("Core.AlertRules/32 条上限、重复身份与名称校验", {
            let rules = (0..<34).map { AlertRule(id: String(format: "u-%08x", $0), name: "规则", metric: "cpu.usage", threshold: 50) }
            let data = try JSONEncoder().encode(AlertRuleSet(custom: [rules[0]] + rules))
            let set = try JSONDecoder().decode(AlertRuleSet.self, from: data)
            guard set.custom.count == 32, set.diagnostics.count == 3 else { return false }
            for name in ["   ", String(repeating: "字", count: 41)] {
                do { _ = try AlertRule(id: "u-12345678", name: name, metric: "cpu.usage", threshold: 1).validated(); return false } catch {}
            }
            return try AlertRule(id: "u-12345678", name: " 名称 ", metric: "cpu.usage", threshold: 1).validated().name == "名称"
        }),
        ("Core.AlertRules/保存读回、未知字段和恢复默认", {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/alert-rules/tests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("config.json")
            try Data(#"{"diskRemainingWarn":0.3,"other":{"preserve":true},"alertRules":{"future":7,"builtin":{"future.rule":{"threshold":4}}}}"#.utf8).write(to: url)
            var c = ConfigStore.load(from: url).config
            c.alertRules.builtin[BuiltinAlertRule.disk.id] = .init(threshold: 10)
            c.alertRules.custom = [.init(id: "u-12345678", name: "Swap 偏高", metric: "swap.used", threshold: 4)]
            try ConfigStore.saveAlertRules(c.alertRules, changedBuiltin: [.disk], to: url)
            let read = ConfigStore.load(from: url)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            guard read.error == nil, disk(read.config) == 10, read.config.alertRules.custom == c.alertRules.custom,
                  object["diskRemainingWarn"] == nil, object["other"] != nil,
                  (object["alertRules"] as? [String: Any])?["future"] as? Int == 7 else { return false }
            try Data(#"{"diskRemainingWarn":0.3,"runawayCPU":140,"alertRules":{"builtin":{"system.disk":{"threshold":15}}}}"#.utf8).write(to: url)
            c = ConfigStore.load(from: url).config
            try ConfigStore.saveAlertRules(c.alertRules, restoringDefaults: true, to: url)
            let restored = ConfigStore.load(from: url).config
            return disk(restored) == 10 && restored.alertRules.effective(.process, config: restored).threshold == 90
        }),
        ("Core.AlertRules/坏文件不覆盖", {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/alert-rules/bad-" + UUID().uuidString)
            let original = Data("bad json".utf8); try original.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            do { try ConfigStore.saveAlertRules(AlertRuleSet(), to: url); return false } catch {}
            return try Data(contentsOf: url) == original && ConfigStore.load(from: url).error != nil
        }),
        ("Core.AlertRules/坏规则根结构保留原因", {
            let c = try decode(#"{"alertRules":"bad","diskRemainingWarn":0.3}"#)
            return c.alertRules.diagnostics.count == 1 && disk(c) == 30
        }),
        ("Core.AlertRules/14 个指标和 11 条内置规则", {
            AlertMetric.allCases.count == 14 && BuiltinAlertRule.allCases.count == 11
                && AlertMetric.quotaRemaining.sampleSeconds == 1800
                && AlertMetric.memoryPressure.unit == "%"
        })
    ] }
}
