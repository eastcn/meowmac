import Foundation
import MeowMacCore

@MainActor
enum HistoryTests {
    static let tests: [(String, @MainActor () -> Bool)] = [
        ("Core.History/两条解析路径的窗口时长", parserDurations),
        ("Core.History/旧行异名与重置容差", currentCycle),
        ("Core.History/峰值容差与七天边界", peaks),
        ("Core.History/损坏单行与旧格式", damagedLine),
    ]

    private static let now = ISO8601DateFormatter().date(from: "2030-04-10T12:00:00Z")!

    private static func parserDurations() -> Bool {
        let dashboard = Data(#"{"providers":[{"id":"claude","windows":[{"kind":"session","usedPercent":20},{"kind":"weekly","usedPercent":40},{"kind":"other","label":"7 天","usedPercent":60}]}]}"#.utf8)
        let usage = Data(#"[{"provider":"claude","usage":{"primary":{"usedPercent":20,"windowMinutes":300},"secondary":{"usedPercent":40,"windowMinutes":10080}}}]"#.utf8)
        guard let first = try? CodexBarParser.dashboard(dashboard, at: now).snapshots[.claude],
              let second = try? CodexBarParser.usage(usage, at: now) else { return false }
        return first.windows.map(\.effectiveWindowMinutes) == [300, 10080, 10080]
            && Array(first.windows.prefix(2)).map(\.effectiveWindowMinutes) == second.windows.map(\.effectiveWindowMinutes)
    }

    private static func currentCycle() -> Bool {
        let reset = now.addingTimeInterval(86400)
        let start = reset.addingTimeInterval(-7 * 86400)
        let window = QuotaWindow(usedPercent: 55, windowMinutes: 10080, resetsAt: reset, resetDescription: nil, identifier: "secondary")
        let rows = [
            row(time: start, reset: reset, minutes: nil, used: 0, id: "weekly"),
            row(time: now.addingTimeInterval(-3600), reset: reset.addingTimeInterval(-5), minutes: 10080, used: 40, id: "weekly"),
            row(time: now, reset: reset.addingTimeInterval(600), minutes: 10080, used: 55, id: "secondary"),
            row(time: now, reset: reset.addingTimeInterval(601), minutes: 10080, used: 99),
            row(time: start.addingTimeInterval(-1), reset: reset, minutes: 10080, used: 99),
            row(time: now.addingTimeInterval(1), reset: reset, minutes: 10080, used: 99),
            row(time: now, reset: reset, minutes: 300, used: 99),
            row(time: now, reset: now.addingTimeInterval(8 * 86400), minutes: nil, used: 99),
        ]
        let cycle = QuotaHistorySeries.currentCycle(rows.reversed(), window: window, now: now)
        return cycle.map(\.usedPercent) == [0, 40, 55]
    }

    private static func peaks() -> Bool {
        let previous = now.addingTimeInterval(-18000), current = now.addingTimeInterval(3600)
        let rows = [
            row(time: previous.addingTimeInterval(-600), reset: previous, minutes: nil, used: 45, id: "session"),
            row(time: previous.addingTimeInterval(-300), reset: previous.addingTimeInterval(5), minutes: 300, used: 88),
            row(time: now.addingTimeInterval(-600), reset: current, minutes: 300, used: 20, id: "session"),
            row(time: now, reset: current.addingTimeInterval(600), minutes: nil, used: 30),
            row(time: now.addingTimeInterval(-7 * 86400 - 1), reset: previous, minutes: 300, used: 99),
            row(time: now.addingTimeInterval(1), reset: current, minutes: 300, used: 99),
            row(time: now, reset: current, minutes: 10080, used: 99),
            row(time: now, reset: nil, minutes: nil, used: 99),
        ]
        let peaks = QuotaHistorySeries.peaks(rows.reversed(), now: now)
        return peaks.count == 2 && peaks.map(\.usedPercent) == [88, 30]
            && !peaks[0].isCurrent && peaks[1].isCurrent
    }

    private static func damagedLine() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = #"{"sampledAt":"2030-04-10T11:00:00Z","provider":"claude","usedPercent":20,"resetsAt":"2030-04-10T13:00:00Z","windowID":"session"}"# + "\n{broken}\n" + #"{"sampledAt":"2030-04-10T12:00:00Z","provider":"claude","windowMinutes":300,"usedPercent":28,"resetsAt":"2030-04-10T13:00:05Z","windowID":"primary"}"# + "\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: directory.appendingPathComponent("claude.jsonl"))
            let rows = try QuotaHistoryStore(directory: directory).read(.claude)
            return rows.count == 2 && rows[0].windowMinutes == nil && rows[1].windowID == "primary"
                && QuotaHistorySeries.peaks(rows, now: now).map(\.usedPercent) == [28]
        } catch { print("历史夹具失败：\(error)"); return false }
    }

    private static func row(time: Date, reset: Date?, minutes: Int?, used: Double, id: String = "primary") -> QuotaHistoryLine {
        QuotaHistoryLine(sampledAt: time, provider: .claude, windowMinutes: minutes, usedPercent: used, resetsAt: reset, windowID: id)
    }
}
