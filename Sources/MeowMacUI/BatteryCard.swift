import SwiftUI
import MeowMacCore

/// 预计时间一行：前缀、加重的数字部分和后缀。
public struct BatteryEstimateText: Equatable {
    public let prefix: String, emphasis: String, suffix: String
    public init(_ prefix: String, _ emphasis: String = "", _ suffix: String = "") {
        self.prefix = prefix; self.emphasis = emphasis; self.suffix = suffix
    }
    public var plain: String { prefix + emphasis + suffix }
}

/// 电池卡片的文案（设计稿 battery.html）。纯计算，便于离线核对。
public struct BatteryCardDisplay: Equatable {
    public let percent: String
    public let state: String
    public let rate: String
    public let estimate: BatteryEstimateText
    public let summary: String
    public let health: String
    public let cycles: String
    public let designCycles: String?
    /// 健康行右侧：电池温度，放电时写低电量参考线，接电源时写适配器。
    public let meta: String
    /// 健康行的悬停提示：原始满充、设计容量和换算百分比。
    public let healthHelp: String

    public static func make(status: BatteryStatus, temperature: Double?, systemPower: Double?,
                            history: BatteryHistory, now: Date) -> BatteryCardDisplay {
        let rate: String
        switch status.state {
        case .battery: rate = "放电 " + BatteryFormat.watts(status.powerWatts)
        case .charging: rate = "充电 " + BatteryFormat.watts(status.powerWatts)
        // D7：接电源但不充电时写整机功耗。
        case .charged, .acNotCharging, .noBattery: rate = "整机 " + BatteryFormat.watts(systemPower)
        }
        let estimate: BatteryEstimateText
        switch status.state {
        case .battery:
            estimate = status.estimateMinutes.map { BatteryEstimateText("预计还能用 ", BatteryFormat.duration(minutes: $0)) }
                ?? BatteryEstimateText("续航估算中，系统还没给出预计时间")
        case .charging:
            // D6：只写充满所需时间，不写目标百分比。
            estimate = status.estimateMinutes.map { BatteryEstimateText("预计 ", BatteryFormat.duration(minutes: $0), "充满") }
                ?? BatteryEstimateText("充电中，系统还没给出预计充满时间")
        case .charged: estimate = BatteryEstimateText("由电源供电，电池已充满")
        case .acNotCharging:
            estimate = BatteryEstimateText("由电源供电，电池保持在 " + (status.percent.map { "\($0)%" } ?? "当前电量"))
        case .noBattery: estimate = BatteryEstimateText("本机没有电池")
        }
        let summary = history.summary(now: now)
        let summaryText: String
        if summary.hasBatteryUse {
            var parts = ["用电池 " + BatteryFormat.duration(seconds: summary.batterySeconds), "耗电 \(summary.drainedPercent)%"]
            if let watts = summary.averageWatts { parts.append("平均 " + BatteryFormat.watts(watts)) }
            summaryText = parts.joined(separator: " · ")
        } else if summary.coversWindow {
            summaryText = "近 24 小时未用电池"
        } else {
            summaryText = "已记录 " + BatteryFormat.duration(seconds: summary.recordedSeconds)
        }
        let temperatureText = "电池 " + (temperature.map { String(format: "%.1f °C", $0) } ?? "—")
        let tail = status.state == .battery ? "低电量 20%" : "适配器 " + (status.adapterWatts.map { "\($0) W" } ?? "—")
        let raw = status.rawMaxCapacity.map { "\($0) mAh" } ?? "—", design = status.designCapacity.map { "\($0) mAh" } ?? "—"
        let ratio = status.rawHealthPercent.map { String(format: "%.1f%%", $0) } ?? "—"
        return BatteryCardDisplay(
            percent: status.percent.map(String.init) ?? "—", state: status.state.title, rate: rate, estimate: estimate,
            summary: summaryText, health: status.maxCapacityPercent.map { "\($0)%" } ?? "—",
            cycles: status.cycleCount.map(String.init) ?? "—", designCycles: status.designCycleCount.map(String.init),
            meta: temperatureText + " · " + tail,
            healthHelp: "健康按系统口径的最大容量，与“系统设置 › 电池”一致。\n原始满充 \(raw) · 设计容量 \(design) · 换算 \(ratio)")
    }
}

public enum BatteryFormat {
    /// 保留 1 位小数，四舍五入（9.95 写作 10.0 W）。读不到写“—”。
    public static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        // 加一点余量，避免 9.95 这类二进制下略小于 .5 的值被舍去。
        let tenths = (value * 10 + 0.5 + 1e-9).rounded(.down)
        return String(format: "%.1f W", tenths / 10)
    }

    public static func duration(minutes: Int) -> String { duration(seconds: TimeInterval(minutes) * 60) }

    /// 不足 1 小时写“N 分钟”；整小时写“N 小时”；其余写“N 小时 M 分”。
    public static func duration(seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) 分钟" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}

