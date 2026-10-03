import AppKit
import SwiftUI
import MeowMacCore

public struct QuotaWindowDisplay: Codable {
    public let window: QuotaWindow
    public let remainingPercent: Double
    public let windowMinutes: Int?
    public let name: String
    public let pace: QuotaPace?
    public let level: HealthLevel
    public let resetText: String?
    public let paceText: String?
}
public struct CostDisplay: Codable {
    public let todayCost: Double, weekCost: Double, totalCost: Double
    public let todayTokens: Int?, weekTokens: Int?, totalTokens: Int?
    public let mostUsedModel: String?
    public let days: [DailyCost]
}
public struct CostDayDisplay: Codable {
    public let date: String
    public let totalCost: Double
    public let totalTokens: Int?
    public let mostUsedModel: String?
    public let hasData: Bool
    public var detailText: String {
        let parts = date.split(separator: "-")
        let day = parts.count == 3 ? "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)" : date
        guard hasData else { return day + " · 无花费" }
        var fields = [day, String(format: "$%.2f", totalCost)]
        if let totalTokens { fields.append(CostTokenFormat.text(totalTokens)) }
        if let mostUsedModel { fields.append(mostUsedModel) }
        return fields.joined(separator: " · ")
    }
}
private enum CostTokenFormat {
    static func text(_ count: Int) -> String {
        if count < 1_000 { return "\(count) tokens" }
        return count >= 1_000_000 ? String(format: "%.1fM tokens", Double(count) / 1_000_000) : String(format: "%.0fK tokens", Double(count) / 1000)
    }
}
public extension PanelState {
    func displayedWindows(_ provider: QuotaProvider) -> [QuotaWindowDisplay] {
        (quotas[provider]?.windows ?? []).map { window in
            let pace = QuotaPace.calculate(window: window, now: now())
            return QuotaWindowDisplay(window: window, remainingPercent: window.remainingPercent, windowMinutes: window.effectiveWindowMinutes, name: window.displayName, pace: pace, level: Design.quotaLevel(window.remainingPercent),
                resetText: window.resetsAt.map { DisplayDate.format($0, pattern: "M/d HH:mm") + " 重置" },
                paceText: pace.map { value in
                    if value.exhaustsBeforeReset, let seconds = value.secondsUntilExhaustion {
                        return "比节奏快 \(Int(value.aheadPercentagePoints.rounded())) 个百分点，约 \(MetricFormat.duration(seconds))后用完"
                    }
                    return "节奏正常，可以撑到重置"
                })
        }
    }
    func providerWindow(_ provider: QuotaProvider) -> QuotaWindow? { quotas[provider]?.windows.min { $0.remainingPercent < $1.remainingPercent } }
    func costDisplay(_ provider: QuotaProvider) -> CostDisplay? {
        guard [.codex, .claude].contains(provider), let all = costs[provider], !all.isEmpty else { return nil }
        let today = DisplayDate.format(now(), pattern: "yyyy-MM-dd")
        let first = DisplayDate.format(Calendar.current.date(byAdding: .day, value: -29, to: now())!, pattern: "yyyy-MM-dd")
        let days = all.filter { $0.date >= first && $0.date <= today }.sorted { $0.date < $1.date }
        let todayRows = days.filter { $0.date == today }
        let weekStart = DisplayDate.format(Calendar.current.date(byAdding: .day, value: -6, to: now())!, pattern: "yyyy-MM-dd")
        let weekRows = days.filter { $0.date >= weekStart }
        let models = Dictionary(grouping: days.flatMap(\.models), by: \.name).mapValues { $0.reduce(0) { $0 + $1.tokens } }
        return CostDisplay(todayCost: todayRows.reduce(0) { $0 + $1.totalCost }, weekCost: weekRows.reduce(0) { $0 + $1.totalCost }, totalCost: days.reduce(0) { $0 + $1.totalCost },
            todayTokens: todayRows.contains(where: { $0.totalTokens != nil }) ? todayRows.reduce(0) { $0 + ($1.totalTokens ?? 0) } : nil,
            weekTokens: weekRows.contains(where: { $0.totalTokens != nil }) ? weekRows.reduce(0) { $0 + ($1.totalTokens ?? 0) } : nil,
            totalTokens: days.contains(where: { $0.totalTokens != nil }) ? days.reduce(0) { $0 + ($1.totalTokens ?? 0) } : nil,
            mostUsedModel: models.max(by: { $0.value < $1.value })?.key, days: days)
    }
    var costChartDates: [String] {
        (-29...0).map { offset in
            DisplayDate.format(Calendar.current.date(byAdding: .day, value: offset, to: now())!, pattern: "yyyy-MM-dd")
        }
    }
    var displayedCostDate: String {
        if let selectedCostDate, costChartDates.contains(selectedCostDate) { return selectedCostDate }
        return DisplayDate.format(now(), pattern: "yyyy-MM-dd")
    }
    func costDayDisplay(_ provider: QuotaProvider, date: String) -> CostDayDisplay {
        let rows = (costDisplay(provider)?.days ?? []).filter { $0.date == date }
        let models = Dictionary(grouping: rows.flatMap(\.models), by: \.name).mapValues { $0.reduce(0) { $0 + $1.tokens } }
        return CostDayDisplay(date: date, totalCost: rows.reduce(0) { $0 + $1.totalCost },
            totalTokens: rows.contains(where: { $0.totalTokens != nil }) ? rows.reduce(0) { $0 + ($1.totalTokens ?? 0) } : nil,
            mostUsedModel: models.max(by: { $0.value < $1.value })?.key, hasData: !rows.isEmpty)
    }

}
struct ProviderLogo: View {
    let provider: QuotaProvider
    private var resourceBundle: Bundle {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("MeowMac_MeowMacUI.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }
    var body: some View {
        if let url = resourceBundle.url(forResource: "ProviderIcon-\(provider.rawValue)", withExtension: "svg", subdirectory: "Resources"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: Design.providerIcon, height: Design.providerIcon)
        }
    }
}
struct QuotaPage: View {
    @ObservedObject var state: PanelState
    private var provider: QuotaProvider { state.selectedProvider }
    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            HStack(spacing: Design.gap) {
                ForEach([QuotaProvider.claude, .codex, .deepseek, .opencodego], id: \.self) { item in
                    Button { state.selectedProvider = item } label: {
                        VStack(spacing: Design.smallGap) {
                            ProviderLogo(provider: item)
                            Text(item.displayName).font(Design.caption).fontWeight(provider == item ? .semibold : .regular).lineLimit(1).minimumScaleFactor(0.75)
                            let window = state.providerWindow(item)
                            LineBar(fraction: (window?.remainingPercent ?? 0) / 100, color: Design.provider(item), height: Design.miniBar)
                            Text(window.map { "\(Int($0.remainingPercent.rounded()))%" } ?? (state.quotaErrors[item] == nil ? "—" : "出错"))
                                .font(Design.caption).fontWeight(.semibold).foregroundStyle(window.map { Design.stateText(Design.quotaLevel($0.remainingPercent)) } ?? Design.secondary)
                        }.padding(Design.gap).frame(maxWidth: .infinity).frame(height: Design.providerHeight)
                            .modifier(GlassSurface()).overlay(RoundedRectangle(cornerRadius: Design.cardRadius).stroke(provider == item ? Design.blue.opacity(Design.peakFill) : .clear, lineWidth: Design.rule))
                            .contentShape(RoundedRectangle(cornerRadius: Design.cardRadius))
                    }.buttonStyle(.plain)
                }
            }
            if let error = state.quotaErrors[provider] {
                GlassCard(warning: true) { VStack(alignment: .leading, spacing: Design.gap) { Text("\(provider.displayName) 采集失败").font(Design.title); Text(error).font(Design.caption).foregroundStyle(Design.secondary) } }
            }
            if let quota = state.quotas[provider] {
                VStack(alignment: .leading, spacing: Design.gap) {
                    HStack {
                        Text(provider.displayName).font(Design.status)
                        if let plan = quota.planName { Text(plan).font(Design.tiny).padding(.horizontal, Design.gap).padding(.vertical, Design.tightGap).background(Design.track, in: Capsule()) }
                        Spacer(); Text(DisplayDate.format(quota.updatedAt, pattern: "HH:mm") + " 更新").font(Design.caption).foregroundStyle(Design.secondary)
                    }
                    HStack {
                        if let email = quota.accountEmail { Text(email) }; Spacer(); Text("来源 " + quota.source)
                    }.font(Design.caption).foregroundStyle(Design.secondary)
                }
                ForEach(state.displayedWindows(provider).indices, id: \.self) { index in
                    QuotaWindowView(value: state.displayedWindows(provider)[index], provider: provider)
                }
                if let credits = quota.codexResetCredits, credits.availableCount > 0 {
                    GlassCard { VStack(alignment: .leading, spacing: Design.gap) {
                        Text("可重置限额 \(credits.availableCount) 次").font(Design.title)
                        if !credits.expiresAt.isEmpty { Text(credits.expiresAt.map { DisplayDate.format($0, pattern: "M/d") + " 过期" }.joined(separator: " · ")).font(Design.caption).foregroundStyle(Design.secondary) }
                    } }
                }
            }
            if provider == .codex {
                SectionRule()
                CodexResetMonitorView(display: state.codexResetState.display)
            }
            let ids = state.renderedCardIDs(for: .quota)
            ForEach(ids, id: \.self) { id in
                SectionRule()
                PanelCardRegistry.cards[id]?.makeView(state: state)
            }
        }
    }
}
struct QuotaWindowView: View {
    let value: QuotaWindowDisplay
    let provider: QuotaProvider
    var body: some View {
        VStack(alignment: .leading, spacing: Design.gap) {
            HStack(alignment: .firstTextBaseline, spacing: Design.gap) {
                Text(value.window.displayName).font(Design.title); Spacer()
                Text("剩余").font(Design.caption).foregroundStyle(Design.secondary)
                Text("\(Int(value.window.remainingPercent.rounded()))%").font(Design.status).foregroundStyle(value.level == .normal ? Design.label : Design.stateText(value.level))
            }
            LineBar(fraction: value.window.remainingPercent / 100, color: Design.provider(provider), marker: value.pace?.expectedRemainingFraction)
            HStack(spacing: Design.smallGap) {
                if let pace = value.pace {
                    Rectangle().fill(Design.red).frame(width: Design.tickWidth, height: Design.legendDot)
                    Text("按节奏应剩 \(Int((pace.expectedRemainingFraction * 100).rounded()))%")
                }
                Spacer(minLength: 0)
                if let text = value.resetText { Text(text) }
            }.font(Design.tiny).foregroundStyle(Design.secondary)
            if let text = value.paceText { Text(text).font(Design.caption).foregroundStyle(value.pace?.exhaustsBeforeReset == true ? Design.stateText(.warn) : Design.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
struct QuotaTrendView: View {
    @ObservedObject var state: PanelState
    let provider: QuotaProvider
    var body: some View {
        VStack(alignment: .leading, spacing: Design.rowGap) {
            SectionHeading(title: "用量趋势", detail: "MeowMac 采样")
            ForEach(state.quotaCycles(provider), id: \.window.identifier) { cycle in
                    let window = cycle.window, reset = cycle.reset, start = cycle.start
                    let history = cycle.points
                    HStack { Text("\(window.displayName) · 从重置到重置，累计已用"); Spacer(minLength: 0); Text("已用 \(Int(window.usedPercent.rounded()))%") }.font(Design.caption).foregroundStyle(Design.secondary)
                    MiniLineGraph(points: history.map { GraphValue(date: $0.sampledAt, value: $0.usedPercent) }, domain: start...reset, range: 0...100, color: Design.provider(provider), fill: true, fillOpacity: Design.quotaCurveFill, pace: true, now: state.now(), height: Design.cycleHeight)
                    HStack { Text(DisplayDate.format(start, pattern: "M/d") + " 重置"); Spacer(); Text("现在"); Spacer(); Text(DisplayDate.format(reset, pattern: "M/d") + " 重置") }.font(Design.tiny).foregroundStyle(Design.secondary)
                    Text("匀速用完的节奏：曲线在虚线上方就是用得偏快").font(Design.tiny).foregroundStyle(Design.secondary)
            }
            if state.quotas[provider]?.windows.contains(where: { $0.effectiveWindowMinutes == 300 }) == true {
                let peaks = state.quotaPeaks(provider)
                Text("5 小时窗口 · 每个窗口的最高已用").font(Design.caption).foregroundStyle(Design.secondary)
                MiniColumns(values: peaks.map(\.usedPercent), colors: peaks.map { Design.provider(provider).opacity(QuotaPalette.peakOpacity(usedPercent: $0.usedPercent, isCurrent: $0.isCurrent)) }, maximum: 100)
                HStack { Text(DisplayDate.format(state.now().addingTimeInterval(-6 * 86400), pattern: "M/d")); Spacer(); Text(DisplayDate.format(state.now().addingTimeInterval(-3 * 86400), pattern: "M/d")); Spacer(); Text("今天") }.font(Design.tiny).foregroundStyle(Design.secondary)
                Text("实色：超过 80% · 浅色：进行中").font(Design.tiny).foregroundStyle(Design.secondary)
            }
        }
    }
}
struct CostCard: View {
    @ObservedObject var state: PanelState
    let value: CostDisplay
    let provider: QuotaProvider
    var body: some View {
        VStack(alignment: .leading, spacing: Design.rowGap) {
            SectionHeading(title: "花费", detail: "按 token 估算，不是账单")
            HStack(spacing: Design.gap) {
                ForEach([0, 1, 2], id: \.self) { index in
                    VStack(alignment: .leading, spacing: Design.smallGap) {
                        Text(["今天", "近 7 天", "近 30 天"][index]).font(Design.caption).foregroundStyle(Design.secondary)
                        Text(String(format: "$%.2f", [value.todayCost, value.weekCost, value.totalCost][index]))
                            .font(Design.amount).monospacedDigit()
                        if let count = [value.todayTokens, value.weekTokens, value.totalTokens][index] {
                            Text(CostTokenFormat.text(count)).font(Design.caption).foregroundStyle(Design.secondary).monospacedDigit()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            let dates = state.costChartDates
            let days = dates.map { state.costDayDisplay(provider, date: $0) }
            MiniColumns(values: days.map(\.totalCost), colors: days.map {
                Design.provider(provider).opacity($0.date == state.displayedCostDate ? 1 : Design.costFill)
            }, action: { state.selectCostDay(dates[$0]) })
            HStack { Text(days.first?.detailText.components(separatedBy: " · ").first ?? ""); Spacer(); Text("今天") }
                .font(Design.tiny).foregroundStyle(Design.secondary)
            Text(state.costDayDisplay(provider, date: state.displayedCostDate).detailText)
                .font(Design.caption).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            if let model = value.mostUsedModel {
                HStack(alignment: .top) { Text("最常用模型").foregroundStyle(Design.secondary); Spacer(); Text(model).fixedSize(horizontal: false, vertical: true) }.font(Design.caption)
            }
        }
    }
}
struct StorageCard: View {
    @ObservedObject var state: PanelState
    let provider: QuotaProvider, value: LocalStorageSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: Design.gap) {
            HStack { Text("本地存储").font(Design.title); Text("~/." + provider.rawValue).font(Design.caption).foregroundStyle(Design.secondary); Spacer(); Text(DisplayDate.bytes(value.totalBytes)).font(Design.title) }
            SegmentedLine(values: [Double(value.sessionsBytes), Double(value.cacheBytes), Double(value.otherBytes)], colors: [Design.blue, Design.teal, Design.purple])
            HStack(spacing: Design.rowGap) {
                ForEach(["会话", "缓存", "其他"].indices, id: \.self) { index in
                    Circle().fill([Design.blue, Design.teal, Design.purple][index]).frame(width: Design.dot, height: Design.dot)
                    Text(["会话", "缓存", "其他"][index] + " " + DisplayDate.bytes([value.sessionsBytes, value.cacheBytes, value.otherBytes][index])).font(Design.tiny).foregroundStyle(Design.secondary)
                }
            }
            HStack { Text("\(value.sessionFileCount) 个会话文件").font(Design.caption).foregroundStyle(Design.secondary); Spacer(); LinkAction(title: "在访达中显示 ↗") { state.onShowStorage(provider) } }
        }
    }
}
