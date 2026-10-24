import AppKit
import Charts
import SwiftUI
import MeowMacCore
import MeowMacSystem
import MeowMacQuota
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
    private let available: (PanelState) -> Bool

    public init(id: String, title: String, available: @escaping (PanelState) -> Bool = { _ in true },
                render: @escaping (PanelState) -> AnyView) {
        self.id = id; self.title = title; self.available = available; self.render = render
    }
    public func makeView(state: PanelState) -> AnyView { render(state) }
    public func isAvailable(state: PanelState) -> Bool { available(state) }
}

@MainActor
public enum PanelCardRegistry {
    public static let cards: [String: AnyPanelCard] = Dictionary(uniqueKeysWithValues:
        PanelLayoutCatalog.definitions.values.flatMap { $0 }.map { definition in
            (definition.id, AnyPanelCard(id: definition.id, title: definition.title, available: { state in
                switch definition.id {
                case "quota.trend": return state.quotas[state.selectedProvider]?.windows.isEmpty == false
                case "quota.cost": return state.costDisplay(state.selectedProvider) != nil
                case "quota.storage": return [.claude, .codex].contains(state.selectedProvider) && state.localStorage[state.selectedProvider] != nil
                case "network.checks", "network.sites", "network.traffic", "network.egress": return state.networkModel != nil
                default: return true
                }
            }, render: { state in
                switch definition.id {
                case "system.chart": return AnyView(SystemChartCard(state: state))
                case "system.energy": return AnyView(EnergyCard(state: state))
                case "system.disk": return AnyView(DiskCard(state: state))
                case "quota.trend": return AnyView(QuotaTrendView(state: state, provider: state.selectedProvider))
                case "quota.cost":
                    return AnyView(state.costDisplay(state.selectedProvider).map { CostCard(state: state, value: $0, provider: state.selectedProvider) })
                case "quota.storage":
                    return AnyView(state.localStorage[state.selectedProvider].map { StorageCard(state: state, provider: state.selectedProvider, value: $0) })
                case "network.checks": return AnyView(state.networkModel.map { NetworkChecks(model: $0, state: state) })
                case "network.sites": return AnyView(state.networkModel.map { NetworkSites(model: $0, state: state) })
                case "network.traffic": return AnyView(NetworkTraffic(state: state))
                case "network.proxy": return AnyView(ProxyTrafficCard(state: state))
                case "network.egress": return AnyView(state.networkModel.map { NetworkEgress(model: $0) })
                default: return AnyView(EmptyView())
                }
            }))
        })
}