public extension PanelState {
    /// 近 24 小时曲线的终点：最新快照时刻，没有快照时取当前时刻。
    var batteryNow: Date { snapshot?.timestamp ?? now() }
    var batteryDomain: ClosedRange<Date> { batteryNow.addingTimeInterval(-BatteryHistory.retention)...batteryNow }
    var batteryDisplay: BatteryCardDisplay? {
        guard let status = snapshot?.battery.status, status.hasBattery else { return nil }
        return BatteryCardDisplay.make(status: status, temperature: snapshot?.battery.temperatureCelsius,
                                       systemPower: snapshot?.battery.systemPowerWatts, history: batteryHistory, now: batteryNow)
    }
    var batteryHoverRecord: BatteryHistoryRecord? {
        batteryHoverDate.flatMap { batteryHistory.selection(at: $0, now: batteryNow) }
    }
    var batteryHoverText: [String] {
        guard let record = batteryHoverRecord else { return ["无记录"] }
        return ["电量 \(record.percent)%", record.state.title]
    }
}

struct BatteryCard: View {
    @ObservedObject var state: PanelState
    var body: some View {
        if let value = state.batteryDisplay {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("电池").font(Design.title)
                    Text(value.percent).font(Design.metric).monospacedDigit().padding(.leading, Design.gap)
                    Text("%").font(Design.caption).foregroundStyle(Design.secondary)
                    Text(value.state).font(.system(size: 12, weight: .medium)).padding(.leading, Design.rowGap)
                    Spacer(minLength: Design.gap)
                    Text(value.rate).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }.padding(.bottom, Design.rowGap)
                HStack(spacing: Design.smallGap) {
                    (Text(value.estimate.prefix) + Text(value.estimate.emphasis).foregroundColor(Design.label).fontWeight(.medium) + Text(value.estimate.suffix))
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Text("近 24 小时").fixedSize()
                }.font(Design.tiny).foregroundStyle(Design.secondary).padding(.bottom, 5)
                BatteryGraph(state: state)
                HStack {
                    Text("昨天 " + DisplayDate.format(state.batteryDomain.lowerBound, pattern: "HH:mm")); Spacer()
                    Text(DisplayDate.format(state.batteryDomain.lowerBound.addingTimeInterval(BatteryHistory.retention / 2), pattern: "HH:mm")); Spacer()
                    Text(DisplayDate.format(state.batteryDomain.upperBound, pattern: "HH:mm"))
                }.font(Design.tiny).foregroundStyle(Design.secondary).monospacedDigit().padding(.top, 5)
                HStack(spacing: 5) {
                    Rectangle().fill(Design.state(.normal).opacity(0.3)).frame(width: 7, height: 7)
                    Text("接电源的时段").fixedSize()
                    Spacer(minLength: Design.gap)
                    Text(value.summary).monospacedDigit().lineLimit(1)
                }.font(Design.tiny).foregroundStyle(Design.secondary).padding(.top, 5)
                HStack {
                    (Text("健康 ") + Text(value.health).foregroundColor(Design.label).fontWeight(.medium)
                        + Text(" · 循环 ") + Text(value.cycles).foregroundColor(Design.label).fontWeight(.medium)
                        + Text(value.designCycles.map { " / " + $0 } ?? ""))
                        .monospacedDigit().help(value.healthHelp)
                        .accessibilityIdentifier("battery.health")
                    Spacer(minLength: Design.gap)
                    Text(value.meta).monospacedDigit().lineLimit(1)
                }.font(Design.tiny).foregroundStyle(Design.secondary).padding(.top, 6)
            }.zIndex(state.chartHoverKind == "battery" ? 10 : 0)
        }
    }
}

