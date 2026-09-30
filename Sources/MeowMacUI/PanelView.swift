import AppKit
import Charts
import SwiftUI
import MeowMacCore
import MeowMacSystem
import os
import TunCanaryUI

public protocol Card {
    var id: String { get }
    var title: String { get }
    func makeView(state: PanelState) -> AnyView
    func overviewContribution(state: PanelState) -> String?
}

public extension Card {
    func overviewContribution(state: PanelState) -> String? { nil }
}

public struct AnyPanelCard: Card {
    public let id: String
    public let title: String
    private let render: (PanelState) -> AnyView

    public init(id: String, title: String, render: @escaping (PanelState) -> AnyView) {
        self.id = id; self.title = title; self.render = render
    }
    public func makeView(state: PanelState) -> AnyView { render(state) }
}

@MainActor
public final class PanelState: ObservableObject {
    @Published public var snapshot: SystemSnapshot?
    @Published public var energy: EnergyDiagnosis?
    @Published public var chartHistory = ChartHistory()
    @Published public var quotas: [QuotaProvider: QuotaSnapshot] = [:]
    @Published public var quotaHistory: [QuotaProvider: [QuotaHistoryLine]] = [:]
    @Published public var quotaErrors: [QuotaProvider: String] = [:]
    @Published public var localStorage: [QuotaProvider: LocalStorageSnapshot] = [:]
    private var storageLoading: Set<QuotaProvider> = []
    public var now: () -> Date = Date.init
    @Published public var costs: [QuotaProvider: [DailyCost]] = [:]
    @Published public var networkTone: NetworkTone = .gray
    @Published public var failures: [String: Int] = [:]
    @Published public var fairSince: Date?
    @Published public var configResult: ConfigLoadResult
    @Published public var lastRefreshedAt: Date?
    @Published public var selectedTab: PanelTab = .system
    @Published public var chartMinutes = 60
    @Published public var selectedProvider: QuotaProvider = .codex
    @Published public var loginEnabled = false
    @Published public var networkModel: AppModel?
    @Published public var lastCleaning: CleaningRecord?

    public var onShowStorage: (QuotaProvider) -> Void = { _ in }
    public var onRefresh: () -> Void = {}
    public var onClean: () -> Void = {}
    public var onOpenConfig: () -> Void = {}
    public var onShowConfigFolder: () -> Void = {}
    public var onQuit: () -> Void = {}
    public var onToggleLogin: (Bool) -> Void = { _ in }

    public init(configResult: ConfigLoadResult = ConfigStore.load()) {
        self.configResult = configResult
    }

    public var health: HealthSummary {
        HealthEvaluator.evaluate(HealthInputs(system: snapshot, energy: energy,
                                               quotaUsedPercent: quotas.values.flatMap { $0.windows.map(\.usedPercent) },
                                               network: networkTone, failedSources: failures,
                                               fairSince: fairSince, now: now(), quotaSnapshots: Array(quotas.values)), config: configResult.config)
    }

    public func open() {
        let last = UserDefaults.standard.string(forKey: "lastPanelTab").flatMap(PanelTab.init(rawValue:)) ?? .system
        selectedTab = DefaultPanelLayout.openingTab(summary: health, lastViewed: last)
        if selectedTab == .quota { refreshStorageIfNeeded() }
    }

    public func refreshStorageIfNeeded() {
        for provider in [QuotaProvider.codex, .claude] {
            guard !storageLoading.contains(provider), localStorage[provider].map({ now().timeIntervalSince($0.sampledAt) >= 600 }) ?? true else { continue }
            storageLoading.insert(provider)
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".\(provider.rawValue)")
            Task.detached { [weak self] in
                do {
                    let value = try LocalStorageCollector.scan(directory: directory, provider: provider)
                    await MainActor.run { [weak self] in self?.localStorage[provider] = value; self?.storageLoading.remove(provider) }
                } catch {
                    Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "storage").error("存储统计失败：\(error.localizedDescription, privacy: .private)")
                    await MainActor.run { [weak self] in self?.storageLoading.remove(provider) }
                }
            }
        }
    }

    public func select(_ tab: PanelTab) {
        if tab == .quota { refreshStorageIfNeeded() }
        selectedTab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: "lastPanelTab")
    }
}