@MainActor
public final class PanelState: ObservableObject {
    @Published public var snapshot: SystemSnapshot? { didSet { refreshReminders() } }
    @Published public var energy: EnergyDiagnosis? { didSet { refreshReminders() } }
    @Published public var chartHistory = ChartHistory()
    @Published public private(set) var quotaSources = QuotaSourceList()
    @Published public var quotaSourceRecoveryReason: String?
    public var onQuotaSourcesRemoved: ([QuotaProvider]) -> Void = { _ in }
    public var quotaProviders: [QuotaProvider] { quotaSources.providers }
    public func openQuotaSourceSettings() { onOpenSettings(.quotaSources) }
    public var quotaEmptyMessage: String { "还没有额度渠道，在设置的“额度源”栏中添加" }
    public func sourcesWithWindowFallbacks(_ list: QuotaSourceList) -> QuotaSourceList {
        var result = list
        result.overviewWindowKinds = quotaSources.overviewWindowKinds.merging(list.overviewWindowKinds) { _, new in new }
        result.balanceWarn = quotaSources.balanceWarn.merging(list.balanceWarn) { _, new in new }
        let removed = quotaProviders.filter { !list.providers.contains($0) }
        for provider in removed {
            if let windows = quotas[provider]?.windows {
                result.overviewWindowKinds[provider.rawValue] = Dictionary(windows.map { ($0.identifier, QuotaWindowKind(minutes: $0.effectiveWindowMinutes, name: $0.displayName)) }, uniquingKeysWith: { first, _ in first })
            }
        }
        for provider in list.providers { result.overviewWindowKinds.removeValue(forKey: provider.rawValue) }
        return result
    }
    public func applyQuotaSources(_ requested: QuotaSourceList) {
        let list = sourcesWithWindowFallbacks(requested)
        let removed = quotaProviders.filter { !list.providers.contains($0) }
        quotaSources = list
        for provider in removed {
            quotaAttempts.removeValue(forKey: provider); quotas.removeValue(forKey: provider); quotaErrors.removeValue(forKey: provider)
            quotaHistory.removeValue(forKey: provider); costs.removeValue(forKey: provider)
            localStorage.removeValue(forKey: provider); failures.removeValue(forKey: "quota." + provider.rawValue)
        }
        if !quotaProviders.contains(selectedProvider), let first = quotaProviders.first { selectedProvider = first }
        if list.providers.isEmpty { failures["quota"] = 0 }
        let absent = QuotaCatalog.usageNames.keys.compactMap(QuotaProvider.init(rawValue:)).filter { !list.providers.contains($0) }
        reminderTracker.removeProviders(absent)
        onQuotaSourcesRemoved(removed)
        refreshReminders()
    }
    @Published public var quotas: [QuotaProvider: QuotaSnapshot] = [:] { didSet { refreshReminders() } }
    @Published public var quotaHistory: [QuotaProvider: [QuotaHistoryLine]] = [:]
    @Published public var quotaAttempts: [QuotaProvider: QuotaAttempt] = [:]
    @Published public var quotaErrors: [QuotaProvider: String] = [:]
    @Published public var quotaProxyStatus: QuotaProxyStatus = .checking
    @Published public var codexResetState = CodexResetState()
    @Published public var localStorage: [QuotaProvider: LocalStorageSnapshot] = [:]
    private var storageLoading: Set<QuotaProvider> = []
    public var now: () -> Date = Date.init
    @Published public var costs: [QuotaProvider: [DailyCost]] = [:]
    @Published public var proxyTraffic = ProxyTrafficViewData() { didSet { proxyTrafficSummaryCache = nil } }
    @Published public var proxyTrafficRange: ProxyTrafficRange = .today { didSet { proxyTrafficSummaryCache = nil } }
    private var proxyTrafficSummaryCache: (hour: Date, summary: ProxyTrafficSummary)?
    /// 面板任一状态变化都会重新求值卡片；汇总只在数据、范围或当前小时变化时重算。
    public func proxyTrafficSummary() -> ProxyTrafficSummary {
        let now = now(), hour = ProxyTrafficTime.start(now)
        if let cache = proxyTrafficSummaryCache, cache.hour == hour { return cache.summary }
        let summary = ProxyTrafficSummary(rows: proxyTraffic.rows, range: proxyTrafficRange, now: now)
        proxyTrafficSummaryCache = (hour, summary)
        return summary
    }
    @Published public var expandedProxyProcesses: Set<String> = []
    @Published public var networkTone: NetworkTone = .gray { didSet { refreshReminders() } }
    @Published public var failures: [String: Int] = [:] { didSet { refreshReminders() } }
    @Published public var fairSince: Date? { didSet { refreshReminders() } }
    /// 风扇转速开始持续超过阈值的时刻（D14）。
    @Published public var fanHighSince: Date? { didSet { refreshReminders() } }
    public var ruleClock = RuleClock()
    var pendingAlertRuleResets = Set<String>()
    @Published public var configResult: ConfigLoadResult {
        didSet {
            let removed = Set(oldValue.config.alertRules.builtin.keys).subtracting(configResult.config.alertRules.builtin.keys)
            pendingAlertRuleResets.formUnion(removed.filter { BuiltinAlertRule(rawValue: $0) != nil })
            // 换指标后，旧提醒及记录即使对象仍叫 system，也不属于新的检测条件。
            for rule in configResult.config.alertRules.custom {
                if let previous = oldValue.config.alertRules.custom.first(where: { $0.id == rule.id }), previous.metric != rule.metric {
                    pendingAlertRuleResets.insert(rule.id)
                }
            }
            refreshReminders()
        }
    }
    @Published public var lastRefreshedAt: Date?
    @Published public var selectedTab: PanelTab = .system
    @Published public var chartHoverDate: Date?
    @Published public var chartHoverKind: String?
    @Published public var chartMinutes = 60 {
        didSet { chartHoverDate = nil; chartHoverKind = nil }
    }
    @Published public var selectedProvider: QuotaProvider = .codex {
        didSet { if oldValue != selectedProvider { selectedCostDate = nil } }
    }
    @Published public private(set) var selectedCostDate: String?
    @Published public var loginEnabled = false
    @Published public var networkModel: AppModel? { didSet { refreshReminders() } }
    /// 站点轮次和速率的本机历史，最近 24 小时。
    @Published public var networkHistory = NetworkHistory()
    /// 近 24 小时电量（D44），由 `BatteryHistoryRecorder` 更新。
    @Published public var batteryHistory = BatteryHistory()
    @Published public var networkRange: NetworkTrendRange = .hour
    public var networkCapture: NetworkCaptureInfo?
    @Published public var cleanTerminalPreference: CleanTerminal
    @Published public var availableCleanTerminals: Set<CleanTerminal> = []
    @Published public var aiAgentPreference: AIAgent
    @Published public var aiDiagnosisEntry: Bool
    @Published public var aiAgentInstallations: [AIAgentInstallation] = []
    @Published public var aiSettingsError: String?
    public var onSelectAIAgent: (AIAgent) -> Void = { _ in }
    public var onSetAIDiagnosisEntry: (Bool) -> Void = { _ in }
    public var onDetectAIAgents: () -> Void = {}
    public var onAIDiagnosis: () -> Void = {}
    @Published public var cleanLaunching = false
    @Published public var cleaningHistoryMessage: String?
    @Published public var lastCleaning: CleaningRecord?
    @Published public var selectedCat: LoadedCat? = CatPackageLoader.defaultCat
    public var catStore: CatStore?
    public var layoutStore: PanelLayoutStore?
    public var styleStore: StyleStore?
    @Published public private(set) var style: StyleSettings = .default
    @Published public private(set) var styleRecoveryReason: String?
    @Published public private(set) var panelLayout: PanelLayout = .default
    @Published public private(set) var layoutRecoveryReason: String?
    @Published public var catLevelOverride: HealthLevel?
    @Published var reminderTracker = ReminderTracker()
    @Published public var showingReminders = false
    @Published public var reminderFilter: PanelTab?
    @Published public var activeSnoozeID: String?
    @Published public var reminderError: String?
    public var energyUpdatedAt: Date?
    var reminderStore: ReminderStore?
    var reminderPersistenceDirty = false
    var reminderSaveAttempt: Date?
    public var effectiveCatLevel: HealthLevel {
        catLevelOverride ?? health.level
    }

