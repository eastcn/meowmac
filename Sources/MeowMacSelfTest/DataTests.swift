import Foundation
import MeowMacCore
import MeowMacSystem

@MainActor
enum DataTests {
    static let tests: [(String, @MainActor () -> Bool)] = [
        ("Core.Format/速率单位", {
            MetricFormat.rate(0) == "0.0B" && MetricFormat.rate(1024) == "1.0K"
                && MetricFormat.rate(2.4 * 1024 * 1024) == "2.4M"
                && MetricFormat.rate(1024 * 1024 * 1024) == "1.0G"
                && MetricFormat.rate(-1) == "0.0B"
        }),
        ("Core.Pace/节奏正常与缺失", {
            let now = Date(timeIntervalSince1970: 1_000_000)
            let normal = QuotaWindow(usedPercent: 28, windowMinutes: 300, resetsAt: now.addingTimeInterval(300 * 60 * 0.55), resetDescription: nil)
            let missing = QuotaWindow(usedPercent: 70, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
            guard let pace = QuotaPace.calculate(window: normal, now: now) else { return false }
            return !pace.exhaustsBeforeReset && abs(pace.expectedRemainingFraction - 0.55) < 0.000001
                && QuotaPace.calculate(window: missing, now: now) == nil
        }),
        ("Core.Pace/快出19个百分点与提醒", {
            let now = Date(timeIntervalSince1970: 1_000_000)
            let window = QuotaWindow(usedPercent: 70, windowMinutes: 10080, resetsAt: now.addingTimeInterval(10080 * 60 * 0.49), resetDescription: nil, identifier: "secondary", name: "每周")
            guard let pace = QuotaPace.calculate(window: window, now: now) else { return false }
            let quota = QuotaSnapshot(provider: .codex, source: "fixture", updatedAt: now, windows: [window], paceSummary: nil, credits: nil)
            let summary = HealthEvaluator.evaluate(HealthInputs(system: nil, energy: nil, quotaUsedPercent: [70], network: .green, failedSources: [:], fairSince: nil, now: now, quotaSnapshots: [quota]), config: LocalConfig())
            return abs(pace.aheadPercentagePoints - 19) < 0.000001 && pace.exhaustsBeforeReset
                && abs((pace.secondsUntilExhaustion ?? 0) - 132192) < 0.001
                && summary.level == .warn && summary.worst?.message == "Codex 每周额度偏快"
        }),
        ("Core.Quota/新增字段与推断", {
            let json = #"[{"provider":"codex","source":"fixture","usage":{"accountEmail":"you@example.com","planName":"Plus","updatedAt":"2026-09-30T06:35:00.000Z","secondary":{"usedPercent":70,"windowMinutes":10080,"resetsAt":"2026-10-04T00:58:00Z"},"codexResetCredits":{"availableCount":2,"credits":[{"expires_at":"2026-10-23T00:00:00Z"},{"expires_at":"2026-10-30T00:00:00Z"}]}},"credits":{"remaining":12}}]"#
            guard let snapshot = try? CodexBarParser.usage(Data(json.utf8), at: Date()) else { return false }
            let inferred = QuotaWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil, name: "5 小时")
            return snapshot.accountEmail == "you@example.com" && snapshot.planName == "Plus"
                && snapshot.codexResetCredits?.availableCount == 2 && snapshot.codexResetCredits?.expiresAt.count == 2
                && snapshot.windows[0].identifier == "secondary" && snapshot.credits == 12 && inferred.effectiveWindowMinutes == 300
        }),
        ("Core.History/峰值分组与本轮截取", history),
        ("System.Storage/分段和文件数量", storage),
    ]

    private static func history() -> Bool {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let previous = now.addingTimeInterval(-300), current = now.addingTimeInterval(600)
        let rows = [(previous, 30.0), (previous, 85), (current, 28)].map { reset, used in
            QuotaHistoryLine(sampledAt: now.addingTimeInterval(-600), provider: .claude, windowMinutes: 300, usedPercent: used, resetsAt: reset)
        }
        let peaks = QuotaHistorySeries.peaks(rows, now: now)
        guard peaks.count == 2, peaks[0].usedPercent == 85, peaks[1].isCurrent else { return false }
        let window = QuotaWindow(usedPercent: 57, windowMinutes: 10080, resetsAt: now.addingTimeInterval(1000), resetDescription: nil, identifier: "secondary")
        let long = [
            QuotaHistoryLine(sampledAt: now.addingTimeInterval(-100), provider: .claude, windowMinutes: 10080, usedPercent: 50, resetsAt: window.resetsAt, windowID: "secondary"),
            QuotaHistoryLine(sampledAt: now.addingTimeInterval(-8 * 86400), provider: .claude, windowMinutes: 10080, usedPercent: 90, resetsAt: window.resetsAt),
            QuotaHistoryLine(sampledAt: now, provider: .claude, windowMinutes: 10080, usedPercent: 98, resetsAt: previous),
        ]
        let cycle = QuotaHistorySeries.currentCycle(long, window: window, now: now)
        return cycle.count == 1 && cycle[0].usedPercent == 50
    }

    private static func storage() -> Bool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            for provider in [QuotaProvider.codex, .claude] {
                let directory = root.appendingPathComponent(provider.rawValue)
                let session = provider == .codex ? "archived_sessions" : "projects"
                let cache = provider == .codex ? "cache" : "file-history"
                for name in [session, cache, "other"] {
                    let folder = directory.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Data(repeating: 65, count: 8192).write(to: folder.appendingPathComponent("fixture.dat"))
                }
                let snapshot = try LocalStorageCollector.scan(directory: directory, provider: provider)
                guard snapshot.sessionFileCount == 1, snapshot.sessionsBytes >= 8192,
                      snapshot.cacheBytes >= 8192, snapshot.otherBytes >= 8192,
                      snapshot.totalBytes == snapshot.sessionsBytes + snapshot.cacheBytes + snapshot.otherBytes else { return false }
            }
            return true
        } catch { print("存储夹具失败：\(error)"); return false }
    }
}