public struct OverviewMetric: Codable {
    public let title: String
    public let value: String
    public let detail: String
    public let fraction: Double
    public let level: HealthLevel
    public let numericValue: Double?
}

public extension PanelState {
    var tabLevels: [HealthLevel] {
        PanelTab.allCases.map { tab in health.issues.filter { $0.tab == tab }.map(\.level).max() ?? .normal }
    }
    var overviewMetrics: [OverviewMetric] {
        let cpu = snapshot?.cpuUsage
        let memory = snapshot?.memoryUsedFraction
        let usedGB = snapshot?.memoryUsedBytes.map { Int((Double($0) / 1_073_741_824).rounded()) }
        let totalGB = snapshot?.memoryTotalBytes.map { Int((Double($0) / 1_073_741_824).rounded()) }
        let memoryDetail = usedGB.flatMap { used in totalGB.map { "\(used) / \($0) GB" } } ?? "内存用量不可用"
        let memoryLevel: HealthLevel = snapshot?.memoryPressure == .critical ? .severe : snapshot?.memoryPressure == .warn ? .warn : .normal
        let quota = quotas[.claude]?.windows.first(where: { $0.effectiveWindowMinutes == 300 })
        let remaining = quota?.remainingPercent
        return [
            OverviewMetric(title: "CPU", value: cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", detail: "整机负载", fraction: cpu ?? 0, level: .normal, numericValue: cpu.map { $0 * 100 }),
            OverviewMetric(title: "内存", value: memory.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", detail: memoryDetail, fraction: memory ?? 0, level: memoryLevel, numericValue: memory.map { $0 * 100 }),
            OverviewMetric(title: "Claude", value: remaining.map { "\(Int($0.rounded()))%" } ?? "—", detail: "5 小时 · 剩余", fraction: (remaining ?? 0) / 100, level: Design.quotaLevel(remaining ?? 0), numericValue: remaining),
            OverviewMetric(title: "网络", value: snapshot?.networkReceivedBytesPerSecond.map { "↓" + MetricFormat.rate($0) } ?? "—", detail: snapshot?.networkSentBytesPerSecond.map { "↑" + MetricFormat.rate($0) } ?? "—", fraction: 1, level: networkTone == .red ? .severe : networkTone == .yellow ? .warn : .normal, numericValue: snapshot?.networkReceivedBytesPerSecond),
        ]
    }
    var quotaUpdatedAt: Date? { quotas.values.map(\.updatedAt).min() }
}

enum DisplayDate {
    static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "等待采集" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        return MetricFormat.duration(seconds) + "前"
    }
    static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
}

public struct PanelView: View {
    @ObservedObject private var state: PanelState
    private let expanded: Bool
    public init(state: PanelState, expanded: Bool = false) { self.state = state; self.expanded = expanded }