    public var onShowStorage: (QuotaProvider) -> Void = { _ in }
    public var onRefresh: () -> Void = {}
    public var onPrepareCleanTerminalMenu: () -> Void = {}
    public var onSelectCleanTerminal: (CleanTerminal) -> Void = { _ in }
    public var onClean: () -> Void = {}
    public var onOpenConfig: () -> Void = {}
    public var onShowConfigFolder: () -> Void = {}
    public var onQuit: () -> Void = {}
    public var onToggleLogin: (Bool) -> Void = { _ in }
    public var onSelectCat: (String) -> Void = { _ in }
    public var onImportCat: () -> Void = {}
    public var onShowCats: () -> Void = {}
    public var onOpenSettings: (SettingsSection?) -> Void = { _ in }
    public var onImportCodexBarHistory: () -> Void = {}
    /// 系统通知（D41）：开关、授权状态（nil 表示未知）和菜单回调。
    @Published public var notificationSettings = NotificationSettings()
    @Published public var notificationsAuthorized: Bool?
    public var onSetNotificationSettings: (NotificationSettings) -> Void = { _ in }
    public var onOpenNotificationSystemSettings: () -> Void = {}
    public var onPrepareNotificationMenu: () -> Void = {}
    /// 每次提醒 reconcile 之后调用，由通知协调器接收。
    public var onRemindersRefreshed: (ReminderTracker, ReminderBatch) -> Void = { _, _ in }
    /// 历史导入是一次性功能，导入完成后菜单不再显示入口。
    @Published public var showsCodexBarImport = true
    public var onCatChanged: () -> Void = {}
    public var readLastTab: () -> PanelTab = {
        UserDefaults.standard.string(forKey: "lastPanelTab").flatMap(PanelTab.init(rawValue:)) ?? .system
    }
    public var writeLastTab: (PanelTab) -> Void = { UserDefaults.standard.set($0.rawValue, forKey: "lastPanelTab") }

