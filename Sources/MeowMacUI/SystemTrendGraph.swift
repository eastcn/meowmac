import SwiftUI
import MeowMacCore

struct SystemTrendRow: View {
    @ObservedObject var state: PanelState
    let trend: SystemTrend
    private var tint: Color { trend.warn ? Design.stateText(.warn) : Design.label }
    private func heading(detail: Bool) -> some View {
        HStack(spacing: Design.smallGap) {
            Circle().fill(SystemChartCard.color(trend.kind)).frame(width: Design.dot, height: Design.dot)
            if trend.secondaryPoints != nil { Circle().fill(Design.pink).frame(width: Design.dot, height: Design.dot) }
            Text(trend.name).font(Design.body).fixedSize()
            if detail { Text(trend.detail).font(Design.tiny).foregroundStyle(trend.warn ? tint : Design.secondary).fixedSize() }
            Spacer(minLength: Design.smallGap)
            Text(trend.current).font(Design.title).monospacedDigit().foregroundStyle(tint).fixedSize()
            if let secondary = trend.secondaryCurrent { Text(secondary).font(Design.tiny).foregroundStyle(Design.secondary).monospacedDigit().fixedSize() }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Design.tightGap) {
            ViewThatFits(in: .horizontal) {
                heading(detail: true)
                VStack(alignment: .leading, spacing: 0) {
                    heading(detail: false)
                    Text(trend.detail).font(Design.tiny).foregroundStyle(trend.warn ? tint : Design.secondary)
                }
            }
            SystemTrendGraph(state: state, kind: trend.kind, series: trend.segments ?? [trend.points],
                secondary: trend.secondarySegments ?? [], range: trend.lower...trend.upper,
                color: SystemChartCard.color(trend.kind), fill: trend.kind == "memory",
                missing: trend.missingPeriods ?? [], warm: state.warmPeriods, threshold: trend.threshold,
                tooltip: state.systemHoverText(trend))
        }.contentShape(Rectangle()).help(trend.help)
    }
}

public extension PanelState {
    func systemHoverText(_ trend: SystemTrend) -> [String] {
        guard let point = chartHoverPoint else { return ["无记录"] }
        func number(_ value: Double?, _ format: String) -> String {
            guard let value, value.isFinite else { return "不可用" }
            return String(format: format, value)
        }
        switch trend.kind {
        case "cpu": return ["CPU " + number(point.cpuUsage.map { $0 * 100 }, "%.1f%%")]
        case "memory": return ["内存已用 " + number(point.memoryUsedBytes.map { Double($0) / 1_073_741_824 }, "%.1f GB")]
        case "power": return ["整机功耗 " + number(point.systemPowerWatts, "%.1f W")]
        case "temperature": return ["SoC " + number(point.socTemperatureCelsius, "%.1f °C"), "电池 " + number(point.batteryTemperatureCelsius, "%.1f °C")]
        case "fan": return ["风扇 " + number(point.fanRPM, "%.0f rpm")]
        default: return []
        }
    }
}

/// 仅用于系统页，额度图的连续累计曲线沿用原组件。
struct SystemTrendGraph: View {
    @Environment(\.previewMaterial) private var previewMaterial
    @ObservedObject var state: PanelState
    let kind: String
    let series: [[TrendValue]]
    var secondary: [[TrendValue]] = []
    let range: ClosedRange<Double>
    let color: Color
    var fill = false
    var missing: [ClosedRange<Date>] = []
    var warm: [ClosedRange<Date>] = []
    var threshold: Double?
    var height: CGFloat = 18
    let tooltip: [String]

