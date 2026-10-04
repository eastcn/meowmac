import AppKit
import MeowMacCore
import MeowMacUI

@MainActor
enum SystemTrendTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static func snapshot(_ seconds: Double, cpu: Double? = 0.24, temperature: Double? = 42, available: Int64? = 196_000_000_000, total: Int64? = 500_000_000_000) -> SystemSnapshot {
        SystemSnapshot(timestamp: start.addingTimeInterval(seconds), cpuUsage: cpu, memoryPressure: .normal, swapUsedBytes: 0,
            diskAvailableBytes: available, diskTotalBytes: total, networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
            battery: BatteryMetrics(temperatureCelsius: temperature, systemPowerWatts: 8.6), thermal: .nominal,
            memoryUsedBytes: 11 * 1_073_741_824, memoryTotalBytes: 16 * 1_073_741_824, memoryPressurePercent: 48)
    }
    static var tests: [(String, @MainActor () async -> Bool)] { [
        ("Core.SystemTrend/缺测、断档与真实采样选择", { timeline() }),
        ("Core.SystemTrend/重复与乱序快照", { ordering() }),
        ("UI.SystemTrend/悬停读数与无记录", { hover() }),
    ] }
    static func timeline() -> Bool {
        let domain = start...start.addingTimeInterval(90)
        let points = [snapshot(0), snapshot(10), snapshot(20, cpu: nil), snapshot(30), snapshot(80), snapshot(90, cpu: .nan)].map(ChartPoint.init)
        let runs = ChartTimeline.segments(points, in: domain, value: { $0.cpuUsage })
        guard runs.map(\.count) == [2, 1, 1], runs[1][0].date == start.addingTimeInterval(30),
              ChartTimeline.selection(points, at: start.addingTimeInterval(14), in: domain)?.timestamp == start.addingTimeInterval(10),
              ChartTimeline.selection(points, at: start.addingTimeInterval(50), in: domain) == nil,
              ChartTimeline.selection(points, at: start.addingTimeInterval(-1), in: domain) == nil else { return false }
        let missing = ChartTimeline.missingPeriods(points, in: domain) { $0.cpuUsage?.isFinite == true }
        return missing == [start.addingTimeInterval(15)...start.addingTimeInterval(25),
                           start.addingTimeInterval(35)...start.addingTimeInterval(75),
                           start.addingTimeInterval(85)...domain.upperBound]
            && ChartTimeline.segments([], in: domain, value: { $0.cpuUsage }).isEmpty
            && ChartTimeline.missingPeriods([], in: domain, available: { _ in true }) == [domain]
    }
    static func ordering() -> Bool {
        var history = ChartHistory()
        history.append(snapshot(10)); history.append(snapshot(10, cpu: 0.5), force: true)
        history.append(snapshot(0), force: true); history.append(snapshot(11)); history.append(snapshot(20))
        guard history.all.count == 2, history.all[0].cpuUsage == 0.5, history.all.last?.timestamp == start.addingTimeInterval(20) else { return false }
        history.append(snapshot(4000))
        return history.all.count == 1 && ChartTimeline.ordered([ChartPoint(snapshot: snapshot(20)), ChartPoint(snapshot: snapshot(10))], in: start...start.addingTimeInterval(30)).map(\.timestamp) == [start.addingTimeInterval(10), start.addingTimeInterval(20)]
    }
    static func hover() -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        state.snapshot = snapshot(3600); state.now = { start.addingTimeInterval(3600) }
        var history = ChartHistory(); history.append(snapshot(0)); history.append(snapshot(10, cpu: 0.5, temperature: nil)); history.append(snapshot(3600))
        state.chartHistory = history; state.chartMinutes = 60
        state.chartHoverDate = start.addingTimeInterval(10); state.chartHoverKind = "cpu"
        guard let cpu = state.systemTrends.first(where: { $0.kind == "cpu" }),
              let temperature = state.systemTrends.first(where: { $0.kind == "temperature" }),
              state.systemHoverText(cpu) == ["CPU 50.0%"],
              state.systemHoverText(temperature) == ["SoC 不可用", "电池 不可用"] else { return false }
        state.chartHoverDate = start.addingTimeInterval(100)
        guard state.chartHoverPoint == nil, state.systemHoverText(cpu) == ["无记录"] else { return false }
        state.chartHoverDate = start
        guard state.chartHoverPoint?.timestamp == start else { return false }
        state.chartMinutes = 15
        return state.chartHoverDate == nil && state.chartHoverKind == nil
    }
}