    public func loadLayoutForSelectedCat() {
        let loaded = layoutStore?.load(cat: selectedCat) ?? PanelLayoutLoad(layout: selectedCat?.package.panel ?? .default, recoveryReason: nil)
        panelLayout = loaded.layout
        layoutRecoveryReason = loaded.recoveryReason
    }

    public func saveLayout(_ layout: PanelLayout, for catID: String) throws {
        guard let cat = selectedCat, cat.id == catID, let layoutStore else {
            throw PanelLayoutError.invalid("当前猫已改变，未保存草稿")
        }
        try layoutStore.save(layout, cat: cat)
        panelLayout = layout
        layoutRecoveryReason = nil
    }

    public func loadStyle() {
        let loaded = styleStore?.load() ?? StyleLoad(settings: .default, recoveryReason: nil)
        applyStyle(loaded.settings)
        styleRecoveryReason = loaded.recoveryReason
    }

    public func applyStyle(_ settings: StyleSettings) {
        style = settings
        chartMinutes = settings.chartMinutes
    }

    public func saveStyle(_ settings: StyleSettings) throws {
        guard let styleStore else { throw StyleError.invalid("样式存储不可用") }
        try styleStore.save(settings)
        applyStyle(settings)
        styleRecoveryReason = nil
    }

    /// 站点和速率共用一条时间轴，画在两者中靠后显示的那一块下面。
    var networkAxisOwner: String? {
        renderedCardIDs(for: .network).last { $0 == "network.sites" || $0 == "network.traffic" }
    }

    public func renderedCardIDs(for tab: PanelTab) -> [String] {
        panelLayout.visibleIDs(for: tab).filter { PanelCardRegistry.cards[$0]?.isAvailable(state: self) == true }
    }

    public init(configResult: ConfigLoadResult = ConfigStore.load()) {
        self.configResult = configResult
        self.cleanTerminalPreference = configResult.config.cleanTerminal
        self.aiAgentPreference = configResult.config.aiAgent
        self.aiDiagnosisEntry = configResult.config.aiDiagnosisEntry
    }

    public var health: HealthSummary {
        projectedReminders.health(now: now())
    }

