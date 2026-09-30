import SwiftUI
import MeowMacCore

public struct DiagnosisRow: Codable {
    public let pid: Int32?
    public let name: String, detail: String, value: String, duration: String
    public let level: HealthLevel
}
public struct TrendValue: Codable {
    public let date: Date, value: Double
}
public struct SystemTrend: Codable {
    public let name: String, rangeLabel: String, current: String
    public let lower: Double, upper: Double
    public let points: [TrendValue]
}
public extension PanelState {
    var diagnosisRows: [DiagnosisRow] {
        guard let energy else { return [] }
        var rows = energy.runaway.map { process in
            DiagnosisRow(pid: process.pid, name: process.name, detail: "失控进程 · 占满 \(max(1, Int((process.cpuPercent / 100).rounded()))) 个核心",
                value: String(format: "%.0f%%", process.cpuPercent), duration: "已持续 " + MetricFormat.duration(energy.runawayDurations[process.pid] ?? configResult.config.runawaySeconds), level: .warn)
        }
        rows += energy.longAssertions.map { assertion in
            DiagnosisRow(pid: assertion.pid, name: assertion.processName ?? energy.topFive.first(where: { $0.pid == assertion.pid })?.name ?? "进程 \(assertion.pid)", detail: "阻止系统休眠",
                value: MetricFormat.duration(now().timeIntervalSince(assertion.startedAt)), duration: "从 " + DisplayDate.format(assertion.startedAt, pattern: "HH:mm") + " 开始", level: .warn)
        }
        if energy.prolongedMemoryPressure {
            rows.append(DiagnosisRow(pid: nil, name: "内存压力", detail: "内存压力持续偏高", value: snapshot?.memoryPressure == .critical ? "严重" : "偏高",
                duration: "已持续 " + MetricFormat.duration(energy.memoryPressureDuration ?? configResult.config.memoryPressureSeconds), level: snapshot?.memoryPressure == .critical ? .severe : .warn))
        }
        return rows
    }
    var trendDomain: ClosedRange<Date> {
        let end = snapshot?.timestamp ?? now()
        return end.addingTimeInterval(Double(-chartMinutes * 60))...end
    }
    var visibleChartPoints: [ChartPoint] { chartHistory.all.filter { trendDomain.contains($0.timestamp) } }
    var warmPeriods: [ClosedRange<Date>] {
        let points = visibleChartPoints
        return points.indices.compactMap { index in
            guard [.fair, .serious, .critical].contains(points[index].thermal) else { return nil }
            return points[index].timestamp...(index + 1 < points.count ? points[index + 1].timestamp : trendDomain.upperBound)
        }
    }
    var systemTrends: [SystemTrend] {
        let points = visibleChartPoints
        let total = Double(snapshot?.memoryTotalBytes ?? 0) / 1_073_741_824
        let powerMax = max(40, ceil((points.compactMap(\.systemPowerWatts).max() ?? 0) / 10) * 10)
        let temps = points.compactMap(\.batteryTemperatureCelsius)
        let minTemp = floor((temps.min() ?? 20) / 2) * 2
        let maxTemp = max(minTemp + 2, ceil((temps.max() ?? 40) / 2) * 2)
        func trend(_ name: String, _ lower: Double, _ upper: Double, _ range: String, _ current: String, _ values: (ChartPoint) -> Double?) -> SystemTrend {
            SystemTrend(name: name, rangeLabel: range, current: current, lower: lower, upper: upper,
                points: points.compactMap { point in values(point).map { TrendValue(date: point.timestamp, value: $0) } })
        }
        return [trend("CPU", 0, 100, "0–100%", snapshot?.cpuUsage.map { String(format: "%.0f%%", $0 * 100) } ?? "—", { $0.cpuUsage.map { $0 * 100 } }),
            trend("内存", 0, max(1, total), String(format: "0–%.0f GB", total), snapshot?.memoryUsedBytes.map { String(format: "%.1f GB", Double($0) / 1_073_741_824) } ?? "—", { $0.memoryUsedBytes.map { Double($0) / 1_073_741_824 } }),
            trend("整机功耗", 0, powerMax, String(format: "0–%.0f W", powerMax), snapshot?.battery.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—", { $0.systemPowerWatts }),
            trend("电池温度", minTemp, maxTemp, String(format: "%.0f–%.0f °C", minTemp, maxTemp), snapshot?.battery.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "—", { $0.batteryTemperatureCelsius })]
    }
}

struct DiagnosisCard: View {
    @ObservedObject var state: PanelState
    var body: some View {
        if !state.diagnosisRows.isEmpty {
            GlassCard(warning: true) {
                VStack(alignment: .leading, spacing: Design.rowGap) {
                    SectionHeading(title: "能耗诊断", detail: "\(state.diagnosisRows.count) 项")
                    ForEach(state.diagnosisRows.indices, id: \.self) { index in
                        let row = state.diagnosisRows[index]
                        if index > 0 { SectionRule() }
                        HStack(alignment: .top, spacing: Design.rowGap) {
                            Circle().fill(Design.state(row.level)).frame(width: Design.checkDot, height: Design.checkDot).padding(.top, Design.gap)
                            VStack(alignment: .leading, spacing: Design.smallGap) {
                                Text(row.name).font(Design.title)
                                Text(row.detail).font(Design.caption).foregroundStyle(Design.secondary)
                            }
                            Spacer(minLength: Design.gap)
                            VStack(alignment: .trailing, spacing: Design.smallGap) {
                                Text(row.value).font(Design.title).foregroundStyle(Design.stateText(row.level))
                                Text(row.duration).font(Design.caption).foregroundStyle(Design.secondary)
                            }
                        }
                    }
                    SectionRule()
                    Text("建议用 AI 诊断：把进程名和上面的数值交给 AI 助手排查").font(Design.caption).foregroundStyle(Design.secondary)
                }
            }
        }
    }
}
struct SystemChartCard: View {
    @ObservedObject var state: PanelState
    private let colors = [Design.blue, Design.teal, Design.orange, Design.purple]
    var body: some View {
        VStack(alignment: .leading, spacing: Design.rowGap) {
            HStack {
                Text("系统趋势").font(Design.title); Spacer()
                CapsuleSelector(titles: ["15 分钟", "1 小时"], selected: state.chartMinutes == 15 ? 0 : 1, compact: true) { state.chartMinutes = $0 == 0 ? 15 : 60 }
            }
            ForEach(state.systemTrends.indices, id: \.self) { index in
                let trend = state.systemTrends[index]
                VStack(spacing: Design.smallGap) {
                    HStack(spacing: Design.gap) {
                        Circle().fill(colors[index]).frame(width: Design.dot, height: Design.dot)
                        Text(trend.name).font(Design.body)
                        Text(trend.rangeLabel).font(Design.tiny).foregroundStyle(Design.secondary)
                        Spacer(); Text(trend.current).font(Design.body).monospacedDigit()
                    }
                    MiniLineGraph(points: trend.points.map { GraphValue(date: $0.date, value: $0.value) }, domain: state.trendDomain,
                        range: trend.lower...trend.upper, color: colors[index], fill: index == 1, warmPeriods: state.warmPeriods)
                }
            }
            HStack {
                Text(DisplayDate.format(state.trendDomain.lowerBound, pattern: "HH:mm")); Spacer()
                Text(DisplayDate.format(state.trendDomain.lowerBound.addingTimeInterval(state.trendDomain.upperBound.timeIntervalSince(state.trendDomain.lowerBound) / 2), pattern: "HH:mm")); Spacer()
                Text(DisplayDate.format(state.trendDomain.upperBound, pattern: "HH:mm"))
            }.font(Design.tiny).foregroundStyle(Design.secondary)
            HStack(alignment: .top, spacing: Design.smallGap) {
                Rectangle().fill(Design.orange.opacity(Design.thermalFill)).frame(width: Design.legendDot, height: Design.legendDot).padding(.top, Design.tightGap)
                Text(state.health.coolingHint ? "热状态 fair 已持续 \(Int(state.now().timeIntervalSince(state.fairSince ?? state.now()) / 60)) 分钟，达到‘建议降温’条件" : "热状态 fair 及以上的时段").fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0); Text("同一时间轴 · 各自纵轴").fixedSize()
            }.font(Design.tiny).foregroundStyle(Design.secondary)
        }
    }
}
struct EnergyCard: View {
    @ObservedObject var state: PanelState
    var body: some View {
        VStack(alignment: .leading, spacing: Design.gap) {
            SectionHeading(title: "能耗排行", detail: "前 5 名")
            HStack {
                Text("进程"); Spacer(); Text("CPU").frame(width: Design.numericColumn, alignment: .trailing)
                Text("影响分").frame(width: Design.numericColumn, alignment: .trailing)
            }.font(Design.tiny).foregroundStyle(Design.secondary).frame(height: Design.tableHeader)
            ForEach(Array((state.energy?.topFive ?? []).enumerated()), id: \.element.pid) { index, process in
                let affected = state.diagnosisRows.contains { $0.pid == process.pid }
                HStack(spacing: Design.gap) {
                    Text("\(index + 1)").font(Design.caption).foregroundStyle(affected ? Design.stateText(.warn) : Design.secondary).frame(width: Design.rankWidth, alignment: .leading)
                    Text(process.name).lineLimit(1).truncationMode(.middle); Spacer(minLength: 0)
                    Text(String(format: "%.1f%%", process.cpuPercent)).monospacedDigit().frame(width: Design.numericColumn, alignment: .trailing)
                    Text(String(format: "%.1f", process.impact)).monospacedDigit().frame(width: Design.numericColumn, alignment: .trailing)
                }.font(Design.caption).fontWeight(affected ? .semibold : .regular).foregroundStyle(affected ? Design.stateText(.warn) : Design.label).frame(height: Design.tableRow)
            }
        }
    }
}
struct DiskCard: View {
    @ObservedObject var state: PanelState
    var body: some View {
        VStack(alignment: .leading, spacing: Design.gap) {
            HStack(alignment: .firstTextBaseline, spacing: Design.gap) {
                Text("磁盘").font(Design.title)
                if let available = state.snapshot?.diskAvailableBytes {
                    Text(String(format: "%.0f", Double(available) / 1_000_000_000)).font(Design.metric)
                    Text("GB 可用").font(Design.caption).foregroundStyle(Design.secondary)
                } else { Text("容量不可用").font(Design.caption).foregroundStyle(Design.secondary) }
                Spacer(); CapsuleAction(title: "清理…", action: state.onClean)
            }
            if let available = state.snapshot?.diskAvailableBytes, let total = state.snapshot?.diskTotalBytes, total > 0 {
                LineBar(fraction: 1 - Double(available) / Double(total), color: Design.blue)
                HStack {
                    Text(String(format: "已用 %.0f GB", Double(total - available) / 1_000_000_000)); Spacer()
                    Text(String(format: "共 %.0f GB", Double(total) / 1_000_000_000))
                }.font(Design.caption).foregroundStyle(Design.secondary)
            }
            Text(state.lastCleaning.map { "上次清理：" + DisplayDate.format($0.startedAt, pattern: "M 月 d 日") + " · 释放 " + $0.sizeDescription } ?? "暂无清理记录").font(Design.caption).foregroundStyle(Design.secondary)
        }
    }
}
