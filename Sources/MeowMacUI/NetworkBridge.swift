import Foundation
import Combine
import MeowMacCore
import TunCanaryCore
import TunCanarySystem
import TunCanaryProbe
import TunCanaryUI
import TunCanaryRuntime

public enum NetworkToneMapper {
    public static func map(_ severity: Severity) -> NetworkTone {
        switch severity {
        case .ok: return .green
        case .unknown: return .gray
        case .warning: return .yellow
        case .critical: return .red
        }
    }
}

@MainActor
public final class NetworkBridge {
    public let model: AppModel
    private let monitor: MonitorController
    private var subscription: AnyCancellable?

    public init(onTone: @escaping (NetworkTone) -> Void) {
        let store = SettingsStore()
        let paths = KnownPaths.currentUser()
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeowMac/tuncanary", isDirectory: true)
        let egressHistory = EgressHistoryStore(fileURL: appSupport.appendingPathComponent("egress-history.json"))
        let model = AppModel(settings: store.load(), egressChecker: EgressIPChecker(),
                             egressGeoClient: EgressGeoClient(), egressHistoryStore: egressHistory)
        self.model = model
        let notifier = UserNotificationCenterNotifier()
        let loginItem = MainAppLoginItemController()
        let adapters = VPNAdapterRegistry(store: VPNAdapterStore(paths: paths))
        var configuration = SystemSnapshotProvider.Configuration(paths: paths, proxySource: { SettingsStore().load().proxySource })
        configuration.adapters = { adapters.current.adapters }
        let monitor = MonitorController(model: model, snapshotProvider: SystemSnapshotProvider(configuration: configuration),
                                        prober: URLSessionSiteProber(), observer: SystemNetworkChangeObserver(),
                                        notifier: notifier, paths: paths, adapterRegistry: adapters,
                                        eventStore: FaultEventStore(fileURL: appSupport.appendingPathComponent("events.jsonl")),
                                        diagnoser: ProxyDiagnoser(prober: URLSessionSiteProber()))
        self.monitor = monitor
        model.actions = AppActions.live(settingsStore: store, notifier: notifier, loginItem: loginItem,
                                         recheck: { [weak monitor] in monitor?.recheck() },
                                         reloadAdapters: { [weak monitor] in monitor?.reloadAdapters() },
                                         diagnoseSite: { [weak monitor] in monitor?.diagnose(siteID: $0) },
                                         settingsDidChange: { [weak monitor] in monitor?.settingsDidChange($0) })
        subscription = model.$overall.sink { assessment in onTone(NetworkToneMapper.map(assessment.severity)) }
    }

    public func start() { monitor.start() }
    public func stop() { monitor.stop() }
    public func recheck() { monitor.recheck() }
}

public extension NetworkBridge {
    /// 无窗口的一轮检测，使用 TunCanary CLI 的同一个 CheckRunner。
    static func collectOnce() async -> (model: AppModel, raw: String) {
        let settings = SettingsStore().load()
        let paths = KnownPaths.currentUser()
        let adapters = VPNAdapterRegistry(store: VPNAdapterStore(paths: paths)).current
        var configuration = SystemSnapshotProvider.Configuration(paths: paths, proxySource: { SettingsStore().load().proxySource })
        configuration.adapters = { adapters.adapters }
        let runner = CheckRunner(snapshotProvider: SystemSnapshotProvider(configuration: configuration), prober: URLSessionSiteProber(), settings: settings, paths: paths, adapters: adapters)
        let verdict = await runner.run(options: CheckOptions())
        let local = LocalAssessment(severity: Severity.worst(verdict.cards.map(\.severity)), cards: verdict.cards, faults: [], primaryReason: verdict.primaryReason,
            tunState: .unknown, vpnState: .unconfirmed, isInGracePeriod: false, intranetProbeEnabled: verdict.intranet.site != nil,
            tailnetDecision: verdict.tailnet, primaryServiceName: nil, mihomoDNSPort: nil, diagnosticNotes: [], evaluatedAt: verdict.checkedAt)
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MeowMac/tuncanary")
        let model = AppModel(settings: settings, local: local, lastCheckedAt: verdict.checkedAt, egressChecker: EgressIPChecker(), egressGeoClient: EgressGeoClient(),
            egressHistoryStore: EgressHistoryStore(fileURL: support.appendingPathComponent("egress-history.json")))
        var overall = OverallAssessment(local: local, connectivityFaults: [])
        overall.severity = verdict.severity; overall.reasons = verdict.reasons; overall.faults = verdict.faults
        model.overall = overall
        model.intranetDecision = verdict.intranet; model.tailnetDecision = verdict.tailnet
        model.siteHistory.record(verdict.siteResults)
        model.checkEgressIP()
        while model.isCheckingEgress { try? await Task.sleep(nanoseconds: 50_000_000) }
        return (model, verdict.renderJSON(redactor: model.redactor))
    }
}