    public func open() {
        showingReminders = false
        activeSnoozeID = nil
        refreshReminders()
        selectedTab = DefaultPanelLayout.openingTab(summary: health, lastViewed: readLastTab())
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

    public func selectCostDay(_ date: String) {
        guard costChartDates.contains(date) else { return }
        selectedCostDate = date == displayedCostDate ? nil : date
    }

    public func select(_ tab: PanelTab) {
        if tab == .quota { refreshStorageIfNeeded() }
        selectedTab = tab
        writeLastTab(tab)
    }
}

public struct OverviewMetric: Codable {
    public let item: OverviewItem
    public let title: String
    public let value: String
    public let detail: String
    public let fraction: Double
    public let level: HealthLevel
    public let numericValue: Double?
}

public extension PanelState {
    var tabLevels: [HealthLevel] {
        PanelTab.allCases.map { tab in level(for: tab) }
    }
    func level(for tab: PanelTab) -> HealthLevel {
        allReminders.filter { $0.tab == tab }.map(\.level).max() ?? .normal
    }
    var overviewMetrics: [OverviewMetric] { overviewMetrics(for: panelLayout.overview) }
    func overviewColor(for metric: OverviewMetric) -> Color {
        switch metric.item {
        case .cpu: return Design.blue
        case .network: return Design.networkColor(networkTone)
        case .memory, .quota: return Design.state(metric.level)
        }
    }
    func overviewMetrics(for overview: PanelOverview) -> [OverviewMetric] {
        let cpu = snapshot?.cpuUsage
        let memory = snapshot?.memoryPressurePercent
        let usedGB = snapshot?.memoryUsedBytes.map { Int((Double($0) / 1_073_741_824).rounded()) }
        let totalGB = snapshot?.memoryTotalBytes.map { Int((Double($0) / 1_073_741_824).rounded()) }
        let memoryDetail = usedGB.flatMap { used in totalGB.map { "已用 \(used) / \($0) GB" } } ?? "内存用量不可用"
        let memoryLevel: HealthLevel = snapshot?.memoryPressure == .critical ? .severe : snapshot?.memoryPressure == .warn ? .warn : .normal
        var quotaConfig = overview.quota
        if !quotaProviders.contains(quotaConfig.provider), let first = quotaProviders.first {
            if quotaConfig.window.hasPrefix("id:"), let kind = quotaSources.overviewWindowKinds[quotaConfig.provider.rawValue]?[String(quotaConfig.window.dropFirst(3))] {
                let candidates = (quotas[first]?.windows ?? []).filter { window in
                    if let minutes = kind.minutes { return window.effectiveWindowMinutes == minutes }
                    return window.displayName == kind.name
                }
                if let match = candidates.first(where: { $0.displayName == kind.name }) ?? candidates.first {
                    quotaConfig.window = "id:" + match.identifier
                } else { quotaConfig.window = kind.minutes.map { "minutes:\($0)" } ?? "id:unavailable" }
            }
            quotaConfig.provider = first
        }
        let quota = quotaConfig.selectedWindow(in: quotas[quotaConfig.provider])
        let remaining = quota?.remainingPercent
        let shown = quota.map { quotaPercent($0) }
        let quotaName = quota?.effectiveWindowMinutes == 300 ? "5 小时" : quota?.effectiveWindowMinutes == 10080 ? "7 天" : quota?.displayName.replacingOccurrences(of: "窗口", with: "") ?? "额度"
        let metrics: [OverviewItem: OverviewMetric] = [
            .cpu: OverviewMetric(item: .cpu, title: "CPU", value: cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", detail: "整机负载", fraction: cpu ?? 0, level: .normal, numericValue: cpu.map { $0 * 100 }),
            .memory: OverviewMetric(item: .memory, title: "内存", value: memory.map { "\(Int($0.rounded()))%" } ?? "—", detail: memoryDetail, fraction: (memory ?? 0) / 100, level: memoryLevel, numericValue: memory),
            .quota: OverviewMetric(item: .quota, title: quotaProviders.isEmpty ? "额度" : quotaConfig.provider.displayName, value: quotaProviders.isEmpty ? "未添加" : shown.map { "\(Int($0.rounded()))%" } ?? "—", detail: quotaName + " · " + quotaBasisLabel, fraction: (shown ?? 0) / 100, level: quotaProviders.isEmpty ? .normal : Design.quotaLevel(remaining ?? 0), numericValue: shown),
            .network: OverviewMetric(item: .network, title: "网络", value: snapshot?.networkReceivedBytesPerSecond.map { "↓" + MetricFormat.rate($0) } ?? "—", detail: snapshot?.networkSentBytesPerSecond.map { "↑" + MetricFormat.rate($0) } ?? "—", fraction: 1, level: networkTone == .red ? .severe : networkTone == .yellow ? .warn : .normal, numericValue: snapshot?.networkReceivedBytesPerSecond),
        ]
        return overview.visible.compactMap { metrics[$0] }
    }
    var quotaBasisLabel: String { style.quotaBasis == .remaining ? "剩余" : "已用" }
    func quotaPercent(_ window: QuotaWindow) -> Double { style.quotaBasis == .remaining ? window.remainingPercent : window.usedPercent }
    func quotaPaceMarker(_ pace: QuotaPace?) -> Double? {
        pace.map { style.quotaBasis == .remaining ? $0.expectedRemainingFraction : 1 - $0.expectedRemainingFraction }
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
    @StateObject private var measurements: PanelMeasurements
    private let expanded: Bool
    public init(state: PanelState, expanded: Bool = false, measurements: PanelMeasurements? = nil) {
        self.state = state; self.expanded = expanded
        _measurements = StateObject(wrappedValue: measurements ?? PanelMeasurements())
    }

    private var tabContent: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            switch state.selectedTab {
            case .system:
                if !state.diagnosisRows.isEmpty { DiagnosisCard(state: state) }
                let ids = state.renderedCardIDs(for: .system)
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    if index > 0 { SectionRule() }
                    PanelCardRegistry.cards[id]?.makeView(state: state).measureCardBottom(id)
                }
            case .quota:
                QuotaPage(state: state)
            case .network:
                if let model = state.networkModel { NetworkPage(model: model, state: state) }
                else {
                    Text("网络检测未启动").font(Design.caption).foregroundStyle(Design.secondary)
                    ForEach(state.renderedCardIDs(for: .network), id: \.self) { id in
                        PanelCardRegistry.cards[id]?.makeView(state: state).measureCardBottom(id)
                    }
                }
            }
        }.padding(.horizontal, Design.inset).padding(.vertical, Design.sectionGap)
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if state.showingReminders {
                    if state.activeSnoozeID != nil {
                        Text("我已知道").font(Design.status).padding(Design.inset)
                    } else { ReminderHeader(state: state) }
                } else {
                OverviewView(state: state)
                CapsuleSelector(titles: state.panelLayout.tabs.map(\.title), selected: state.panelLayout.tabs.firstIndex(of: state.selectedTab) ?? 0,
                                levels: state.panelLayout.tabs.map { state.level(for: $0) }) { state.select(state.panelLayout.tabs[$0]) }
                    .padding(.horizontal, Design.inset).padding(.bottom, Design.sectionGap)
                }
                SectionRule()
            }.fixedSize(horizontal: false, vertical: true).measurePanelHeight(.header)
            if expanded { measuredContent }
            else { ScrollView { measuredContent }.frame(height: measurements.viewportHeight) }
            VStack(spacing: 0) {
                SectionRule()
                if state.showingReminders {
                    VStack(alignment: .leading, spacing: Design.gap) {
                        Text("已知晓会暂缓告警；持续故障仍需关注。").font(Design.caption).foregroundStyle(Design.secondary)
                        if let error = state.reminderError { Text(error).font(Design.caption).foregroundStyle(Design.stateText(.warn)) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(Design.inset)
                } else {
                HStack(spacing: Design.rowGap) {
                    CapsuleAction(title: "刷新", symbol: "arrow.clockwise", action: state.onRefresh)
                    Spacer(minLength: 0)
                    Text(state.quotaUpdatedAt.map { "额度更新于 " + DisplayDate.format($0, pattern: "HH:mm") } ?? "等待额度采集")
                        .font(Design.caption).foregroundStyle(Design.secondary)
                    Spacer(minLength: 0)
                    CapsuleAction(title: "设置", symbol: "gearshape") { SettingsMenu.present(state: state) }
                }.padding(.horizontal, Design.inset).padding(.vertical, Design.footerInset)
                }
            }.fixedSize(horizontal: false, vertical: true).measurePanelHeight(.footer)
        }.frame(width: Design.panelWidth)
            .frame(height: expanded ? nil : measurements.panelHeight, alignment: .top)
            .background(PanelSurface())
            .foregroundStyle(Design.label).focusEffectDisabled()
            .coordinateSpace(name: PanelInteractionFrameKey.space)
            .onPreferenceChange(PanelInteractionFrameKey.self) { measurements.updateInteractions($0) }
            .onPreferenceChange(PanelHeightKey.self) { measurements.update($0) }
    }

