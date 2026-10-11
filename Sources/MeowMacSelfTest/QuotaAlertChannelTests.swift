import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

/// 固定时钟与虚构额度，覆盖渠道设置到提醒、通知和持久化的实际路径。
@MainActor
enum QuotaAlertChannelTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func snapshot(_ provider: QuotaProvider, used: Double = 90) -> QuotaSnapshot {
        .init(provider: provider, source: "fixture", updatedAt: now,
              windows: [.init(usedPercent: used, windowMinutes: 300, resetsAt: now.addingTimeInterval(17940), resetDescription: nil)],
              paceSummary: nil, credits: nil)
    }
    static func config(_ json: String) throws -> LocalConfig { try JSONDecoder().decode(LocalConfig.self, from: Data(json.utf8)) }
    static func batch(_ config: LocalConfig, snapshots: [QuotaSnapshot]? = nil) -> ReminderBatch {
        ReminderCollector.collect(.init(system: nil, energy: nil, quotaUsedPercent: [], network: .green, failedSources: [:],
            fairSince: nil, now: now, quotaSnapshots: snapshots ?? [snapshot(.claude), snapshot(.codex)]), config: config)
    }
    static func disabledCleanup() throws -> Bool {
        let (root, state, model, coordinator, store) = try CustomRuleTests.editingFixture(RuleClockTests.rule(duration: 0))
        defer { try? FileManager.default.removeItem(at: root) }
        state.now = { now }
        state.quotas[.claude] = snapshot(.claude, used: 1)
        state.quotas[.codex] = snapshot(.codex, used: 1)
        let claude = "quotaPace.claude.primary", codex = "quotaPace.codex.primary"
        guard coordinator.records[claude] != nil, coordinator.records[codex] != nil else { return false }
        try state.snooze(claude, seconds: 3600)
        try state.snooze(codex, seconds: 3600)
        // 采集暂时不可用时，关闭设置仍要清掉旧提醒及记录。
        state.failures["quota"] = 1
        let disabled = try config(#"{"alertRules":{"quotaProviders":{"claude":{"paceEnabled":false}}}}"#)
        state.configResult = .init(config: disabled, error: nil)
        guard Set(state.allReminders.map(\.id)) == [codex], Set(store.load().records.map(\.key)) == [codex],
              Set(coordinator.records.keys) == [codex], Set(NotificationStore(rootURL: root).load().records.keys) == [codex],
              state.health.level == .normal else { return false }
        // 原始快照和节奏风险仍然可读。
        guard state.quotas[.claude]?.windows[0].usedPercent == 1,
              QuotaPace.calculate(window: state.quotas[.claude]!.windows[0], now: now)?.exhaustsBeforeReset == true else { return false }
        try ConfigStore.saveAlertRules(disabled.alertRules, to: model.configURL)
        let restarted = PanelState(configResult: ConfigStore.load(from: model.configURL)); restarted.now = { now }
        restarted.initializeReminders(store: store)
        return Set(restarted.allReminders.map(\.id)) == [codex]
            && restarted.allReminders.allSatisfy { !$0.confirmed }
    }
    static func persistence() throws -> Bool {
        let (root, _, model) = try AlertSettingsTests.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = #"{"keep":7,"quotaRemainingWarn":0.3,"alertRules":{"future":8,"quotaProviders":{"claude":{"paceEnabled":false,"remainingThreshold":5,"future":9}}}}"#
        try Data(json.utf8).write(to: model.configURL)
        let original = ConfigStore.load(from: model.configURL)
        try ConfigStore.saveAlertRules(original.config.alertRules, to: model.configURL)
        let loaded = ConfigStore.load(from: model.configURL)
        let ids = Set(batch(loaded.config).reminders.map(\.id))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: model.configURL)) as! [String: Any]
        let rootObject = object["alertRules"] as! [String: Any]
        let providers = rootObject["quotaProviders"] as! [String: Any]
        let claude = providers["claude"] as! [String: Any]
        guard ids == ["quotaLow.codex.primary", "quotaPace.codex.primary"], object["keep"] as? Int == 7,
              rootObject["future"] as? Int == 8, claude["future"] as? Int == 9 else { return false }
        try ConfigStore.saveAlertRules(loaded.config.alertRules, restoringDefaults: true, to: model.configURL)
        return Set(batch(ConfigStore.load(from: model.configURL).config).reminders.map(\.id)).count == 4
    }
    static func settingsControls() throws -> Bool {
        let (root, state, model) = try AlertSettingsTests.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        state.now = { now }; state.quotas[.claude] = snapshot(.claude); state.quotas[.codex] = snapshot(.codex)
        model.setQuotaEnabled(.pace, provider: .claude, enabled: false)
        guard model.error == nil, model.quotaStateText(.pace, provider: .claude) == "已停用",
              model.quotaStateText(.pace, provider: .codex) == "触发中", model.quotaStateText(.quotaLow, provider: .claude) == "触发中",
              model.setQuotaThreshold(.claude, text: "5"), model.quotaStateText(.quotaLow, provider: .claude) == "正常" else { return false }
        let before = try Data(contentsOf: model.configURL)
        guard !model.setQuotaThreshold(.claude, text: "91"), try Data(contentsOf: model.configURL) == before,
              model.setQuotaThreshold(.claude, text: ""), model.quotaThresholdText(.claude).isEmpty else { return false }
        model.setEnabled(BuiltinAlertRule.pace.id, false)
        model.setQuotaEnabled(.pace, provider: .claude, enabled: true)
        guard !state.allReminders.contains(where: { $0.kind == .quotaPace }) else { return false }
        model.setEnabled(BuiltinAlertRule.pace.id, true)
        guard state.allReminders.filter({ $0.kind == .quotaPace }).count == 2 else { return false }
        model.setQuotaEnabled(.quotaLow, provider: .claude, enabled: false)
        model.setQuotaEnabled(.pace, provider: .claude, enabled: false)
        model.confirmation = .defaults; model.confirm()
        return model.confirmation == nil && model.config.alertRules.quotaProviders.isEmpty
            && state.allReminders.filter({ $0.provider == .claude }).count == 2
    }
    static func nativeControls() throws -> Bool {
        let (root, state, _) = try AlertSettingsTests.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = SettingsWindowController(state: state); controller.alertConfigURL = root.appendingPathComponent("config.json")
        controller.open(section: .notifications, load: false)
        defer { controller.closeWithoutConfirmation() }
        guard let window = controller.window else { return false }
        controller.alertRules.expandedID = BuiltinAlertRule.pace.id; SettingsControlTestSupport.settle(window)
        guard let toggle = SettingsControlTestSupport.element(window, id: "alerts.channel.quota.pace.claude") as? NSSwitch else { return false }
        toggle.state = .off; _ = toggle.sendAction(toggle.action, to: toggle.target)
        guard ConfigStore.load(from: controller.alertConfigURL).config.alertRules.quotaProviders["claude"]?.paceEnabled == false else { return false }
        controller.alertRules.expandedID = BuiltinAlertRule.quotaLow.id; SettingsControlTestSupport.settle(window)
        guard let field = SettingsControlTestSupport.element(window, id: "alerts.channel.threshold.claude") as? NSTextField,
              let delegate = field.delegate else { return false }
        field.stringValue = "8"; delegate.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        guard ConfigStore.load(from: controller.alertConfigURL).config.alertRules.quotaProviders["claude"]?.remainingThreshold == 8 else { return false }
        if let path = ProcessInfo.processInfo.environment["MEOWMAC_QUOTA_ALERT_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for rule in [BuiltinAlertRule.quotaLow, .pace] {
                controller.alertRules.expandedID = rule.id
                for dark in [false, true] {
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    SettingsControlTestSupport.settle(window)
                    // 展开行位于滚动区域下方；让原生渠道控件进入可见区域后截图。
                    let id = "alerts.channel." + rule.id + ".claude"
                    if let control = SettingsControlTestSupport.element(window, id: id) as? NSView {
                        control.scrollToVisible(control.bounds.insetBy(dx: 0, dy: -90))
                    }
                    SettingsControlTestSupport.settle(window)
                    guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
                    try data.write(to: directory.appendingPathComponent(rule.id + (dark ? "-dark.png" : "-light.png")))
                    guard let content = PanelPreviewRenderer.quotaRulePNG(state: state, rule: rule, dark: dark) else { return false }
                    try content.write(to: directory.appendingPathComponent(rule.id + (dark ? "-content-dark.png" : "-content-light.png")))
                }
            }
        }
        return true
    }
    static var tests: [(String, @MainActor () throws -> Bool)] { [
        ("UI.QuotaAlertChannel/渠道开关阈值全局优先与恢复默认", { try settingsControls() }),
        ("UI.QuotaAlertChannel/原生渠道开关与阈值保存", { try nativeControls() }),
        ("Core.QuotaAlertChannel/余额渠道独立且不影响窗口", {
            let config = try config(#"{"alertRules":{"quotaProviders":{"deepseek":{"balanceEnabled":false},"claude":{"remainingEnabled":false}}}}"#)
            let snapshots = [snapshot(.claude), snapshot(.codex), BalanceAlertTests.snapshot("¥1"), BalanceAlertTests.snapshot("$1", provider: .opencodego)]
            let ids = Set(batch(config, snapshots: snapshots).reminders.map(\.id))
            return ids == ["quotaPace.claude.primary", "quotaPace.codex.primary", "quotaLow.codex.primary", "quotaLow.opencodego.balance"]
        }),
        ("Core.QuotaAlertChannel/坏覆盖逐条容错和保存拒绝越界", {
            let config = try config(#"{"quotaRemainingWarn":0.3,"alertRules":{"quotaProviders":{"claude":{"paceEnabled":false,"remainingThreshold":99},"codex":{"paceEnabled":"bad"},"future-provider":{"remainingEnabled":false}}}}"#)
            guard config.alertRules.diagnostics.count == 2, !config.alertRules.quotaEnabled(.pace, provider: .claude, config: config),
                  config.alertRules.quotaRemainingThreshold(.claude, config: config) == 30,
                  config.alertRules.quotaEnabled(.pace, provider: .codex, config: config),
                  !config.alertRules.quotaEnabled(.quotaLow, provider: QuotaProvider(rawValue: "future-provider")!, config: config) else { return false }
            var invalid = config.alertRules
            invalid.quotaProviders["claude"]?.remainingThreshold = 99
            return (try? invalid.validated()) == nil
        }),
        ("Core.QuotaAlertChannel/缺测停用清理通知暂缓与重启", { try disabledCleanup() }),
        ("Core.QuotaAlertChannel/渠道覆盖持久化未知字段与恢复默认", { try persistence() }),
        ("Core.QuotaAlertChannel/关闭 Claude 节奏保留 Codex 及 Claude 不足提醒", {
            let config = try config(#"{"alertRules":{"quotaProviders":{"claude":{"paceEnabled":false}}}}"#)
            let ids = Set(batch(config).reminders.map(\.id))
            return ids == ["quotaLow.claude.primary", "quotaLow.codex.primary", "quotaPace.codex.primary"]
        }),
        ("Core.QuotaAlertChannel/按渠道不足阈值不影响其他渠道", {
            let config = try config(#"{"alertRules":{"quotaProviders":{"claude":{"remainingThreshold":5}}}}"#)
            let ids = Set(batch(config).reminders.filter { $0.kind == .quotaLow }.map(\.id))
            return ids == ["quotaLow.codex.primary"]
        }),
        ("Core.QuotaAlertChannel/旧配置与节奏起点保持原合同", {
            let config = try config(#"{"quotaRemainingWarn":0.3}"#)
            let ids = Set(batch(config, snapshots: [snapshot(.claude, used: 75)]).reminders.map(\.id))
            let fast = QuotaPace.calculate(window: snapshot(.claude, used: 1).windows[0], now: now)
            let slow = QuotaPace.calculate(window: snapshot(.claude, used: 0.1).windows[0], now: now)
            return ids == ["quotaLow.claude.primary", "quotaPace.claude.primary"]
                && fast?.exhaustsBeforeReset == true && abs((fast?.secondsUntilExhaustion ?? 0) - 5940) < 0.001
                && slow?.exhaustsBeforeReset == false
        }),
    ] }
}
