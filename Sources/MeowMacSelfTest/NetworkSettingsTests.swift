import AppKit
import Foundation
import MeowMacUI
import TunCanaryCore
import TunCanaryUI

/// 所有读写都留在字典中，不使用真实 suite 或持久域。
final class NetworkMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = NSNumber(value: value) }
    override func removeObject(forKey key: String) { values[key] = nil }
}

@MainActor
enum NetworkSettingsTests {
    static func fixture() -> AppSettings {
        var settings = AppSettings()
        settings.sites = []
        settings.intranetURL = URL(string: "https://office.example.test")
        settings.canaryHost = "probe.example.net"
        settings.checkPages = []
        settings.proxyClient = .manual
        settings.manualProxy = ManualProxyConfig(fakeIPRange: "198.18.0.0/15", dnsPort: 1053, coreProcessName: "example-proxy")
        settings.expectedDNS = ["198.18.0.2"]
        settings.disconnectedDNSRule = .equals
        return settings
    }
    static func roundTrip() -> Bool {
        let defaults = NetworkMemoryDefaults()
        let store = SettingsStore(defaults: defaults)
        var received: AppSettings?
        let network = AppModel(settings: fixture())
        network.actions = .live(settingsStore: store, notifier: NotificationUITests.SpyNotifier(),
            loginItem: MainAppLoginItemController(environment: AppBundleEnvironment(bundleIdentifier: nil, bundlePath: "")), recheck: {}, settingsDidChange: { received = $0 })
        let model = NetworkSettingsModel(network: network); model.open()
        network.settingsDraft.addSite()
        network.settingsDraft.sites[0].name = "示例站点"
        network.settingsDraft.sites[0].url = "https://www.example.org"
        network.settingsDraft.sites[0].inLightProbe = true
        network.settingsDraft.egressIntervalMinutes = "10"
        network.settingsDraft.disconnectedDNSRule = .empty
        network.settingsDraft.connectedDNSRule = .notSet
        network.settingsDraft.localCheckInterval = "30"
        network.settingsDraft.lightProbeInterval = "240"
        guard network.canSaveSettings, model.save() else { return false }
        let loaded = store.load()
        guard loaded == network.settings, received == loaded, loaded.sites.count == 1,
              loaded.sites[0].url.absoluteString == "https://www.example.org", loaded.localCheckInterval == 30,
              loaded.lightProbeInterval == 240, loaded.egressMonitoring.interval == 600,
              loaded.disconnectedDNSRule == .empty else { return false }
        network.settingsDraft.localCheckInterval = "99"; model.cancel()
        return network.settingsDraft.localCheckInterval == "30" && store.load() == loaded
    }
    static func boundaries() -> Bool {
        let network = AppModel(settings: fixture()), model = NetworkSettingsModel(network: AppModel(settings: fixture()))
        // 每轮从已保存草稿重建，边界值既检查校验也检查保存按钮状态。
        let target = model.network
        for (key, values, tab) in [
            (\SettingsDraft.localCheckInterval, [4, 5, 3600, 3601], NetworkSettingsTab.frequency),
            (\SettingsDraft.lightProbeInterval, [14, 15, 86400, 86401], .frequency),
            (\SettingsDraft.egressIntervalMinutes, [4, 5, 1440, 1441], .egress)
        ] {
            for (i, value) in values.enumerated() {
                target.settingsDraft = SettingsDraft(settings: target.settings)
                target.settingsDraft[keyPath: key] = String(value)
                // 与默认值相同的 5 分钟仍通过校验，但不是改动；添加另一个有效改动。
                target.settingsDraft.canaryHost = "new.example.test"
                let valid = i == 1 || i == 2
                guard target.canSaveSettings == valid, model.errorTabs.contains(tab) == !valid else { return false }
            }
        }
        target.settingsDraft = SettingsDraft(settings: target.settings)
        target.settingsDraft.intranetURL = "invalid URL"
        guard !target.canSaveSettings, model.errorTabs == [.sites] else { return false }
        network.settingsDraft.addSite(); network.settingsDraft.sites[0].url = "file:///tmp/example"
        return !network.canSaveSettings && !network.settingsValidation.siteErrors.isEmpty
    }
    static func status() -> Bool {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let network = AppModel(settings: fixture(), now: { now }, timeZone: TimeZone(secondsFromGMT: 0)!)
        let model = NetworkSettingsModel(network: network)
        network.checkProgress = CheckProgress(kind: .full, completed: 1, total: 1)
        network.lastCheckedAt = now.addingTimeInterval(-1)
        network.settingsDraft.localCheckInterval = "30"
        guard model.save(), model.statusText.contains("正在重新检测") else { return false }
        // 旧轮次收尾和单独本机轮次都不能宣称保存后站点检测完成。
        network.checkProgress = nil
        now = now.addingTimeInterval(1)
        network.checkProgress = CheckProgress(kind: .local)
        network.lastCheckedAt = now; network.checkProgress = nil
        guard model.completedAt == nil else { return false }
        network.checkProgress = CheckProgress(kind: .light, completed: 0, total: 1)
        network.lastCheckedAt = now; network.checkProgress = nil
        guard model.completedAt == nil else { return false }
        network.checkProgress = CheckProgress(kind: .light, completed: 1, total: 1)
        now = now.addingTimeInterval(1); network.lastCheckedAt = now; network.checkProgress = nil
        guard model.completedAt == now, model.statusText.contains("已按新设置完成"), model.statusText.contains("出口检测按间隔进行，下次约"), !model.statusText.contains("出口检测已完成") else { return false }
        var settings = fixture(), state = EgressMonitorState(), control = EgressControl()
        control.manualNextAttempt = now.addingTimeInterval(600); control.nextAttempt = control.manualNextAttempt
        state.controls[EgressIPTarget.cloudflare.rawValue] = control
        guard NetworkSettingsModel.egressStatus(settings: settings, state: state, now: now, timeZone: .current).contains("冷却中") else { return false }
        settings.egressMonitoring.automatic = false
        return NetworkSettingsModel.egressStatus(settings: settings, state: state, now: now, timeZone: .current).contains("已关闭")
    }
    static func click(_ window: NSWindow, id: String) -> Bool {
        SettingsControlTestSupport.settle(window)
        guard let button = SettingsControlTestSupport.element(window, id: id) as? NSButton else { return false }
        guard button.sendAction(button.action, to: button.target) else { return false }
        SettingsControlTestSupport.settle(window)
        return true
    }
    static func controlsAndPreviews() -> Bool {
        let network = AppModel(settings: fixture())
        let controller = NetworkSettingsController(network: network); controller.present()
        guard let window = controller.window else { return false }
        defer { window.close() }
        controller.present(); guard controller.window === window else { return false }
        network.settingsDraft.addSite()
        network.settingsDraft.sites[0].name = "示例站点"
        network.settingsDraft.sites[0].url = "https://www.example.org"
        do {
            for tab in NetworkSettingsTab.allCases {
                guard click(window, id: "network.tab.\(tab)"), controller.model.tab == tab else { return false }
                if tab == .sites {
                    guard SettingsControlTestSupport.element(window, id: "ID") == nil,
                          SettingsControlTestSupport.element(window, id: "network.proxyDiagnostics") == nil else { print("站点页仍有额外字段"); return false }
                }
                if tab == .proxy {
                    guard let toggle = SettingsControlTestSupport.element(window, id: "network.proxyDiagnostics") as? NSButton else { print("代理页诊断开关未定位"); return false }
                    let previous = network.settingsDraft.proxyDiagnosticsEnabled
                    toggle.state = previous ? .off : .on
                    guard toggle.sendAction(toggle.action, to: toggle.target), network.settingsDraft.proxyDiagnosticsEnabled != previous else { return false }
                }
                if tab == .frequency {
                    guard let field = SettingsControlTestSupport.element(window, id: "network.localInterval") as? NSTextField else { return false }
                    field.stringValue = "4"
                    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                    SettingsControlTestSupport.settle(window)
                    guard network.settingsDraft.localCheckInterval == "4", !network.canSaveSettings,
                          controller.model.errorTabs.contains(.frequency),
                          SettingsControlTestSupport.element(window, id: "network.save")?.isAccessibilityEnabled() == false else { return false }
                }
                if let path = ProcessInfo.processInfo.environment["MEOWMAC_CONFIG_RENDER_DIR"] {
                    let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for dark in [false, true] {
                        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); SettingsControlTestSupport.settle(window)
                        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("network-settings-\(tab)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
            guard click(window, id: "network.cancel") else { return false }
            return controller.window == nil && !network.settingsDraft.hasChanges(comparedTo: network.settings)
        } catch { print("网络设置预览失败：\(error)"); return false }
    }
}
