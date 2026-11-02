import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum CostTests {
    static func totals() -> Bool {
        let state = fixture()
        guard let value = state.costDisplay(.codex) else { return false }
        return value.todayCost == 2 && value.weekCost == 5 && value.totalCost == 12
            && value.todayTokens == 100 && value.weekTokens == 300 && value.totalTokens == 700
            && value.mostUsedModel == "example-month" && state.costChartDates.count == 30
            && state.costChartDates.first == "2026-09-01" && state.costChartDates.last == "2026-09-30"
            && state.costDisplay(.deepseek) == nil && state.costDisplay(.opencodego) == nil
    }
    static func selection() -> Bool {
        let state = fixture()
        guard state.displayedCostDate == "2026-09-30" else { return false }
        state.selectCostDay("2026-09-24")
        let day = state.costDayDisplay(.codex, date: state.displayedCostDate)
        guard day.date == "2026-09-24", day.totalCost == 3, day.totalTokens == 200,
              day.mostUsedModel == "example-week", day.detailText == "9/24 · $3.00 · 200 tokens · example-week" else { return false }
        state.selectCostDay("2026-09-24")
        guard state.displayedCostDate == "2026-09-30" else { return false }
        state.selectCostDay("2026-09-24")
        state.selectedProvider = .claude
        guard state.displayedCostDate == "2026-09-30" else { return false }
        state.selectCostDay("2026-09-23")
        let empty = state.costDayDisplay(.claude, date: state.displayedCostDate)
        guard !empty.hasData, empty.totalCost == 0, empty.detailText == "9/23 · 无记录" else { return false }
        state.selectCostDay("2026-08-31")
        return state.displayedCostDate == "2026-09-23"
    }
    static func archive() -> Bool {
        let today = ISO8601DateFormatter().date(from: "2026-09-30T12:00:00Z")!
        let kept = DailyCost(date: "2026-09-10", totalCost: 5, totalTokens: 50)
        let shrunk = DailyCost(date: "2026-09-12", totalCost: 8)
        let old = DailyCost(date: "2026-05-01", totalCost: 1)
        let merged = CostArchive.merge(
            archived: [kept, shrunk, old],
            fresh: [DailyCost(date: "2026-09-12", totalCost: 3), DailyCost(date: "2026-09-30", totalCost: 2)],
            today: today)
        guard merged.map(\.date) == ["2026-09-10", "2026-09-12", "2026-09-30"],
              merged[0].totalCost == 5, merged[1].totalCost == 8, merged[2].totalCost == 2 else { return false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meowmac-cost-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CostArchiveStore(directory: dir)
        _ = store.merged(.codex, fresh: [kept], today: today)
        let again = store.merged(.codex, fresh: [DailyCost(date: "2026-09-30", totalCost: 2)], today: today)
        return again.map(\.date) == ["2026-09-10", "2026-09-30"] && store.load(.claude).isEmpty
    }
    static func snapshot() -> Bool {
        let state = fixture()
        state.selectCostDay("2026-09-24")
        do {
            let data = try JSONEncoder().encode(PanelSnapshot(state: state))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let quota = json?["quota"] as? [[String: Any]]
            let channel = quota?.first { $0["provider"] as? String == "codex" }
            let cost = channel?["cost"] as? [String: Any]
            let days = channel?["costDays"] as? [[String: Any]]
            let selected = channel?["selectedCostDay"] as? [String: Any]
            return cost?["weekCost"] as? Double == 5 && cost?["weekTokens"] as? Int == 300
                && days?.count == 30 && selected?["date"] as? String == "2026-09-24"
                && selected?["mostUsedModel"] as? String == "example-week"
        } catch { print("花费快照编码失败：\(error)"); return false }
    }
    private static func fixture() -> PanelState {
        let state = PanelPreviewRenderer.syntheticState()
        state.costs[.codex] = [
            DailyCost(date: "2026-09-30", totalCost: 2, totalTokens: 100, models: [CostModel(name: "example-today", tokens: 100)]),
            DailyCost(date: "2026-09-24", totalCost: 3, totalTokens: 200, models: [CostModel(name: "example-week", tokens: 200)]),
            DailyCost(date: "2026-09-23", totalCost: 4, totalTokens: 300, models: [CostModel(name: "example-month", tokens: 300)]),
            DailyCost(date: "2026-09-01", totalCost: 3, totalTokens: 100, models: [CostModel(name: "example-month", tokens: 100)]),
            DailyCost(date: "2026-08-31", totalCost: 99, totalTokens: 999),
            DailyCost(date: "2026-10-01", totalCost: 99, totalTokens: 999)]
        state.costs[.claude] = [DailyCost(date: "2026-09-30", totalCost: 1, totalTokens: nil)]
        return state
    }
}
