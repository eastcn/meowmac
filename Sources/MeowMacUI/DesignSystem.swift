import AppKit
import SwiftUI
import MeowMacCore

/// 数值来自 SPEC 和终稿画板。页面只组合这些语义组件。
enum Design {
    static let panelWidth: CGFloat = 360, panelHeight: CGFloat = 820
    static let inset: CGFloat = 16, sectionGap: CGFloat = 12, metricGap: CGFloat = 14
    static let gap: CGFloat = 6, smallGap: CGFloat = 3, rowGap: CGFloat = 8, tightGap: CGFloat = 2
    static let cardRadius: CGFloat = 12, cardInset: CGFloat = 12, cardVertical: CGFloat = 10
    static let rule: CGFloat = 1, miniBar: CGFloat = 3, bar: CGFloat = 6, barRadius: CGFloat = 3
    static let tickWidth: CGFloat = 2, tickHeight: CGFloat = 12
    static let trendLabelWidth: CGFloat = 104, trendValueWidth: CGFloat = 74, trendRowHeight: CGFloat = 32
    static let dot: CGFloat = 6, checkDot: CGFloat = 7, legendDot: CGFloat = 8
    static let tabHeight: CGFloat = 28, tabPadding: CGFloat = 3
    static let trendHeight: CGFloat = 26, cycleHeight: CGFloat = 56, columnHeight: CGFloat = 40
    static let tableRow: CGFloat = 21, tableHeader: CGFloat = 16, rankWidth: CGFloat = 18
    static let numericColumn: CGFloat = 56, siteCountColumn: CGFloat = 64, siteLatencyColumn: CGFloat = 88
    static let providerHeight: CGFloat = 72
    static let providerIcon: CGFloat = 20, networkIcon: CGFloat = 32
    // 网络页（2026-10-04 重新设计，见 mockups/network-redesign.html）。
    static let verdictIcon: CGFloat = 28, badge: CGFloat = 14, groupRadius: CGFloat = 10, checkRowInset: CGFloat = 7
    static let networkLabelWidth: CGFloat = 88, networkValueWidth: CGFloat = 72, networkChartHeight: CGFloat = 24
    static let siteRowHeight: CGFloat = 32, trafficRowHeight: CGFloat = 24, egressStrip: CGFloat = 6, networkStroke: CGFloat = 1.4
    static let catWidth: CGFloat = 26, catHeight: CGFloat = 17
    static let headerTop: CGFloat = 14, footerInset: CGFloat = 10
    static let menuWidth: CGFloat = 260, menuRow: CGFloat = 26
    static let graphStroke: CGFloat = 1.6, graphDot: CGFloat = 2.6
    static let mutedFill: Double = 0.12, thermalFill: Double = 0.16
    static let quotaCurveFill: Double = 0.15, quotaPeakFill: Double = 0.55
    static let peakFill: Double = 0.6, currentPeakFill: Double = 0.28, costFill: Double = 0.35
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let status = Font.system(size: 15, weight: .semibold)
    static let metric = Font.system(size: 20, weight: .semibold)
    static let amount = Font.system(size: 20, weight: .semibold)
    static let button = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let checkName = Font.system(size: 12.5, weight: .semibold)
    static let ip = Font.system(size: 12, weight: .semibold)
    static let tiny = Font.system(size: 10)
    static let iconInk = Color(nsColor: .white)
    static let label = Color(nsColor: .labelColor), secondary = Color(nsColor: .secondaryLabelColor)
    static let separator = Color(nsColor: .separatorColor), track = Color(nsColor: .quaternarySystemFill)
    static let blue = Color(nsColor: .systemBlue), purple = Color(nsColor: .systemPurple)
    static let teal = Color(nsColor: .systemTeal), pink = Color(nsColor: .systemPink)
    static let orange = Color(nsColor: .systemOrange), red = Color(nsColor: .systemRed)
    static let gray = Color(nsColor: .systemGray)
    static let indigo = Color(nsColor: .systemIndigo), brown = Color(nsColor: .systemBrown)
    static let selection = Color(nsColor: .controlBackgroundColor)
    static let background = Color(nsColor: .windowBackgroundColor)
    static func provider(_ provider: QuotaProvider, style: StyleSettings = .default) -> Color { Color(nsColor: QuotaPalette.color(provider, style: style)) }
    static func state(_ level: HealthLevel) -> Color {
        switch level { case .normal: return Color(nsColor: .systemGreen); case .warn: return orange; case .severe: return red }
    }
    static func stateText(_ level: HealthLevel) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                switch level { case .normal: return .systemGreen; case .warn: return .systemOrange; case .severe: return .systemRed }
            }
            switch level {
            case .normal: return NSColor(srgbRed: 30 / 255, green: 142 / 255, blue: 62 / 255, alpha: 1)
            case .warn: return NSColor(srgbRed: 178 / 255, green: 80 / 255, blue: 0, alpha: 1)
            case .severe: return NSColor(srgbRed: 215 / 255, green: 0, blue: 21 / 255, alpha: 1)
            }
        })
    }
    static func quotaLevel(_ remaining: Double) -> HealthLevel { remaining >= 50 ? .normal : remaining >= 20 ? .warn : .severe }
    static func networkColor(_ tone: NetworkTone) -> Color {
        switch tone { case .green: return state(.normal); case .yellow: return orange; case .red: return red; case .gray: return gray }
    }
}

