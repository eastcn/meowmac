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
    /// 行的身份，决定颜色：cpu、memory、power、temperature、fan。
    public var kind: String = ""
    /// 同一行的第二条线；温度行用它画电池温度。
    public var secondaryPoints: [TrendValue]? = nil
    public var secondaryCurrent: String? = nil
    /// 虚线阈值；风扇行用它标降温阈值。
    public var threshold: Double? = nil
    /// 名称下面的副信息。
    public var detail: String = ""
    /// 达到降温条件时，副信息和当前值转为橙色。
    public var warn: Bool = false
    /// 悬停提示：量程，以及读不到时的原因。
    public var help: String = ""
    public var segments: [[TrendValue]]? = nil
    public var secondarySegments: [[TrendValue]]? = nil
    public var missingPeriods: [ClosedRange<Date>]? = nil
}
public extension PanelState {
    var chartHoverPoint: ChartPoint? {
        chartHoverDate.flatMap { ChartTimeline.selection(chartHistory.all, at: $0, in: trendDomain) }
    }
    var chartCursorDate: Date? { chartHoverPoint?.timestamp ?? chartHoverDate }
    var diagnosisRows: [DiagnosisRow] {
        guard let energy else { return [] }
        var rows = energy.runaway.map { process in
            DiagnosisRow(pid: process.pid, name: process.name, detail: "失控进程 · 占满 \(max(1, Int((process.cpuPercent / 100).rounded()))) 个核心",
                value: String(format: "%.0f%%", process.cpuPercent), duration: "已持续 " + MetricFormat.duration(energy.runawayDurations[process.pid] ?? configResult.config.runawaySeconds), level: .warn)
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
        let temps = points.compactMap(\.batteryTemperatureCelsius) + points.compactMap(\.socTemperatureCelsius)
        let minTemp = floor((temps.min() ?? 20) / 2) * 2
        let maxTemp = max(minTemp + 2, ceil((temps.max() ?? 40) / 2) * 2)
        func segments(_ value: (ChartPoint) -> Double?) -> [[TrendValue]] {
            ChartTimeline.segments(points, in: trendDomain, value: value).map { $0.map { TrendValue(date: $0.date, value: $0.value) } }
        }
        func values(_ value: (ChartPoint) -> Double?) -> [TrendValue] { segments(value).flatMap { $0 } }
        func trend(_ kind: String, _ name: String, _ lower: Double, _ upper: Double, _ range: String, _ current: String, _ detail: String, _ value: (ChartPoint) -> Double?) -> SystemTrend {
            var trend = SystemTrend(name: name, rangeLabel: range, current: current, lower: lower, upper: upper, points: values(value))
            trend.kind = kind; trend.detail = detail; trend.help = name + " · 量程 " + range
            trend.segments = segments(value)
            trend.missingPeriods = ChartTimeline.missingPeriods(points, in: trendDomain) { value($0)?.isFinite == true }
            return trend
        }
        var temperature = trend("temperature", "温度", minTemp, maxTemp, String(format: "%.0f–%.0f °C", minTemp, maxTemp),
            snapshot?.sensors?.cpuAverageCelsius.map { String(format: "%.1f °C", $0) } ?? "—", temperatureDetail, { $0.socTemperatureCelsius })
        temperature.secondaryPoints = values { $0.batteryTemperatureCelsius }
        temperature.secondarySegments = segments { $0.batteryTemperatureCelsius }
        temperature.missingPeriods = ChartTimeline.missingPeriods(points, in: trendDomain) {
            $0.socTemperatureCelsius?.isFinite == true || $0.batteryTemperatureCelsius?.isFinite == true
        }
        temperature.secondaryCurrent = "电池 " + (snapshot?.battery.temperatureCelsius.map { String(format: "%.1f", $0) } ?? "—")
        temperature.help += "\n靛蓝：SoC 平均温度；粉：电池温度\n" + sensorHelp
        var rows = [trend("cpu", "CPU", 0, 100, "0–100%", snapshot?.cpuUsage.map { String(format: "%.0f%%", $0 * 100) } ?? "—", "整机负载", { $0.cpuUsage.map { $0 * 100 } }),
            trend("memory", "内存", 0, max(1, total), String(format: "0–%.0f GB", total), snapshot?.memoryUsedBytes.map { String(format: "%.1f GB", Double($0) / 1_073_741_824) } ?? "—",
                  String(format: "已用 / %.0f GB", total), { $0.memoryUsedBytes.map { Double($0) / 1_073_741_824 } }),
            trend("power", "整机功耗", 0, powerMax, String(format: "0–%.0f W", powerMax), snapshot?.battery.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—",
                  String(format: "0–%.0f W", powerMax), { $0.systemPowerWatts }),
            temperature]
        // 本机报告没有风扇时不画风扇行；读不到时保留这一行，显示“—”。
        if snapshot?.sensors?.fans != [] {
            let knownMax = snapshot?.sensors?.leadingFan?.maxRPM ?? points.compactMap(\.fanMaxRPM).max()
            let fanMax = knownMax ?? max(1000, ceil((points.compactMap(\.fanRPM).max() ?? 0) / 1000) * 1000)
            let fanRange = knownMax == nil && !points.contains(where: { $0.fanRPM != nil }) ? "" : String(format: "0–%.0f rpm", fanMax)
            let detail = fanDetail
            var fan = trend("fan", "风扇", 0, fanMax, fanRange,
                snapshot?.sensors?.leadingFan.map { String(format: "%.0f rpm", $0.rpm) } ?? "—", detail.text, { $0.fanRPM })
            fan.threshold = knownMax.map { $0 * configResult.config.fanHighFraction }
            fan.warn = detail.warn
            fan.help = fanRange.isEmpty ? "风扇 · " + sensorHelp : fan.help + "\n虚线：建议降温阈值（最大值的 " + Self.percent(configResult.config.fanHighFraction) + "）"
            rows.append(fan)
        }
        return rows
    }
}

struct DiagnosisCard: View {
    @ObservedObject var state: PanelState
    var body: some View {
        if !state.diagnosisRows.isEmpty {
            GlassCard(warning: true) {
                VStack(alignment: .leading, spacing: Design.smallGap + 1) {
                    SectionHeading(title: "能耗诊断", detail: "\(state.diagnosisRows.count) 项")
                    // 每个问题一行：进程名、问题类型、数值和持续时长。
                    ForEach(state.diagnosisRows.indices, id: \.self) { index in
                        let row = state.diagnosisRows[index]
                        HStack(alignment: .firstTextBaseline, spacing: Design.gap) {
                            Circle().fill(Design.state(row.level)).frame(width: Design.checkDot, height: Design.checkDot)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Design.smallGap }
                            Text(row.name).font(Design.title).lineLimit(1).layoutPriority(2)
                            Text(row.detail).font(Design.caption).foregroundStyle(Design.secondary).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: Design.gap)
                            Text(row.value).font(Design.title).foregroundStyle(Design.stateText(row.level)).monospacedDigit().layoutPriority(2)
                            Text(row.duration.replacingOccurrences(of: "已持续 ", with: "")).font(Design.caption)
                                .foregroundStyle(Design.secondary).monospacedDigit().lineLimit(1).layoutPriority(1)
                        }.help(row.name + "：" + row.detail + "，" + row.duration)
                    }
                    Text("建议用 AI 诊断：把进程名和数值交给 AI 助手排查").font(Design.caption).foregroundStyle(Design.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }
}
struct SystemChartCard: View {
    @ObservedObject var state: PanelState
    static func color(_ kind: String) -> Color {
        switch kind {
        case "cpu": return Design.blue
        case "memory": return Design.purple
        case "power": return Design.teal
        case "temperature": return Design.indigo
        case "fan": return Design.brown
        default: return Design.gray
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Design.rowGap) {
            HStack {
                Text("系统趋势").font(Design.title); Spacer()
                CapsuleSelector(titles: ["15 分钟", "1 小时"], selected: state.chartMinutes == 15 ? 0 : 1, compact: true) { state.chartMinutes = $0 == 0 ? 15 : 60 }
            }
            VStack(spacing: Design.tightGap) {
                ForEach(state.systemTrends.indices, id: \.self) { index in
                    let trend = state.systemTrends[index]
                    SystemTrendRow(state: state, trend: trend)
                        .zIndex(state.chartHoverKind == trend.kind ? 10 : 0)
                }
            }
            HStack {
                Text(DisplayDate.format(state.trendDomain.lowerBound, pattern: "HH:mm")); Spacer()
                Text(DisplayDate.format(state.trendDomain.lowerBound.addingTimeInterval(state.trendDomain.upperBound.timeIntervalSince(state.trendDomain.lowerBound) / 2), pattern: "HH:mm")); Spacer()
                Text(DisplayDate.format(state.trendDomain.upperBound, pattern: "HH:mm"))
            }.font(Design.tiny).foregroundStyle(Design.secondary)
            HStack(alignment: .top, spacing: Design.smallGap) {
                Rectangle().fill(Design.orange.opacity(Design.thermalFill)).frame(width: Design.legendDot, height: Design.legendDot).padding(.top, Design.tightGap)
                Text(state.coolingLegend).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0); Text("同一时间轴").fixedSize()
            }.font(Design.tiny).foregroundStyle(Design.secondary)
        }
    }
}
struct EnergyCard: View {
    @ObservedObject var state: PanelState
    var body: some View {
        VStack(alignment: .leading, spacing: Design.tightGap) {
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
                }.font(Design.body).fontWeight(affected ? .semibold : .regular).foregroundStyle(affected ? Design.stateText(.warn) : Design.label).frame(height: Design.tableRow)
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
                Spacer(); CapsuleAction(title: "清理…", action: state.onClean).disabled(state.cleanLaunching)
            }
            if let available = state.snapshot?.diskAvailableBytes, let total = state.snapshot?.diskTotalBytes, total > 0 {
                LineBar(fraction: 1 - Double(available) / Double(total), color: Double(available) / Double(total) < 0.1 ? Design.orange : Design.gray)
                HStack {
                    Text(String(format: "已用 %.0f GB", Double(total - available) / 1_000_000_000)); Spacer()
                    Text(String(format: "共 %.0f GB", Double(total) / 1_000_000_000))
                }.font(Design.caption).foregroundStyle(Design.secondary)
            }
            Text(state.cleaningHistoryMessage ?? state.lastCleaning.map { "上次清理：" + DisplayDate.format($0.startedAt, pattern: "M 月 d 日") + " · 释放 " + $0.sizeDescription } ?? "暂无清理记录").font(Design.caption).foregroundStyle(Design.secondary)
        }
    }
}
