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
