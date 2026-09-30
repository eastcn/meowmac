import Foundation
import Combine
import MeowMacCore
import TunCanaryCore
import TunCanarySystem
import TunCanaryProbe
import TunCanaryUI
import TunCanaryRuntime
import os

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
        let monitor = Self.makeMonitor(model: model, paths: paths, notifier: notifier,
            eventStore: FaultEventStore(fileURL: appSupport.appendingPathComponent("events.jsonl")))
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

    private static func makeMonitor(model: AppModel, paths: KnownPaths, notifier: UserNotifying, eventStore: FaultEventStore?) -> MonitorController {
        let adapters = VPNAdapterRegistry(store: VPNAdapterStore(paths: paths))
        var configuration = SystemSnapshotProvider.Configuration(paths: paths, proxySource: { SettingsStore().load().proxySource })
        configuration.adapters = { adapters.current.adapters }
        return MonitorController(model: model, snapshotProvider: SystemSnapshotProvider(configuration: configuration),
            prober: URLSessionSiteProber(), observer: SystemNetworkChangeObserver(), notifier: notifier,
            paths: paths, adapterRegistry: adapters, eventStore: eventStore,
            diagnoser: ProxyDiagnoser(prober: URLSessionSiteProber()))
    }
}

public extension NetworkBridge {
    /// 无窗口的一轮检测，与应用共用 MonitorController 配置。
    static func collectOnce(historyFile: URL? = nil) async throws -> (model: AppModel, raw: String, capture: NetworkCaptureInfo) {
        let settings = SettingsStore().load()
        let paths = KnownPaths.currentUser()
        let model = AppModel(settings: settings, egressChecker: EgressIPChecker(), egressGeoClient: EgressGeoClient(),
            egressHistoryStore: historyFile.map { EgressHistoryStore(fileURL: $0) })
        // 快照不申请权限、不发通知，事件和出口记录只写验收目录。
        let notifier = UserNotificationCenterNotifier(environment: AppBundleEnvironment(bundleIdentifier: nil, bundlePath: ""))
        let events = historyFile.map { FaultEventStore(fileURL: $0.deletingPathExtension().appendingPathExtension("events.jsonl")) }
        let monitor = makeMonitor(model: model, paths: paths, notifier: notifier, eventStore: events)
        var fullStarted = false, fullCompleted = false
        let progress = model.$checkProgress.sink { value in
            if value?.kind == .full { fullStarted = true }
            if fullStarted && value == nil { fullCompleted = true }
        }
        defer { progress.cancel(); monitor.stop() }
        monitor.start()
        monitor.recheck()
        let checkCompleted = try await SnapshotWait.waitWhile { !fullCompleted }
        let logger = Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "snapshot-network")
        if !checkCompleted { logger.warning("网络检测等待超时，保留已完成的数据") }
        // 自动采样每次只取一个目标；快照再走模型的手动检测入口。
        let egressDeadline = ProcessInfo.processInfo.systemUptime + 30
        var egressCompleted = try await SnapshotWait.waitWhile { model.isCheckingEgress }
        if egressCompleted {
            model.checkEgressIP()
            egressCompleted = try await SnapshotWait.waitWhile(timeout: max(0, egressDeadline - ProcessInfo.processInfo.systemUptime)) { model.isCheckingEgress }
        }
        if !egressCompleted { logger.warning("出口检测等待 30 秒超时，快照标记为未完成") }
        let capture = NetworkCaptureInfo(source: "monitorController", checkCompleted: checkCompleted,
            egressCompleted: egressCompleted, tunState: model.local.map { local in
                switch local.tunState { case .running: return "running"; case .inactive: return "inactive"; case .off: return "off"; case .unknown: return "unknown" }
            }, vpnState: model.local?.vpnState.rawValue)
        let verdict: CLIVerdict
        if let local = model.local {
            verdict = CLIVerdict.make(firstLocal: local, secondLocal: local,
                siteResults: model.siteHistory.results.values.compactMap(\.last), intranet: model.intranetDecision,
                tailnet: model.tailnetDecision, full: true, checkedAt: model.lastCheckedAt ?? Date(), configuredSites: settings.enabledSites)
        } else { verdict = CLIVerdict.timedOut(checkedAt: Date(), full: true) }
        guard var object = try JSONSerialization.jsonObject(with: Data(verdict.renderJSON(redactor: model.redactor).utf8)) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        object["status"] = model.overall.severity.rawValue
        object["capture"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(capture))
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return (model, String(decoding: raw, as: UTF8.self), capture)
    }
}

public struct NetworkCaptureInfo: Codable {
    public let source: String
    public let checkCompleted: Bool, egressCompleted: Bool
    public let tunState: String?, vpnState: String?
}

public enum SnapshotWait {
    /// 用单调时钟限制总等待时间。时钟和 sleep 可由离线用例注入。
    @MainActor public static func waitWhile(timeout: TimeInterval = 30,
        uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        pending: () -> Bool) async throws -> Bool {
        let deadline = uptime() + timeout
        while pending() {
            let remaining = deadline - uptime()
            guard remaining > 0 else { return false }
            try await sleep(min(0.05, remaining))
        }
        return true
    }
}
