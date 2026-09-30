import AppKit
import Charts
import SwiftUI
import MeowMacCore
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
    @Published public var costs: [QuotaProvider: [DailyCost]] = [:]
    @Published public var networkTone: NetworkTone = .gray
    @Published public var failures: [String: Int] = [:]
    @Published public var fairSince: Date?
    @Published public var configResult: ConfigLoadResult
    @Published public var lastRefreshedAt: Date?
    @Published public var selectedTab: PanelTab = .system
    @Published public var chartMinutes = 60
    @Published public var loginEnabled = false
    @Published public var networkModel: AppModel?
    @Published public var lastCleaning: CleaningRecord?

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
                                               fairSince: fairSince, now: Date()), config: configResult.config)
    }

    public func open() {
        let last = UserDefaults.standard.string(forKey: "lastPanelTab").flatMap(PanelTab.init(rawValue:)) ?? .system
        selectedTab = DefaultPanelLayout.openingTab(summary: health, lastViewed: last)
    }

    public func select(_ tab: PanelTab) {
        selectedTab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: "lastPanelTab")
    }
}

public struct PanelView: View {
    @ObservedObject private var state: PanelState

    public init(state: PanelState) { self.state = state }

    private var cards: [String: AnyPanelCard] {
        [
            "system.chart": AnyPanelCard(id: "system.chart", title: "负载、功耗与温度") { AnyView(SystemChartCard(state: $0)) },
            "system.energy": AnyPanelCard(id: "system.energy", title: "能耗诊断") { AnyView(EnergyCard(state: $0)) },
            "system.disk": AnyPanelCard(id: "system.disk", title: "磁盘与清理") { AnyView(DiskCard(state: $0)) },
            "quota.providers": AnyPanelCard(id: "quota.providers", title: "额度窗口") { AnyView(QuotaProvidersCard(state: $0)) },
            "quota.cost": AnyPanelCard(id: "quota.cost", title: "按天花费") { AnyView(CostCard(state: $0)) },
            "network.monitor": AnyPanelCard(id: "network.monitor", title: "网络检测") { state in
                AnyView(Group {
                    if let model = state.networkModel { PopoverRootView(model: model, maxScrollHeight: nil) }
                    else { Text("网络检测未启动").foregroundStyle(.secondary) }
                })
            },
        ]
    }

    public var body: some View {
        VStack(spacing: 0) {
            overview
            Divider()
            Picker("标签页", selection: Binding(get: { state.selectedTab }, set: { state.select($0) })) {
                ForEach(DefaultPanelLayout.tabs, id: \.tab) { layout in
                    Text(layout.title).tag(layout.tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            ScrollView {
                VStack(spacing: 10) {
                    if let layout = DefaultPanelLayout.tabs.first(where: { $0.tab == state.selectedTab }) {
                        ForEach(layout.cardIDs, id: \.self) { id in
                            if let card = cards[id] {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(card.title).font(.headline)
                                    card.makeView(state: state)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 440)
            Divider()
            HStack {
                Button("刷新", action: state.onRefresh)
                Button("清理", action: state.onClean)
                Spacer()
                Menu("设置") {
                    Button("打开配置文件", action: state.onOpenConfig)
                    Button("在访达中显示配置目录", action: state.onShowConfigFolder)
                    Toggle("开机启动", isOn: Binding(get: { state.loginEnabled }, set: { state.onToggleLogin($0) }))
                    Divider()
                    Button("退出 MeowMac", action: state.onQuit)
                }
            }
            .padding(12)
        }
        .frame(width: 380)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(state.health.level == .severe ? "严重" : state.health.level == .warn ? "提醒" : "正常")
                    .fontWeight(.semibold)
                if let issue = state.health.worst {
                    Button(issue.message) { state.select(issue.tab) }.buttonStyle(.plain)
                } else {
                    Text("一切正常").foregroundStyle(.secondary)
                    if let date = state.lastRefreshedAt { Text(date, style: .time).foregroundStyle(.secondary) }
                }
                if state.health.coolingHint { Text("建议降温").foregroundStyle(.orange) }
            }
            HStack {
                Text("CPU \(Int((state.snapshot?.cpuUsage ?? 0) * 100))%")
                Text("内存 \(state.snapshot?.memoryPressure.rawValue ?? "未知")")
                let claude = state.quotas[.claude]?.windows.first?.usedPercent
                Text("Claude \(claude.map { "\(Int(100 - $0))%" } ?? "--")")
                Circle().fill(state.networkTone == .red ? Color.red : state.networkTone == .yellow ? .orange : state.networkTone == .green ? .green : .gray)
                    .frame(width: 8, height: 8)
            }
            .font(.caption)
            if let error = state.configResult.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