    private var tabContent: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            switch state.selectedTab {
            case .system:
                DiagnosisCard(state: state); SystemChartCard(state: state); SectionRule(); EnergyCard(state: state); SectionRule(); DiskCard(state: state)
            case .quota:
                QuotaPage(state: state)
            case .network:
                if let model = state.networkModel { NetworkPage(model: model) }
                else { Text("网络检测未启动").font(Design.caption).foregroundStyle(Design.secondary) }
            }
        }.padding(.horizontal, Design.inset).padding(.vertical, Design.sectionGap)
    }

    public var body: some View {
        VStack(spacing: 0) {
            OverviewView(state: state)
            CapsuleSelector(titles: ["系统", "额度", "网络"], selected: PanelTab.allCases.firstIndex(of: state.selectedTab) ?? 0, levels: state.tabLevels) { state.select(PanelTab.allCases[$0]) }
                .padding(.horizontal, Design.inset).padding(.bottom, Design.sectionGap)
            SectionRule()
            if expanded { tabContent }
            else { ScrollView { tabContent }.frame(maxHeight: Design.panelHeight - Design.fixedChromeHeight) }
            SectionRule()
            HStack(spacing: Design.rowGap) {
                CapsuleAction(title: "刷新", symbol: "arrow.clockwise", action: state.onRefresh)
                Spacer(minLength: 0)
                Text(state.quotaUpdatedAt.map { "额度更新于 " + DisplayDate.format($0, pattern: "HH:mm") } ?? "等待额度采集")
                    .font(Design.caption).foregroundStyle(Design.secondary)
                Spacer(minLength: 0)
                CapsuleAction(title: "设置⌄", symbol: "gearshape") { SettingsMenu.present(state: state) }
            }.padding(.horizontal, Design.inset).padding(.vertical, Design.footerInset)
        }.frame(width: Design.panelWidth).frame(maxHeight: expanded ? nil : Design.panelHeight).foregroundStyle(Design.label)
    }
}

struct OverviewView: View {
    @ObservedObject var state: PanelState
    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            VStack(alignment: .leading, spacing: Design.gap) {
                Button {
                    if let issue = state.health.worst { state.select(issue.tab) }
                } label: {
                    HStack(spacing: Design.rowGap) {
                        Image(nsImage: CatRenderer.image(frame: 0, level: state.health.level, load: state.catDisplay().load)).renderingMode(state.health.level == .normal ? .template : .original).resizable().foregroundStyle(Design.label).frame(width: Design.catWidth, height: Design.catHeight)
                        if let issue = state.health.worst {
                            HStack(spacing: Design.smallGap) {
                                Text(state.health.level == .severe ? "严重" : "提醒").foregroundStyle(Design.stateText(state.health.level))
                                Text("·").foregroundStyle(Design.secondary)
                                Text(issue.message)
                                Image(systemName: "chevron.right").foregroundStyle(Design.secondary).font(Design.caption)
                            }.font(Design.status).multilineTextAlignment(.leading)
                        } else { Text("一切正常").font(Design.status) }
                        Spacer(minLength: 0)
                        if state.health.level == .normal {
                            Text(DisplayDate.age(state.lastRefreshedAt, now: state.now())).font(Design.caption).foregroundStyle(Design.secondary)
                        }
                    }
                }.buttonStyle(.plain)
                if state.health.coolingHint {
                    HStack(spacing: Design.rowGap) {
                        Text("建议降温").font(Design.caption).fontWeight(.semibold).foregroundStyle(Design.stateText(.warn))
                            .padding(.horizontal, Design.rowGap).padding(.vertical, Design.rule).background(Design.orange.opacity(Design.mutedFill), in: Capsule())
                        if state.health.issues.count > 1 { Text("另有 \(state.health.issues.count - 1) 项问题，见系统页").font(Design.caption).foregroundStyle(Design.secondary) }
                    }.padding(.leading, Design.catWidth + Design.rowGap)
                }
            }
            HStack(alignment: .top, spacing: Design.metricGap) {
                ForEach(state.overviewMetrics.indices, id: \.self) { index in
                    let metric = state.overviewMetrics[index]
                    FlatMetric(title: metric.title, value: metric.value, detail: metric.detail, fraction: metric.fraction,
                               color: index == 0 ? Design.blue : index == 3 ? Design.networkColor(state.networkTone) : Design.state(metric.level))
                }
            }
            if let error = state.configResult.error { Text(error).font(Design.caption).foregroundStyle(Design.stateText(.warn)) }
        }.padding(.horizontal, Design.inset).padding(.top, Design.headerTop).padding(.bottom, Design.headerTop)
    }
}
