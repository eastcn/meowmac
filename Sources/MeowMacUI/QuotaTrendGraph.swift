import SwiftUI
import MeowMacCore

struct QuotaCycleGraph: View {
    let cycle: QuotaCycleDisplay
    let color: Color
    let now: Date
    @State private var hoverDate: Date?

    private var sample: QuotaHistoryLine? {
        hoverDate.flatMap { QuotaHistorySeries.hoverSample(cycle.points, at: $0, now: now) }
    }
    private var detail: String {
        guard let hoverDate else { return "匀速用完的节奏：曲线在虚线上方就是用得偏快" }
        guard let sample else {
            return DisplayDate.format(hoverDate, pattern: "M/d HH:mm") + (hoverDate > now ? " · 尚未发生" : " · 无记录")
        }
        return DisplayDate.format(sample.sampledAt, pattern: "M/d HH:mm") + String(format: " · 已用 %.1f%%（采样值）", sample.usedPercent)
    }
    var body: some View {
        HStack {
            Text("\(cycle.window.displayName) · 从重置到重置，累计已用")
            Spacer(minLength: 0)
            Text("已用 \(Int(cycle.window.usedPercent.rounded()))%")
        }.font(Design.caption).foregroundStyle(Design.secondary)
        GeometryReader { proxy in
            MiniLineGraph(points: cycle.points.map { GraphValue(date: $0.sampledAt, value: $0.usedPercent) },
                domain: cycle.start...cycle.reset, range: 0...100, color: color, fill: true,
                fillOpacity: Design.quotaCurveFill, pace: true, now: now, height: Design.cycleHeight)
                .overlay {
                    if let date = sample?.sampledAt ?? hoverDate {
                        let x = proxy.size.width * date.timeIntervalSince(cycle.start) / max(1, cycle.reset.timeIntervalSince(cycle.start))
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        }.stroke(Design.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        if let sample {
                            Circle().fill(color).frame(width: 6, height: 6)
                                .position(x: x, y: proxy.size.height * (1 - min(100, max(0, sample.usedPercent)) / 100))
                        }
                    }
                }
                .background(TrendMouseSurface(kind: "quota.cycle." + cycle.window.identifier) { location in
                    hoverDate = location.map {
                        cycle.start.addingTimeInterval(min(1, max(0, $0.x / max(1, proxy.size.width))) * cycle.reset.timeIntervalSince(cycle.start))
                    }
                })
        }.frame(height: Design.cycleHeight)
        HStack {
            Text(DisplayDate.format(cycle.start, pattern: "M/d") + " 重置")
            Spacer(); Text("现在"); Spacer()
            Text(DisplayDate.format(cycle.reset, pattern: "M/d") + " 重置")
        }.font(Design.tiny).foregroundStyle(Design.secondary)
        Text(detail).font(Design.tiny).monospacedDigit().foregroundStyle(hoverDate == nil ? Design.secondary : Design.label)
            .accessibilityLabel(detail)
    }
}

struct QuotaPeakGraph: View {
    let peaks: [QuotaPeak]
    let color: Color
    let now: Date
    @State private var hoverIndex: Int?
    private var selected: QuotaPeak? {
        hoverIndex.flatMap { peaks.indices.contains($0) ? peaks[$0] : nil }
    }
    private var detail: String {
        guard let selected else { return peaks.isEmpty ? "暂无窗口记录" : "实色：超过 80% · 浅色：进行中" }
        return DisplayDate.format(selected.resetsAt.addingTimeInterval(-5 * 3600), pattern: "M/d HH:mm")
            + "–" + DisplayDate.format(selected.resetsAt, pattern: "M/d HH:mm")
            + String(format: " · 最高 %.1f%%", selected.usedPercent) + (selected.isCurrent ? " · 进行中" : "")
    }
    var body: some View {
        Text("5 小时窗口 · 每个窗口的最高已用").font(Design.caption).foregroundStyle(Design.secondary)
        GeometryReader { proxy in
            MiniColumns(values: peaks.map(\.usedPercent), colors: peaks.enumerated().map { index, peak in
                color.opacity(index == hoverIndex ? 1 : QuotaPalette.peakOpacity(usedPercent: peak.usedPercent, isCurrent: peak.isCurrent))
            }, maximum: 100)
                .background(TrendMouseSurface(kind: "quota.peaks") { location in
                    guard let location, !peaks.isEmpty else { hoverIndex = nil; return }
                    let step = (proxy.size.width + Design.tightGap) / CGFloat(peaks.count)
                    hoverIndex = min(peaks.count - 1, max(0, Int(location.x / max(1, step))))
                })
        }.frame(height: Design.columnHeight)
        HStack {
            Text(DisplayDate.format(now.addingTimeInterval(-6 * 86400), pattern: "M/d")); Spacer()
            Text(DisplayDate.format(now.addingTimeInterval(-3 * 86400), pattern: "M/d")); Spacer(); Text("今天")
        }.font(Design.tiny).foregroundStyle(Design.secondary)
        Text(detail).font(Design.tiny).monospacedDigit().foregroundStyle(selected == nil ? Design.secondary : Design.label)
    }
}