private struct PreviewMaterialKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var previewMaterial: Bool {
        get { self[PreviewMaterialKey.self] }
        set { self[PreviewMaterialKey.self] = newValue }
    }
}

/// 三个标签页、总览和底栏共用一个表面；原生玻璃由 NSPopover 提供。
struct PanelSurface: View {
    @Environment(\.previewMaterial) private var previewMaterial
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Group {
            if previewMaterial { Design.background }
            else if #available(macOS 26, *) { Color.clear }
            else { Rectangle().fill(.regularMaterial) }
        }.overlay {
            if colorScheme == .light {
                // 保留底层玻璃透色，顶部淡蓝灰，底部暖杏色。
                LinearGradient(stops: [
                    .init(color: Color(red: 199 / 255, green: 217 / 255, blue: 237 / 255).opacity(0.26), location: 0),
                    .init(color: Color.white.opacity(0.04), location: 0.45),
                    .init(color: Color(red: 255 / 255, green: 216 / 255, blue: 184 / 255).opacity(0.32), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }.allowsHitTesting(false)
    }
}

struct GlassSurface: ViewModifier {
    @Environment(\.previewMaterial) private var previewMaterial
    var warning = false
    func body(content: Content) -> some View {
        if previewMaterial {
            content.background(warning ? Design.orange.opacity(0.1) : Design.track, in: RoundedRectangle(cornerRadius: Design.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Design.cardRadius).stroke(warning ? Design.orange.opacity(0.3) : Design.separator, lineWidth: Design.rule))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(warning ? Design.orange.opacity(Design.mutedFill) : nil), in: RoundedRectangle(cornerRadius: Design.cardRadius))
        } else if warning {
            content.background(Design.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Design.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Design.cardRadius).stroke(Design.orange.opacity(0.3), lineWidth: Design.rule))
        } else {
            content.background(.thinMaterial, in: RoundedRectangle(cornerRadius: Design.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Design.cardRadius).stroke(.white.opacity(0.6), lineWidth: Design.rule))
        }
    }
}

struct GlassCard<Content: View>: View {
    var warning = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Design.cardInset).padding(.vertical, Design.cardVertical)
            .modifier(GlassSurface(warning: warning))
    }
}

struct CapsuleAction: View {
    @Environment(\.previewMaterial) private var previewMaterial
    let title: String
    var symbol: String? = nil
    var action: () -> Void
    private var label: some View {
        HStack(spacing: Design.smallGap) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }.font(Design.button)
    }
    var body: some View {
        if previewMaterial {
            Button(action: action) { label.padding(.horizontal, Design.footerInset).padding(.vertical, Design.smallGap).background(Design.track, in: Capsule()).overlay(Capsule().stroke(Design.separator, lineWidth: Design.rule)) }.buttonStyle(.plain)
        } else if #available(macOS 26, *) {
            Button(action: action) { label }.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.small)
        } else {
            Button(action: action) { label }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
        }
    }
}

