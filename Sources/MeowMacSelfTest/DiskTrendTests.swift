import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum DiskTrendTests {
    static var tests: [(String, @MainActor () async -> Bool)] { [
        ("Core.DiskTrend/容量校验与旧数据兼容", { compatibility() }),
        ("UI.DiskTrend/容量变化、缺测与局部量程", { segments() }),
        ("UI.DiskTrend/部分记录与悬停", { hover() }),
    ] }
    static func compatibility() -> Bool {
        guard DiskCapacity(available: 0, total: 500)?.usedBytes == 500,
              DiskCapacity(available: nil, total: 500) == nil,
              DiskCapacity(available: -1, total: 500) == nil,
              DiskCapacity(available: 501, total: 500) == nil,
              DiskCapacity(available: 0, total: 0) == nil else { return false }
        do {
            let point = ChartPoint(snapshot: SystemTrendTests.snapshot(0))
            let encoder = JSONEncoder(), decoder = JSONDecoder()
            var old = try JSONSerialization.jsonObject(with: encoder.encode(point)) as! [String: Any]
            old.removeValue(forKey: "diskAvailableBytes"); old.removeValue(forKey: "diskTotalBytes")
            let decoded = try decoder.decode(ChartPoint.self, from: JSONSerialization.data(withJSONObject: old))
            let roundtrip = try decoder.decode(ChartPoint.self, from: encoder.encode(point))
            return decoded.diskCapacity == nil && decoded.cpuUsage == point.cpuUsage && roundtrip.diskCapacity == point.diskCapacity
        } catch { print("磁盘兼容失败：\(error)"); return false }
    }
    static func state(_ snapshots: [SystemSnapshot]) -> PanelState {
        let state = PanelPreviewRenderer.syntheticState()
        var history = ChartHistory()
        for snapshot in snapshots { history.append(snapshot, force: true) }
        state.chartHistory = history; state.snapshot = snapshots.last; state.chartMinutes = 60
        return state
    }
    static func segments() -> Bool {
        let snapshots = [SystemTrendTests.snapshot(0), SystemTrendTests.snapshot(10, available: 195_000_000_000),
            SystemTrendTests.snapshot(20, available: nil), SystemTrendTests.snapshot(30, available: 199_000_000_000),
            SystemTrendTests.snapshot(40, available: 799_000_000_000, total: 1_000_000_000_000),
            SystemTrendTests.snapshot(50, available: 798_000_000_000, total: 1_000_000_000_000),
            SystemTrendTests.snapshot(100, available: 797_000_000_000, total: 1_000_000_000_000)]
        let value = state(snapshots)
        let runs = value.diskTrend.segments ?? []
        guard runs.map(\.count) == [2, 1, 2, 1], value.diskChangeSummary == "记录不足",
              value.diskTrend.lower <= 195, value.diskTrend.upper >= 799 else { print("磁盘段：\(runs.map(\.count))"); return false }
        let constant = state([SystemTrendTests.snapshot(0), SystemTrendTests.snapshot(10)])
        return constant.diskTrend.upper - constant.diskTrend.lower >= 1
            && constant.diskChangeSummary.contains("基本不变")
            && state([SystemTrendTests.snapshot(0, available: 0)]).diskTrend.points.first?.value == 0
            && state([SystemTrendTests.snapshot(0, available: -1)]).diskTrend.points.isEmpty
    }
    static func hover() -> Bool {
        let value = state([SystemTrendTests.snapshot(0), SystemTrendTests.snapshot(10, available: 195_000_000_000)])
        value.chartHoverDate = SystemTrendTests.start; value.chartHoverKind = "disk"
        guard value.diskHoverText == ["可用 196.0 GB", "已用 304.0 GB · 共 500.0 GB"],
              value.diskChangeSummary.hasPrefix("已记录 "), value.diskChangeSummary.hasSuffix("减少 1.0 GB") else { return false }
        value.chartHoverDate = SystemTrendTests.start.addingTimeInterval(-100)
        guard value.diskHoverText == ["无记录"] else { return false }
        let missing = state([SystemTrendTests.snapshot(0, available: nil)])
        missing.chartHoverDate = SystemTrendTests.start
        return missing.diskHoverText == ["磁盘容量不可用"] && missing.diskCapacity == nil
    }
}