/// 近 24 小时电量曲线：灰线加浅填充，接电源时段绿色底，无记录斜纹，20% 橙色虚线。
struct BatteryGraph: View {
    @Environment(\.previewMaterial) private var previewMaterial
    @ObservedObject var state: PanelState
    var height: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let domain = state.batteryDomain
            let segments = state.batteryHistory.segments(now: domain.upperBound)
            let selected = state.batteryHoverRecord?.sampledAt
            Canvas { context, size in
                func x(_ date: Date) -> CGFloat { size.width * date.timeIntervalSince(domain.lowerBound) / BatteryHistory.retention }
                func y(_ percent: Int) -> CGFloat { size.height - 1 - (size.height - 2) * CGFloat(min(100, max(0, percent))) / 100 }
                // 接电源的时段：同一段内相邻两点，前一点接着电源。
                for segment in segments {
                    for (a, b) in zip(segment, segment.dropFirst()) where a.state.isExternalPower {
                        context.fill(Path(CGRect(x: x(a.sampledAt), y: 0, width: x(b.sampledAt) - x(a.sampledAt), height: size.height)),
                                     with: .color(Design.state(.normal).opacity(0.14)))
                    }
                }
                for period in BatteryHistory.missingPeriods(segments, domain: domain) {
                    let rect = CGRect(x: x(period.lowerBound), y: 0, width: x(period.upperBound) - x(period.lowerBound), height: size.height)
                    var hatch = context; hatch.clip(to: Path(rect))
                    var path = Path()
                    for dx in stride(from: rect.minX - size.height, to: rect.maxX, by: 6) {
                        path.move(to: CGPoint(x: dx, y: size.height)); path.addLine(to: CGPoint(x: dx + size.height, y: 0))
                    }
                    hatch.stroke(path, with: .color(Design.secondary.opacity(0.18)), lineWidth: 0.7)
                }
                var grid = Path()
                for fraction: CGFloat in [0, 0.5, 1] {
                    let xx = min(size.width - 0.5, size.width * fraction)
                    grid.move(to: CGPoint(x: xx, y: 0)); grid.addLine(to: CGPoint(x: xx, y: size.height))
                }
                context.stroke(grid, with: .color(Design.separator), lineWidth: 0.5)
                var low = Path(); low.move(to: CGPoint(x: 0, y: y(20))); low.addLine(to: CGPoint(x: size.width, y: y(20)))
                context.stroke(low, with: .color(Design.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                var base = Path(); base.move(to: CGPoint(x: 0, y: size.height - 0.5)); base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                context.stroke(base, with: .color(Design.separator), lineWidth: 0.7)
                let last = segments.last?.last
                for segment in segments {
                    guard let first = segment.first, let end = segment.last else { continue }
                    var path = Path(); path.move(to: CGPoint(x: x(first.sampledAt), y: y(first.percent)))
                    for record in segment.dropFirst() { path.addLine(to: CGPoint(x: x(record.sampledAt), y: y(record.percent))) }
                    if segment.count > 1 {
                        var area = path
                        area.addLine(to: CGPoint(x: x(end.sampledAt), y: size.height)); area.addLine(to: CGPoint(x: x(first.sampledAt), y: size.height)); area.closeSubpath()
                        context.fill(area, with: .color(Design.gray.opacity(Design.mutedFill)))
                        context.stroke(path, with: .color(Design.gray), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                    }
                    for record in segment where segment.count == 1 || record == last || record.sampledAt == selected {
                        let cx = min(size.width - 1.6, max(1.6, x(record.sampledAt)))
                        context.fill(Path(ellipseIn: CGRect(x: cx - 1.6, y: y(record.percent) - 1.6, width: 3.2, height: 3.2)), with: .color(Design.gray))
                    }
                }
                if state.chartHoverKind == "battery", let date = selected ?? state.batteryHoverDate {
                    var line = Path(); line.move(to: CGPoint(x: x(date), y: 0)); line.addLine(to: CGPoint(x: x(date), y: size.height))
                    context.stroke(line, with: .color(Design.secondary), lineWidth: 0.8)
                }
            }.contentShape(Rectangle())
                .accessibilityLabel("近 24 小时电量")
                .preference(key: PanelInteractionFrameKey.self, value: ["graph.battery": proxy.frame(in: .named(PanelInteractionFrameKey.space))])
                .background { if !previewMaterial { TrendMouseSurface(kind: "battery") { location in
                    if let location {
                        let fraction = min(1, max(0, location.x / max(1, proxy.size.width)))
                        state.batteryHoverDate = domain.lowerBound.addingTimeInterval(fraction * BatteryHistory.retention)
                        state.chartHoverKind = "battery"; state.chartHoverDate = nil
                    } else if state.chartHoverKind == "battery" { state.batteryHoverDate = nil; state.chartHoverKind = nil }
                } } }
                .overlay(alignment: .topLeading) {
                    if state.chartHoverKind == "battery", let date = state.batteryHoverDate {
                        let shown = state.batteryHoverRecord?.sampledAt ?? date
                        let fraction = shown.timeIntervalSince(domain.lowerBound) / BatteryHistory.retention
                        let lines = state.batteryHoverText
                        VStack(alignment: .leading, spacing: Design.tightGap) {
                            Text(DisplayDate.format(shown, pattern: "HH:mm:ss")).font(Design.tiny).foregroundStyle(Design.secondary)
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, text in Text(text).font(Design.caption).monospacedDigit().fixedSize() }
                        }.frame(width: 180, alignment: .leading).padding(Design.rowGap)
                            .background(Design.background, in: RoundedRectangle(cornerRadius: Design.gap))
                            .overlay(RoundedRectangle(cornerRadius: Design.gap).stroke(Design.separator, lineWidth: 0.5))
                            .offset(x: min(max(0, proxy.size.width * fraction - 98), max(0, proxy.size.width - 196)), y: -CGFloat(lines.count * 15 + 34))
                            .allowsHitTesting(false).accessibilityElement(children: .combine)
                    }
                }
        }.frame(height: height)
    }

}