struct LinkAction: View {
    let title: String
    let action: () -> Void
    var body: some View { Button(title, action: action).buttonStyle(.plain).font(Design.button).foregroundStyle(Design.blue) }
}

private struct CapsuleSurface: ViewModifier {
    var selected: Bool
    func body(content: Content) -> some View {
        content.background(selected ? Design.label.opacity(Design.mutedFill) : .clear, in: Capsule())
            .background(selected ? Design.selection : .clear, in: Capsule())
            .shadow(color: .black.opacity(selected ? Design.mutedFill : 0), radius: Design.smallGap, y: Design.rule)
    }
}

private struct CapsuleTrack: ViewModifier {
    @Environment(\.previewMaterial) private var previewMaterial
    func body(content: Content) -> some View {
        if previewMaterial { content.background(Design.track, in: Capsule()) }
        else if #available(macOS 26, *) { content.glassEffect(.regular, in: Capsule()) }
        else { content.background(Design.track, in: Capsule()) }
    }
}

struct CapsuleSelector: View {
    let titles: [String]
    let selected: Int
    var levels: [HealthLevel]? = nil
    var compact = false
    let action: (Int) -> Void
    var body: some View {
        HStack(spacing: Design.tightGap) {
            ForEach(titles.indices, id: \.self) { index in
                Button { action(index) } label: {
                    HStack(spacing: Design.gap) {
                        if let levels { Circle().fill(Design.state(levels[index])).frame(width: Design.dot, height: Design.dot) }
                        Text(titles[index]).font(compact ? Design.caption : Design.body).fontWeight(selected == index ? .semibold : .regular)
                    }
                    .frame(maxWidth: compact ? nil : .infinity)
                    .padding(.horizontal, compact ? Design.footerInset : 0)
                    .frame(height: compact ? Design.tableRow : Design.tabHeight)
                    .modifier(CapsuleSurface(selected: selected == index))
                    .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(Design.tabPadding).modifier(CapsuleTrack())
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String = ""
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Design.title)
            Spacer(minLength: Design.gap)
            Text(detail).font(Design.caption).foregroundStyle(Design.secondary)
        }
    }
}

struct SectionRule: View {
    var body: some View { Rectangle().fill(Design.separator).frame(height: Design.rule) }
}

struct LineBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = Design.bar
    var marker: Double? = nil
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Design.barRadius).fill(Design.track)
                RoundedRectangle(cornerRadius: Design.barRadius).fill(color).frame(width: proxy.size.width * min(1, max(0, fraction)))
                if let marker {
                    RoundedRectangle(cornerRadius: Design.rule).fill(Design.red)
                        .overlay(RoundedRectangle(cornerRadius: Design.rule).stroke(Design.background, lineWidth: Design.rule))
                        .frame(width: Design.tickWidth, height: Design.tickHeight)
                        .offset(x: min(proxy.size.width - Design.tickWidth, max(0, proxy.size.width * marker - Design.rule)))
                }
            }.frame(height: height)
        }.frame(height: height)
    }
}

