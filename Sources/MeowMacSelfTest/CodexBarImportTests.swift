import Foundation
import MeowMacCore
import MeowMacQuota
import MeowMacUI

@MainActor
enum CodexBarImportTests {
    static let tests: [(String, @MainActor () -> Bool)] = [
        ("Core.History/导入补缺口边界与保留期", gapBoundary),
        ("Core.History/导入账号选择与坏条目", accountsAndBadEntries),
        ("Core.History/导入版本与重复条目", versionAndDuplicates),
        ("Core.History/导入写入保留原字节并只执行一次", writeOnce),
        ("Core.History/导入失败回滚与符号链接", failureAndSymlinks),
        ("Core.History/导入标记写入失败与版本不支持重试", markerFailureAndUnsupported),
        ("UI.Quota/导入提示与趋势数据刷新", coordinatorAndMessages),
        ("Core.History.Live/真实文件只读干跑", liveDryRun),
    ]

    private static let base = URL(fileURLWithPath: "build/acceptance/history-import/tests", isDirectory: true)
    private static let now = date("2030-04-10T12:00:00Z")

    private static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private static func entry(_ captured: String, _ percent: Int = 10) -> String {
        #"{"capturedAt":"\#(captured)","resetsAt":"2030-04-10T18:00:00Z","usedPercent":\#(percent)}"#
    }
    private static func series(_ name: String, _ minutes: Int, _ entries: [String]) -> String {
        #"{"name":"\#(name)","windowMinutes":\#(minutes),"entries":[\#(entries.joined(separator: ","))]}"#
    }
    private static func source(version: Int = 1, preferred: String? = nil, accounts: [String: [String]] = [:], unscoped: [String] = []) -> Data {
        let acc = accounts.map { #""\#($0.key)":[\#($0.value.joined(separator: ","))]"# }.joined(separator: ",")
        let pref = preferred.map { #""preferredAccountKey":"\#($0)","# } ?? ""
        return Data(#"{"version":\#(version),\#(pref)"accounts":{\#(acc)},"unscoped":[\#(unscoped.joined(separator: ","))]}"#.utf8)
    }
    private static func line(_ time: String, provider: QuotaProvider = .claude) -> QuotaHistoryLine {
        QuotaHistoryLine(sampledAt: date(time), provider: provider, windowMinutes: 300, usedPercent: 50, resetsAt: nil)
    }
    private static func fresh(_ name: String) throws -> URL {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func gapBoundary() -> Bool {
        let data = source(unscoped: [series("session", 300, [entry("2030-04-01T00:00:00Z"), entry("2030-04-05T00:00:00Z"),
                                                              entry("2030-04-05T00:00:01Z"), entry("2030-01-01T00:00:00Z")])])
        let existing = [line("2030-04-05T00:00:00Z"), line("2030-04-09T00:00:00Z")]
        let notBefore = now.addingTimeInterval(-90 * 86400)
        guard let partial = try? CodexBarHistoryImporter.parse(data, provider: .claude, existing: existing, notBefore: notBefore),
              let empty = try? CodexBarHistoryImporter.parse(data, provider: .claude, existing: [], notBefore: notBefore) else { return false }
        // 等于最早时间的条目属于重叠，不导入；早于保留期的不导入。
        return partial.rows.map(\.sampledAt) == [date("2030-04-01T00:00:00Z")]
            && partial.overlapEntries == 2 && partial.expiredEntries == 1
            && empty.rows.count == 3 && empty.expiredEntries == 1 && empty.overlapEntries == 0
            && empty.rows.map(\.windowMinutes) == [300, 300, 300]
            && zip(empty.rows, empty.rows.dropFirst()).allSatisfy { $0.sampledAt <= $1.sampledAt }
    }

    private static func accountsAndBadEntries() -> Bool {
        let bad = [
            #"{"resetsAt":"2030-04-10T18:00:00Z","usedPercent":10}"#,
            #"{"capturedAt":"not-a-date","usedPercent":10}"#,
            #"{"capturedAt":"2030-04-02T00:00:00Z","usedPercent":101}"#,
            #"{"capturedAt":"2030-04-02T00:00:00Z","usedPercent":-1}"#,
            #"{"capturedAt":"2030-04-02T00:00:00Z","resetsAt":"oops","usedPercent":5}"#,
        ]
        let data = source(preferred: "acct-a",
                          accounts: ["acct-a": [series("session", 300, [entry("2030-04-01T00:00:00Z"), bad[0], bad[1], bad[2], bad[3], bad[4]])],
                                     "acct-b": [series("weekly", 10080, [entry("2030-04-01T01:00:00Z")]), series("session", 300, [entry("2030-04-01T02:00:00Z")])]],
                          unscoped: [series("weekly", 10080, [entry("2030-04-01T03:00:00Z")]),
                                     #"{"name":"mystery","entries":[\#(entry("2030-04-01T04:00:00Z"))]}"#,
                                     #"{"name":"weekly","entries":[\#(entry("2030-04-01T05:00:00Z"))]}"#])
        let noPreferred = source(accounts: ["acct-a": [series("session", 300, [entry("2030-04-01T00:00:00Z")])]])
        let fractional = source(unscoped: [series("session", 300, [#"{"capturedAt":"2030-04-01T00:00:00.500Z","usedPercent":3.5}"#])])
        let notBefore = now.addingTimeInterval(-90 * 86400)
        guard let result = try? CodexBarHistoryImporter.parse(data, provider: .codex, existing: [], notBefore: notBefore),
              let none = try? CodexBarHistoryImporter.parse(noPreferred, provider: .codex, existing: [], notBefore: notBefore),
              let frac = try? CodexBarHistoryImporter.parse(fractional, provider: .codex, existing: [], notBefore: notBefore) else { return false }
        // 首选账号 1 条有效 + unscoped 的 weekly 与按名称推断窗口的 weekly；无窗口且名称未知的曲线整条算坏条目。
        return result.rows.count == 3 && result.badEntries == 6
            && result.skippedAccountSeries == 2
            && Set(result.rows.compactMap(\.windowMinutes)) == [300, 10080]
            && result.rows.allSatisfy { $0.provider == .codex && $0.windowID == nil }
            && none.rows.isEmpty && none.skippedAccountSeries == 1
            && frac.rows.count == 1 && frac.rows[0].usedPercent == 3.5 && frac.rows[0].resetsAt == nil
    }

    private static func versionAndDuplicates() -> Bool {
        let notBefore = now.addingTimeInterval(-90 * 86400)
        var versionError: CodexBarImportError?
        do { _ = try CodexBarHistoryImporter.parse(source(version: 2), provider: .claude, existing: [], notBefore: notBefore) }
        catch { versionError = error as? CodexBarImportError }
        var unreadable: CodexBarImportError?
        do { _ = try CodexBarHistoryImporter.parse(Data("[]".utf8), provider: .claude, existing: [], notBefore: notBefore) }
        catch { unreadable = error as? CodexBarImportError }
        let dup = source(unscoped: [series("session", 300, [entry("2030-04-01T00:00:00Z"), entry("2030-04-01T00:00:00Z", 20)]),
                                    series("weekly", 10080, [entry("2030-04-01T00:00:00Z")])])
        guard let parsed = try? CodexBarHistoryImporter.parse(dup, provider: .claude, existing: [], notBefore: notBefore) else { return false }
        return versionError == .unsupportedVersion(2) && unreadable == .unreadable
            && parsed.rows.count == 2 && parsed.duplicateEntries == 1 && parsed.rows[0].usedPercent == 10
    }

    private static func prepare(_ name: String, existing: String? = nil) throws -> (CodexBarHistoryImport, URL, URL) {
        let root = try fresh(name)
        let src = root.appendingPathComponent("codexbar", isDirectory: true)
        let history = root.appendingPathComponent("history/quota", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try source(unscoped: [series("session", 300, [entry("2030-04-01T00:00:00Z"), entry("2030-04-02T00:00:00Z")])]).write(to: src.appendingPathComponent("claude.json"))
        try source(unscoped: [series("weekly", 10080, [entry("2030-04-03T00:00:00Z")])]).write(to: src.appendingPathComponent("codex.json"))
        if let existing {
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try Data(existing.utf8).write(to: history.appendingPathComponent("claude.jsonl"))
        }
        return (CodexBarHistoryImport(source: src, store: QuotaHistoryStore(directory: history)), src, history)
    }

    private static func writeOnce() -> Bool {
        do {
            let original = #"{"sampledAt":"2030-04-05T00:00:00Z","provider":"claude","windowMinutes":300,"usedPercent":50}"# + "\n{broken}\n"
            let (importer, _, history) = try prepare("write-once", existing: original)
            let first = try importer.run(now: now, retentionDays: 90)
            let claudeURL = history.appendingPathComponent("claude.jsonl")
            let afterFirst = try Data(contentsOf: claudeURL)
            let store = QuotaHistoryStore(directory: history)
            let claudeRows = try store.read(.claude), codexRows = try store.read(.codex)
            let second = try importer.run(now: now, retentionDays: 90)
            let afterSecond = try Data(contentsOf: claudeURL)
            let text = String(decoding: afterFirst, as: UTF8.self)
            let (empty, _, _) = try prepare("write-once-missing")
            let missing = CodexBarHistoryImport(source: base.appendingPathComponent("write-once-missing/nope"), store: empty.store)
            let absent = try missing.run(now: now, retentionDays: 90)
            return first.outcome == .imported && first.imported[.claude] == 2 && first.imported[.codex] == 1 && first.totalImported == 3
                && text.hasSuffix(original) && claudeRows.count == 3 && claudeRows.map(\.sampledAt) == claudeRows.map(\.sampledAt).sorted()
                && codexRows.count == 1 && codexRows[0].windowMinutes == 10080
                && FileManager.default.fileExists(atPath: importer.marker.path)
                && second.outcome == .alreadyImported && afterSecond == afterFirst
                && absent.outcome == .sourceMissing && !FileManager.default.fileExists(atPath: missing.marker.path)
        } catch { print("导入写入夹具失败：\(error)"); return false }
    }

    private static func failureAndSymlinks() -> Bool {
        do {
            let original = #"{"sampledAt":"2030-04-05T00:00:00Z","provider":"claude","windowMinutes":300,"usedPercent":50}"# + "\n"
            let (base, src, history) = try prepare("failure", existing: original)
            let claudeURL = history.appendingPathComponent("claude.jsonl")
            let codexURL = history.appendingPathComponent("codex.jsonl")
            var calls = 0
            // 第二个文件写入失败：第一个文件回到原字节，第二个文件不存在，标记不存在。
            let failing = CodexBarHistoryImport(source: src, store: base.store, write: { data, url in
                calls += 1
                if calls == 2 { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            var failed = false
            do { _ = try failing.run(now: now, retentionDays: 90) } catch is CodexBarImportFailure { failed = true }
            let rolledBack = try Data(contentsOf: claudeURL) == Data(original.utf8)
                && !FileManager.default.fileExists(atPath: codexURL.path)
                && !FileManager.default.fileExists(atPath: failing.marker.path)
            let retry = try base.run(now: now, retentionDays: 90)

            let (linked, _, linkedHistory) = try prepare("symlink-file", existing: original)
            let sentinel = linkedHistory.deletingLastPathComponent().appendingPathComponent("sentinel.jsonl")
            try Data("keep\n".utf8).write(to: sentinel)
            let target = linkedHistory.appendingPathComponent("codex.jsonl")
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: sentinel)
            var unsafeFile = false
            do { _ = try linked.run(now: now, retentionDays: 90) } catch CodexBarImportFailure.unsafePath { unsafeFile = true }
            let sentinelKept = try Data(contentsOf: sentinel) == Data("keep\n".utf8)
            let linkedClaudeKept = try Data(contentsOf: linkedHistory.appendingPathComponent("claude.jsonl")) == Data(original.utf8)

            let (dirLinked, _, dirHistory) = try prepare("symlink-dir")
            let realDir = dirHistory.deletingLastPathComponent().appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dirHistory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: dirHistory, withDestinationURL: realDir)
            var unsafeDir = false
            do { _ = try dirLinked.run(now: now, retentionDays: 90) } catch CodexBarImportFailure.unsafePath { unsafeDir = true }
            let realEmpty = try FileManager.default.contentsOfDirectory(atPath: realDir.path).isEmpty
            return failed && rolledBack && retry.outcome == .imported && retry.totalImported == 3
                && unsafeFile && sentinelKept && linkedClaudeKept
                && unsafeDir && realEmpty && !FileManager.default.fileExists(atPath: dirLinked.marker.path)
        } catch { print("导入失败夹具失败：\(error)"); return false }
    }

    private static func markerFailureAndUnsupported() -> Bool {
        do {
            // 旧行没有 windowMinutes 时，缺口边界仍只看 sampledAt。
            let original = #"{"sampledAt":"2030-04-05T00:00:00Z","provider":"claude","usedPercent":50,"resetsAt":"2030-04-05T03:00:00Z"}"# + "\n"
            let (base, src, history) = try prepare("marker-failure", existing: original)
            var calls = 0
            let failing = CodexBarHistoryImport(source: src, store: base.store, write: { data, url in
                calls += 1
                if calls == 3 { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            var failed = false
            do { _ = try failing.run(now: now, retentionDays: 90) } catch is CodexBarImportFailure { failed = true }
            let restored = try Data(contentsOf: history.appendingPathComponent("claude.jsonl")) == Data(original.utf8)
                && !FileManager.default.fileExists(atPath: history.appendingPathComponent("codex.jsonl").path)
                && !FileManager.default.fileExists(atPath: failing.marker.path)

            let (mixed, mixedSrc, mixedHistory) = try prepare("unsupported")
            try source(version: 9).write(to: mixedSrc.appendingPathComponent("opencodego.json"))
            let first = try mixed.run(now: now, retentionDays: 90)
            let afterFirst = try Data(contentsOf: mixedHistory.appendingPathComponent("claude.jsonl"))
            let second = try mixed.run(now: now, retentionDays: 90)
            let afterSecond = try Data(contentsOf: mixedHistory.appendingPathComponent("claude.jsonl"))
            return failed && restored
                && first.outcome == .imported && first.unsupported == [.opencodego] && first.totalImported == 3
                && !FileManager.default.fileExists(atPath: mixed.marker.path)
                && second.outcome == .imported && second.totalImported == 0 && afterSecond == afterFirst
                && first.message.contains("无法读取或版本不支持：OpenCode Go")
        } catch { print("标记失败夹具失败：\(error)"); return false }
    }

    private static func coordinatorAndMessages() -> Bool {
        do {
            let (importer, src, history) = try prepare("coordinator")
            let state = PanelPreviewRenderer.syntheticState()
            state.quotaHistory = [:]
            let coordinator = QuotaCoordinator(state: state, config: LocalConfig(), history: importer.store, importSource: src)
            let before = coordinator.codexBarImportDone, shownBefore = SettingsMenu.make(state: state).items.contains { $0.title == "导入 CodexBar 历史…" }
            let first = try coordinator.importCodexBarHistory(now: now)
            let hidden = coordinator.codexBarImportDone && !state.showsCodexBarImport
                && !SettingsMenu.make(state: state).items.contains { $0.title == "导入 CodexBar 历史…" }
            let refreshed = state.quotaHistory[.claude]?.count == 2 && state.quotaHistory[.codex]?.count == 1
            let second = try coordinator.importCodexBarHistory(now: now)
            let missing = CodexBarImportReport(outcome: .sourceMissing).message
            let nothing = CodexBarImportReport(outcome: .imported).message
            _ = history
            return !before && shownBefore && hidden && first.totalImported == 3 && refreshed && second.outcome == .alreadyImported
                && first.message.contains("已补充 3 条") && first.message.contains("Claude：2 条") && first.message.contains("Codex：1 条")
                && second.message.contains("已导入过") && missing.contains("没有找到") && nothing.contains("没有需要补充")
        } catch { print("导入协调器夹具失败：\(error)"); return false }
    }

    /// 只解析，不写任何历史文件。汇总只写进忽略目录 build/acceptance/history-import/。
    private static func liveDryRun() -> Bool {
        do {
            let store = QuotaHistoryStore()
            var summary: [String: Any] = [:]
            for provider in QuotaProvider.defaults {
                let file = CodexBarHistoryImport.defaultSource.appendingPathComponent("\(provider.rawValue).json")
                guard let data = try? Data(contentsOf: file) else { summary[provider.rawValue] = "no source"; continue }
                let existing = try store.read(provider)
                let parsed = try CodexBarHistoryImporter.parse(data, provider: provider, existing: existing,
                                                                notBefore: Date().addingTimeInterval(-90 * 86400))
                summary[provider.rawValue] = [
                    "importable": parsed.rows.count, "overlap": parsed.overlapEntries, "bad": parsed.badEntries,
                    "expired": parsed.expiredEntries, "duplicates": parsed.duplicateEntries, "skippedAccountSeries": parsed.skippedAccountSeries,
                    "earliestImported": parsed.rows.first.map { ISO8601DateFormatter().string(from: $0.sampledAt) } ?? "",
                    "earliestExisting": existing.map(\.sampledAt).min().map { ISO8601DateFormatter().string(from: $0) } ?? "",
                ]
            }
            let out = URL(fileURLWithPath: "build/acceptance/history-import", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("dry-run.json"))
            return true
        } catch { print("干跑失败：\(error)"); return false }
    }
}