    private var measuredContent: some View {
        Group {
            if state.showingReminders {
                if let id = state.activeSnoozeID, let reminder = state.allReminders.first(where: { $0.id == id }) {
                    SnoozeForm(state: state, reminder: reminder).id(id)
                } else { ReminderList(state: state) }
            } else { tabContent }
        }.fixedSize(horizontal: false, vertical: true).coordinateSpace(name: PanelCardBottomKey.space).measurePanelHeight(.content)
            .onPreferenceChange(PanelCardBottomKey.self) { measurements.updateCards($0) }
    }
}

struct PanelInteractionFrameKey: PreferenceKey {
    static let space = "panelInteractions"
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

private enum PanelPart: Hashable { case header, footer, content }
private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: [PanelPart: CGFloat] = [:]
    static func reduce(value: inout [PanelPart: CGFloat], nextValue: () -> [PanelPart: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
/// 功能块底边在标签页内容里的位置，用来核对首屏能看到哪些块。
private struct PanelCardBottomKey: PreferenceKey {
    static let space = "panelContent"
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
extension View {
    func measureCardBottom(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: PanelCardBottomKey.self, value: [id: proxy.frame(in: .named(PanelCardBottomKey.space)).maxY])
        })
    }
}
private extension View {
    func measurePanelHeight(_ part: PanelPart) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: PanelHeightKey.self, value: [part: proxy.size.height]) })
    }
}