    var body: some View {
        GeometryReader { proxy in
            let selectedDate = state.chartHoverPoint?.timestamp
            Canvas { context, size in
                let domain = state.trendDomain
                func x(_ date: Date) -> CGFloat { size.width * date.timeIntervalSince(domain.lowerBound) / max(1, domain.upperBound.timeIntervalSince(domain.lowerBound)) }
                func y(_ value: Double) -> CGFloat { size.height - 1 - (size.height - 2) * min(1, max(0, (value - range.lowerBound) / max(0.001, range.upperBound - range.lowerBound))) }
                for period in warm {
                    context.fill(Path(CGRect(x: x(period.lowerBound), y: 0, width: x(period.upperBound) - x(period.lowerBound), height: size.height)), with: .color(Design.orange.opacity(Design.thermalFill)))
                }
                for period in missing {
                    let rect = CGRect(x: x(period.lowerBound), y: 0, width: x(period.upperBound) - x(period.lowerBound), height: size.height)
                    var hatch = context; hatch.clip(to: Path(rect))
                    var path = Path()
                    for dx in stride(from: rect.minX - size.height, to: rect.maxX, by: 6) {
                        path.move(to: CGPoint(x: dx, y: size.height)); path.addLine(to: CGPoint(x: dx + size.height, y: 0))
                    }
                    hatch.stroke(path, with: .color(Design.secondary.opacity(0.18)), lineWidth: 0.6)
                }
                var grid = Path()
                for fraction: CGFloat in [0, 0.5, 1] {
                    let xx = min(size.width - 0.5, size.width * fraction)
                    grid.move(to: CGPoint(x: xx, y: 0)); grid.addLine(to: CGPoint(x: xx, y: size.height))
                }
                grid.move(to: CGPoint(x: 0, y: size.height - 0.5)); grid.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                context.stroke(grid, with: .color(Design.separator), lineWidth: 0.5)
                if let threshold {
                    var path = Path(); path.move(to: CGPoint(x: 0, y: y(threshold))); path.addLine(to: CGPoint(x: size.width, y: y(threshold)))
                    context.stroke(path, with: .color(Design.secondary), style: StrokeStyle(lineWidth: 0.7, dash: [3, 3]))
                }
                func draw(_ runs: [[TrendValue]], _ tint: Color, _ area: Bool) {
                    for run in runs {
                        guard let first = run.first, let last = run.last else { continue }
                        var path = Path(); path.move(to: CGPoint(x: x(first.date), y: y(first.value)))
                        for sample in run.dropFirst() { path.addLine(to: CGPoint(x: x(sample.date), y: y(sample.value))) }
                        if area, run.count > 1 {
                            var shape = path; shape.addLine(to: CGPoint(x: x(last.date), y: size.height)); shape.addLine(to: CGPoint(x: x(first.date), y: size.height)); shape.closeSubpath()
                            context.fill(shape, with: .color(tint.opacity(Design.mutedFill)))
                        }
                        context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                        for sample in run where run.count == 1 || sample.date == selectedDate || sample.date == series.last?.last?.date {
                            context.fill(Path(ellipseIn: CGRect(x: min(size.width - 1.5, max(1.5, x(sample.date))) - 1.5, y: y(sample.value) - 1.5, width: 3, height: 3)), with: .color(tint))
                        }
                    }
                }
                draw(series, color, fill); draw(secondary, Design.pink, false)
                if let date = state.chartCursorDate {
                    var line = Path(); line.move(to: CGPoint(x: x(date), y: 0)); line.addLine(to: CGPoint(x: x(date), y: size.height))
                    context.stroke(line, with: .color(Design.secondary), lineWidth: 0.8)
                }
            }.contentShape(Rectangle())
                .preference(key: PanelInteractionFrameKey.self, value: ["graph." + kind: proxy.frame(in: .named(PanelInteractionFrameKey.space))])
                .background { if !previewMaterial { TrendMouseSurface(kind: kind) { location in
                    if let location {
                        let fraction = min(1, max(0, location.x / max(1, proxy.size.width)))
                        state.chartHoverDate = state.trendDomain.lowerBound.addingTimeInterval(fraction * state.trendDomain.upperBound.timeIntervalSince(state.trendDomain.lowerBound))
                        state.chartHoverKind = kind
                    } else if state.chartHoverKind == kind { state.chartHoverDate = nil; state.chartHoverKind = nil }
                } } }
                .overlay(alignment: .topLeading) {
                    if state.chartHoverKind == kind, let date = state.chartCursorDate {
                        let fraction = date.timeIntervalSince(state.trendDomain.lowerBound) / max(1, state.trendDomain.upperBound.timeIntervalSince(state.trendDomain.lowerBound))
                        VStack(alignment: .leading, spacing: Design.tightGap) {
                            Text(DisplayDate.format(date, pattern: "HH:mm:ss")).font(Design.tiny).foregroundStyle(Design.secondary)
                            ForEach(Array(tooltip.enumerated()), id: \.offset) { _, text in Text(text).font(Design.caption).monospacedDigit().fixedSize() }
                        }.frame(width: 180, alignment: .leading).padding(Design.rowGap)
                            .background(Design.background, in: RoundedRectangle(cornerRadius: Design.gap))
                            .overlay(RoundedRectangle(cornerRadius: Design.gap).stroke(Design.separator, lineWidth: 0.5))
                            .offset(x: min(max(0, proxy.size.width * fraction - 98), max(0, proxy.size.width - 196)),
                                    y: kind == "cpu" || kind == "memory" ? height + 4 : -CGFloat(tooltip.count * 15 + 34))
                            .allowsHitTesting(false).accessibilityElement(children: .combine)
                    }
                }
        }.frame(height: height)
    }
}

/// 使用原生 tracking area，弹出面板未成为键盘焦点时也能查看历史。
struct TrendMouseSurface: NSViewRepresentable {
    let kind: String
    let moved: (CGPoint?) -> Void
    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView(); view.identifier = NSUserInterfaceItemIdentifier("trend." + kind); view.moved = moved
        return view
    }
    func updateNSView(_ view: TrackingView, context: Context) { view.moved = moved }
    final class TrackingView: NSView {
        var moved: ((CGPoint?) -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
        override func mouseMoved(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            moved?(bounds.contains(point) ? point : nil)
        }
        override func mouseExited(with event: NSEvent) { moved?(nil) }
    }
}
