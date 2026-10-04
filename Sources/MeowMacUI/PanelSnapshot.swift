import Foundation
import MeowMacCore

public struct OverviewSnapshot: Codable {
    public let capturedAt: Date
    public let health: HealthSummary
    public let metrics: [OverviewMetric]
    public let quotaUpdatedAt: Date?
}
public struct TabsSnapshot: Codable {
    public let levels: [String: HealthLevel]
    public let defaultTab: PanelTab
}
public struct PanelLayoutSnapshot: Codable {
    public let effective: PanelLayout
    public let fallback: Bool
}
public struct RemindersSnapshot: Codable {
    public let current: [Reminder]
    public let snoozed: [SnoozeRecord]
    public let pendingIDs: [String]
    public let showingList: Bool
    public let filter: PanelTab?
}
public struct SystemPanelSnapshot: Codable {
    public let latest: SystemSnapshot?
    public let diagnosis: [DiagnosisRow]
    public let energy: EnergyDiagnosis?
    public let trends: [SystemTrend]
    public let chartMinutes: Int
    public let domain: ClosedRange<Date>
    public let warmPeriods: [ClosedRange<Date>]
    public let lastCleaning: CleaningRecord?
    /// v0.3 实验传感器的显示值、趋势图图例和风扇持续高转速的开始时刻。
    public var sensors: SensorCardDisplay? = nil
    public var coolingLegend: String? = nil
    public var fanHighSince: Date? = nil
}
public struct QuotaCycleDisplay: Codable {
    public let window: QuotaWindow
    public let start: Date, reset: Date
    public let points: [QuotaHistoryLine]
}
public struct QuotaChannelDisplay: Codable {
    public let provider: QuotaProvider
    public let accountEmail: String?, planName: String?, source: String?
    public let updatedAt: Date?
    public let windows: [QuotaWindowDisplay]
    public let buttonWindow: QuotaWindowDisplay?
    public let resetCredits: QuotaResetCredits?
    public let resetMonitor: CodexResetDisplay?
    public let cycles: [QuotaCycleDisplay]
    public let peaks: [QuotaPeak]
    public let cost: CostDisplay?
    public let costDays: [CostDayDisplay]
    public let selectedCostDay: CostDayDisplay?
    public let storage: LocalStorageSnapshot?
    public let error: String?
}
public struct PanelSnapshot: Codable {
    public let overview: OverviewSnapshot
    public let tabs: TabsSnapshot
    public let system: SystemPanelSnapshot
    public let quota: [QuotaChannelDisplay]
    public let network: NetworkDisplay?
    public let cat: CatDisplay
    public let layout: PanelLayoutSnapshot
    public let reminders: RemindersSnapshot
    @MainActor public init(state: PanelState) {
        overview = OverviewSnapshot(capturedAt: state.now(), health: state.health, metrics: state.overviewMetrics, quotaUpdatedAt: state.quotaUpdatedAt)
        tabs = TabsSnapshot(levels: Dictionary(uniqueKeysWithValues: zip(PanelTab.allCases.map(\.rawValue), state.tabLevels)), defaultTab: DefaultPanelLayout.openingTab(summary: state.health, lastViewed: state.selectedTab))
        system = SystemPanelSnapshot(latest: state.snapshot, diagnosis: state.diagnosisRows, energy: state.energy, trends: state.systemTrends,
            chartMinutes: state.chartMinutes, domain: state.trendDomain, warmPeriods: state.warmPeriods, lastCleaning: state.lastCleaning,
            sensors: state.sensorDisplay, coolingLegend: state.coolingLegend, fanHighSince: state.fanHighSince)
        quota = QuotaProvider.allCases.map { state.channelDisplay($0) }
        var networkDisplay = state.networkModel?.meowMacDisplay
        networkDisplay?.capture = state.networkCapture
        network = networkDisplay
        cat = state.catDisplay()
        layout = PanelLayoutSnapshot(effective: state.panelLayout, fallback: state.layoutRecoveryReason != nil || state.selectedCat == nil)
        reminders = RemindersSnapshot(current: state.allReminders, snoozed: state.projectedReminders.records,
            pendingIDs: state.pendingReminders.map(\.id), showingList: state.showingReminders, filter: state.reminderFilter)
    }
}
public extension PanelState {
    func quotaCycles(_ provider: QuotaProvider) -> [QuotaCycleDisplay] {
        (quotas[provider]?.windows ?? []).compactMap { window in
            guard let minutes = window.effectiveWindowMinutes, minutes > 300, let reset = window.resetsAt else { return nil }
            return QuotaCycleDisplay(window: window, start: reset.addingTimeInterval(Double(-minutes * 60)), reset: reset,
                points: QuotaHistorySeries.currentCycle(quotaHistory[provider] ?? [], window: window, now: now()))
        }
    }
    func quotaPeaks(_ provider: QuotaProvider) -> [QuotaPeak] { QuotaHistorySeries.peaks(quotaHistory[provider] ?? [], now: now()) }
    func channelDisplay(_ provider: QuotaProvider) -> QuotaChannelDisplay {
        let snapshot = quotas[provider]
        let windows = displayedWindows(provider)
        return QuotaChannelDisplay(provider: provider, accountEmail: snapshot?.accountEmail, planName: snapshot?.planName, source: snapshot?.source, updatedAt: snapshot?.updatedAt,
            windows: windows, buttonWindow: windows.min { $0.remainingPercent < $1.remainingPercent }, resetCredits: snapshot?.codexResetCredits,
            resetMonitor: provider == .codex ? codexResetState.display : nil,
            cycles: quotaCycles(provider), peaks: quotaPeaks(provider), cost: costDisplay(provider),
            costDays: costDisplay(provider) == nil ? [] : costChartDates.map { costDayDisplay(provider, date: $0) },
            selectedCostDay: costDisplay(provider) == nil ? nil : costDayDisplay(provider, date: displayedCostDate),
            storage: localStorage[provider], error: quotaErrors[provider])
    }
}