@MainActor
public final class PanelMeasurements: ObservableObject {
    @Published public private(set) var headerHeight: CGFloat = 0
    @Published public private(set) var footerHeight: CGFloat = 0
    @Published public private(set) var contentHeight: CGFloat = 0
    /// 系统页、网络页各功能块底边距内容顶部的距离。
    @Published public private(set) var cardBottoms: [String: CGFloat] = [:]
    @Published public private(set) var interactionFrames: [String: CGRect] = [:]
    public init() {}
    public var fixedHeight: CGFloat { headerHeight + footerHeight }
    public var viewportHeight: CGFloat { min(contentHeight, max(0, Design.panelHeight - fixedHeight)) }
    public var panelHeight: CGFloat { fixedHeight + viewportHeight }

    fileprivate func update(_ values: [PanelPart: CGFloat]) {
        if let height = values[.header], abs(height - headerHeight) > 0.01 { headerHeight = height }
        if let height = values[.footer], abs(height - footerHeight) > 0.01 { footerHeight = height }
        if let height = values[.content], abs(height - contentHeight) > 0.01 { contentHeight = height }
    }

    fileprivate func updateInteractions(_ values: [String: CGRect]) {
        if values != interactionFrames { interactionFrames = values }
    }

    fileprivate func updateCards(_ values: [String: CGFloat]) {
        if values != cardBottoms { cardBottoms = values }
    }
}

public enum PanelHosting {
    @MainActor public static func make(state: PanelState) -> (controller: NSHostingController<PanelView>, measurements: PanelMeasurements) {
        let measurements = PanelMeasurements()
        let controller = NSHostingController(rootView: PanelView(state: state, measurements: measurements))
        controller.sizingOptions = [.preferredContentSize]
        controller.view.focusRingType = .none
        return (controller, measurements)
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
                        Image(nsImage: CatRenderer.image(cat: state.selectedCat, display: state.catDisplay(), frame: 0))
                            .renderingMode(state.catDisplay().template ? .template : .original)
                            .resizable().aspectRatio(contentMode: .fit).foregroundStyle(Design.label)
                            .frame(width: Design.catWidth, height: Design.catHeight)
                        if let issue = state.health.worst {
                            HStack(spacing: Design.smallGap) {
                                Text(state.health.level == .severe ? "严重" : "提醒").foregroundStyle(Design.stateText(state.health.level))
                                Text("·").foregroundStyle(Design.secondary)
                                Text(issue.message)
                                Image(systemName: "chevron.right").foregroundStyle(Design.secondary).font(Design.caption)
                            }.font(Design.status).multilineTextAlignment(.leading)
                        } else { Text(state.snoozedReminders.isEmpty ? "一切正常" : "当前无待关注提醒").font(Design.status) }
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
                    }.padding(.leading, Design.catWidth + Design.rowGap)
                }
            }
            Button { state.showReminders() } label: {
                HStack {
                    Text("全部提醒 · \(state.allReminders.count) 项")
                    if !state.snoozedReminders.isEmpty { Text("已知晓 \(state.snoozedReminders.count)").foregroundStyle(Design.secondary) }
                    Spacer()
                    Image(systemName: "chevron.right")
                }.font(Design.caption).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("reminders.open")
            HStack(alignment: .top, spacing: Design.metricGap) {
                ForEach(state.overviewMetrics.indices, id: \.self) { index in
                    let metric = state.overviewMetrics[index]
                    FlatMetric(title: metric.title, value: metric.value, detail: metric.detail, fraction: metric.fraction,
                               color: state.overviewColor(for: metric))
                }
            }
            if let error = state.configResult.error { Text(error).font(Design.caption).foregroundStyle(Design.stateText(.warn)) }
            if let error = state.reminderError { Text(error).font(Design.caption).foregroundStyle(Design.stateText(.warn)) }
        }.padding(.horizontal, Design.inset).padding(.top, Design.headerTop).padding(.bottom, Design.headerTop)
    }
}
