import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum AlertSettingsTests {
    static func fixture() throws -> (URL, PanelState, AlertRuleSettingsModel) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/alert-rules/settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = PanelState(configResult: .init(config: LocalConfig(), error: nil))
        let store = NotificationStore(rootURL: root)
        state.onSetNotificationSettings = { settings in
            do { try store.save(settings: settings, records: [:]); state.notificationSettings = store.load().settings }
            catch { print("测试通知写盘失败：\(error)") }
        }
        return (root, state, AlertRuleSettingsModel(state: state, configURL: root.appendingPathComponent("config.json")))
    }
    static func controls() throws -> Bool {
        let (root, state, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for rule in BuiltinAlertRule.allCases {
            model.setEnabled(rule.id, false)
            guard ConfigStore.load(from: model.configURL).config.alertRules.enabled(rule, config: state.configResult.config) == false else { return false }
            model.setEnabled(rule.id, true)
            if rule != .cooling {
                model.setNotify(rule.id, false)
                guard !NotificationStore(rootURL: root).load().settings.allows(ruleID: rule.id) else { return false }
                model.setNotify(rule.id, true)
            }
            if let range = rule.thresholdRange {
                let value = range.upperBound
                guard model.setField(rule, field: .threshold, text: alertNumber(value)), model.value(rule).threshold == value,
                      !model.setField(rule, field: .threshold, text: alertNumber(value + 1)), model.value(rule).threshold == value else { return false }
            }
            if model.value(rule).durationSeconds != nil {
                guard model.setField(rule, field: .durationSeconds, text: "12"), model.value(rule).durationSeconds == 720,
                      !model.setField(rule, field: .durationSeconds, text: "0") else { return false }
            }
        }
        guard model.setField(.cooling, field: .fairThermalSeconds, text: "10"), model.setField(.cooling, field: .fanHighSeconds, text: "12"),
              !model.setField(.cooling, field: .fanHighSeconds, text: "121") else { return false }
        model.setNotifications(false); model.setNotify("system.disk", false)
        guard !NotificationStore(rootURL: root).load().settings.enabled, model.notify("system.disk") else { return false }
        model.setNotifications(true)
        model.beginNew(); guard !model.canSaveDraft else { return false }
        model.draft?.name = "Swap 偏高"; model.draft?.threshold = 6; model.draft?.durationSeconds = 60
        model.draftNotify = false
        guard model.saveDraft(), model.custom.count == 1, ConfigStore.load(from: model.configURL).config.alertRules.custom[0].threshold == 6 else { return false }
        let saved = model.custom[0]
        model.beginEdit(saved); model.draft?.level = .severe; model.draft?.comparison = .lte
        guard model.saveDraft(), model.custom[0].level == .severe, model.custom[0].comparison == .lte else { return false }
        model.confirmation = .defaults; model.confirm()
        guard model.value(.memory).threshold == 61, model.value(.disk).threshold == 10,
              model.custom.count == 1, model.notify("system.disk"), !model.notify(saved.id) else { return false }
        model.confirmation = .delete(saved.id); model.confirm()
        return model.custom.isEmpty && ConfigStore.load(from: model.configURL).config.alertRules.custom.isEmpty
    }
    static func notificationOrder() throws -> Bool {
        let (root, state, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var notices: [SystemNotice] = []
        let coordinator = NotificationCoordinator(store: NotificationStore(rootURL: root), startedAt: RuleClockTests.base) { notices.append($0) }
        state.now = { RuleClockTests.base }
        state.onSetNotificationSettings = { settings in if coordinator.update(settings) { state.notificationSettings = coordinator.settings } }
        state.onRemindersRefreshed = { tracker, batch in coordinator.process(tracker, batch: batch, now: state.now()) }
        state.snapshot = RuleClockTests.input(0).system
        model.beginNew(); model.draft?.name = "内存偏高"; model.draft?.metric = "memory.pressure"
        model.draft?.threshold = 70; model.draft?.durationSeconds = 0; model.draftNotify = false
        guard model.saveDraft(), state.allReminders.contains(where: { $0.kind == .custom }) else { return false }
        return notices.isEmpty && !NotificationStore(rootURL: root).load().settings.allows(ruleID: model.custom[0].id)
    }
    static func nativeFields() throws -> Bool {
        let (root, state, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = SettingsWindowController(state: state); controller.alertConfigURL = root.appendingPathComponent("config.json")
        controller.open(section: .notifications, load: false)
        defer { controller.closeWithoutConfirmation() }
        guard SettingsSection(rawValue: "notifications")?.title == "提醒", let window = controller.window else { return false }
        controller.alertRules.expandedID = "system.memory"; SettingsControlTestSupport.settle(window)
        guard let field = SettingsControlTestSupport.element(window, id: "alerts.field.system.memory.threshold") as? NSTextField,
              let delegate = field.delegate else { return false }
        field.stringValue = "75"; delegate.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        guard ConfigStore.load(from: controller.alertConfigURL).config.alertRules.memoryRule(config: state.configResult.config).threshold == 75 else { return false }
        SettingsControlTestSupport.settle(window)
        field.stringValue = "100"; delegate.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        guard field.stringValue == "75", controller.alertRules.error?.contains("1～99") == true else { return false }
        guard let toggle = SettingsControlTestSupport.element(window, id: "alerts.enabled.system.memory") as? NSSwitch else { return false }
        toggle.state = .off; _ = toggle.sendAction(toggle.action, to: toggle.target)
        guard controller.alertRules.stateText("system.memory") == "已停用", !controller.alertRules.value(.memory).enabled! else { return false }
        guard let add = SettingsControlTestSupport.element(window, id: "alerts.add") as? NSButton else { return false }
        _ = add.sendAction(add.action, to: add.target)
        SettingsControlTestSupport.settle(window)
        guard controller.alertRules.draft != nil else { return false }
        controller.alertRules.draft = nil; SettingsControlTestSupport.settle(window)
        return ConfigStore.load(from: controller.alertConfigURL).config.alertRules.effective(.memory, config: state.configResult.config).threshold == 75
    }
    static func limitsAndBroken() throws -> Bool {
        let (root, state, model) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var config = LocalConfig(); config.alertRules.custom = (0..<32).map { .init(id: String(format: "u-%08x", $0), name: "规则", metric: "swap.used", threshold: 4) }
        state.configResult = .init(config: config, error: nil)
        guard !model.canAdd else { return false }; model.beginNew(); guard model.draft == nil else { return false }
        let original = Data("broken".utf8); try original.write(to: model.configURL)
        state.configResult = ConfigStore.load(from: model.configURL)
        model.setEnabled("system.memory", false)
        let read = try Data(contentsOf: model.configURL)
        return state.configResult.error != nil && model.error != nil && read == original
    }
    static func previews() async -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MEOWMAC_ALERT_RENDER_DIR"] else { return true }
        do {
            let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let state = PanelPreviewRenderer.syntheticState(); state.configResult = .init(config: LocalConfig(), error: nil)
            state.notificationSettings = NotificationSettings(); state.notificationsAuthorized = true
            let controller = SettingsWindowController(state: state)
            controller.open(section: .notifications, load: false)
            defer { controller.closeWithoutConfirmation() }
            guard let window = controller.window else { return false }
            func capture(_ name: String, _ target: NSWindow) throws {
                SettingsControlTestSupport.settle(target)
                guard let view = target.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let _ = target.contentView else { throw CocoaError(.fileWriteUnknown) }
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            }
            window.appearance = NSAppearance(named: .aqua); try capture("light", window)
            window.appearance = NSAppearance(named: .darkAqua); try capture("dark", window)
            window.appearance = NSAppearance(named: .aqua); controller.alertRules.expandedID = "system.memory"; try capture("expanded", window)
            controller.alertRules.beginNew(); controller.alertRules.draft?.name = "Swap 偏高"
            for _ in 0..<5 { SettingsControlTestSupport.settle(window) }
            guard let sheet = window.attachedSheet else { print("新建规则 sheet 未挂到真实设置窗口"); return false }
            try capture("new-sheet", sheet)
            controller.alertRules.draft = nil
            return true
        } catch { print("提醒规则预览失败：\(error)"); return false }
    }
}