struct FlatMetric: View {
    let title: String, value: String, detail: String
    let fraction: Double
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: Design.tightGap) {
            Text(title).font(Design.caption).foregroundStyle(Design.secondary)
            Text(value).font(Design.metric).monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            Text(detail).font(Design.tiny).foregroundStyle(Design.secondary).lineLimit(1)
            LineBar(fraction: fraction, color: color, height: Design.miniBar).padding(.top, Design.smallGap)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SegmentedLine: View {
    let values: [Double]
    let colors: [Color]
    var body: some View {
        GeometryReader { proxy in
            let total = max(1, values.reduce(0, +))
            let width = max(0, proxy.size.width - CGFloat(max(0, values.count - 1)) * Design.tightGap)
            HStack(spacing: Design.tightGap) {
                ForEach(values.indices, id: \.self) { index in
                    Rectangle().fill(colors[index]).frame(width: width * values[index] / total)
                }
            }.clipShape(RoundedRectangle(cornerRadius: Design.barRadius))
        }.frame(height: Design.bar)
    }
}

struct GraphValue {
    let date: Date
    let value: Double
}

struct MiniLineGraph: View {
    let points: [GraphValue]
    let domain: ClosedRange<Date>
    let range: ClosedRange<Double>
    let color: Color
    var fill = false
    var fillOpacity = Design.mutedFill
    var warmPeriods: [ClosedRange<Date>] = []
    var pace = false
    var now: Date? = nil
    var height = Design.trendHeight
    /// 叠加在同一量程里的其他折线。
    var overlay: [([GraphValue], Color)] = []
    /// 虚线阈值。
    var threshold: Double? = nil
    var body: some View {
        Canvas { context, size in
            let duration = max(1, domain.upperBound.timeIntervalSince(domain.lowerBound))
            func x(_ date: Date) -> CGFloat { size.width * min(1, max(0, date.timeIntervalSince(domain.lowerBound) / duration)) }
            func y(_ value: Double) -> CGFloat { size.height * (1 - min(1, max(0, (value - range.lowerBound) / max(1, range.upperBound - range.lowerBound)))) }
            for period in warmPeriods {
                let rect = CGRect(x: x(period.lowerBound), y: 0, width: max(0, x(period.upperBound) - x(period.lowerBound)), height: size.height)
                context.fill(Path(rect), with: .color(Design.orange.opacity(Design.thermalFill)))
            }
            var base = Path(); base.move(to: CGPoint(x: 0, y: size.height - Design.rule / 2)); base.addLine(to: CGPoint(x: size.width, y: size.height - Design.rule / 2))
            context.stroke(base, with: .color(Design.separator), lineWidth: Design.rule)
            if pace {
                var guide = Path(); guide.move(to: CGPoint(x: 0, y: size.height)); guide.addLine(to: CGPoint(x: size.width, y: 0))
                context.stroke(guide, with: .color(Design.red.opacity(Design.peakFill)), style: StrokeStyle(lineWidth: Design.rule, dash: [Design.smallGap, Design.smallGap]))
            }
            if let threshold {
                var guide = Path(); guide.move(to: CGPoint(x: 0, y: y(threshold))); guide.addLine(to: CGPoint(x: size.width, y: y(threshold)))
                context.stroke(guide, with: .color(Design.secondary.opacity(Design.peakFill)), style: StrokeStyle(lineWidth: Design.rule, dash: [Design.smallGap, Design.smallGap]))
            }
            for (values, lineColor) in overlay {
                let visible = values.filter { domain.contains($0.date) }
                guard let first = visible.first else { continue }
                var path = Path(); path.move(to: CGPoint(x: x(first.date), y: y(first.value)))
                for point in visible.dropFirst() { path.addLine(to: CGPoint(x: x(point.date), y: y(point.value))) }
                context.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: Design.graphStroke, lineJoin: .round))
            }
            let visible = points.filter { domain.contains($0.date) }
            if let first = visible.first {
                var path = Path(); path.move(to: CGPoint(x: x(first.date), y: y(first.value)))
                for point in visible.dropFirst() { path.addLine(to: CGPoint(x: x(point.date), y: y(point.value))) }
                if fill, let last = visible.last {
                    var area = path; area.addLine(to: CGPoint(x: x(last.date), y: size.height)); area.addLine(to: CGPoint(x: x(first.date), y: size.height)); area.closeSubpath()
                    context.fill(area, with: .color(color.opacity(fillOpacity)))
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: Design.graphStroke, lineJoin: .round))
                if pace, let last = visible.last {
                    let radius = Design.graphDot
                    context.fill(Path(ellipseIn: CGRect(x: x(last.date) - radius, y: y(last.value) - radius, width: radius * 2, height: radius * 2)), with: .color(color))
                }
            }
            if let now {
                var line = Path(); line.move(to: CGPoint(x: x(now), y: 0)); line.addLine(to: CGPoint(x: x(now), y: size.height))
                context.stroke(line, with: .color(Design.secondary.opacity(Design.costFill)), lineWidth: Design.rule)
            }
        }.frame(height: height)
    }
}

struct MiniColumns: View {
    let values: [Double]
    var colors: [Color] = []
    var maximum: Double? = nil
    var action: ((Int) -> Void)? = nil
    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(1, maximum ?? values.max() ?? 1)
            HStack(alignment: .bottom, spacing: Design.tightGap) {
                ForEach(values.indices, id: \.self) { index in
                    let column = RoundedRectangle(cornerRadius: Design.tightGap)
                        .fill(colors.indices.contains(index) ? colors[index] : Design.blue.opacity(Design.costFill))
                        .frame(maxWidth: .infinity).frame(height: max(Design.rule, proxy.size.height * values[index] / maxValue))
                    if let action {
                        Button { action(index) } label: {
                            column.frame(maxWidth: .infinity).frame(height: proxy.size.height, alignment: .bottom)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    } else { column }
                }
            }.frame(height: proxy.size.height, alignment: .bottom)
        }.frame(height: Design.columnHeight)
    }
}

struct DesignComponentPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            SectionHeading(title: "MeowMac 设计组件", detail: "合成数据")
            HStack(spacing: Design.metricGap) {
                FlatMetric(title: "CPU", value: "24%", detail: "整机负载", fraction: 0.24, color: Design.blue)
                FlatMetric(title: "内存", value: "69%", detail: "11 / 16 GB", fraction: 0.69, color: Design.state(.normal))
                FlatMetric(title: "Claude", value: "72%", detail: "5 小时 · 剩余", fraction: 0.72, color: Design.state(.normal))
                FlatMetric(title: "网络", value: "↓2.4M", detail: "↑128.0K", fraction: 1, color: Design.state(.normal))
            }
            CapsuleSelector(titles: ["系统", "额度", "网络"], selected: 0, levels: [.normal, .warn, .severe]) { _ in }
            GlassCard(warning: true) { VStack(alignment: .leading, spacing: Design.gap) { SectionHeading(title: "能耗诊断", detail: "1 项"); Text("示例进程 · 已持续 35 分钟").font(Design.body); Text("建议用 AI 诊断").font(Design.caption).foregroundStyle(Design.stateText(.warn)) } }
            LineBar(fraction: 0.3, color: Design.orange, marker: 0.49)
            SegmentedLine(values: [6.3, 2.1, 0.7], colors: [Design.blue, Design.teal, Design.purple])
            SectionRule()
            HStack { CapsuleAction(title: "刷新", symbol: "arrow.clockwise") {}; Spacer(); LinkAction(title: "在访达中显示 ↗") {} }
            MiniColumns(values: [30, 80, 60, 95, 40], colors: [Design.blue, Design.orange, Design.blue, Design.orange, Design.blue])
        }.padding(Design.inset).frame(width: Design.panelWidth).foregroundStyle(Design.label)
    }
}

/// 额度页的渠道色。状态色由 Design 单独提供。
public enum QuotaPalette {
    public static func color(_ provider: QuotaProvider, style: StyleSettings = .default) -> NSColor {
        if let pair = style.color(for: provider).hexPair {
            return NSColor(name: nil) { appearance in
                let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.dark : pair.light
                let value = Int(hex.dropFirst(), radix: 16)!
                return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                               green: CGFloat((value >> 8) & 255) / 255,
                               blue: CGFloat(value & 255) / 255, alpha: 1)
            }
        }
        switch provider {
        case .codex: return .labelColor
        case .claude: return NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
        case .deepseek: return NSColor(srgbRed: 77 / 255, green: 107 / 255, blue: 254 / 255, alpha: 1)
        case .opencodego: return .systemGray
        }
    }
    public static func peakOpacity(usedPercent: Double, isCurrent: Bool) -> Double {
        isCurrent ? Design.currentPeakFill : usedPercent > 80 ? 1 : Design.quotaPeakFill
    }
}
