import AppKit
import Foundation
import MeowMacCore
import MeowMacQuota
import MeowMacUI
import TunCanaryCore
import TunCanaryUI

@MainActor
enum ImmediateSettingsTests {
    static func callbacks() -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        let actions = ImmediateSettingsActions(state: state)
        var login: Bool?, terminal: CleanTerminal?, cat: String?, history = 0, imported = 0, shown = 0, config = 0, folder = 0, permission = 0
        state.onToggleLogin = { login = $0 }
        state.onSelectCleanTerminal = { terminal = $0 }
        state.onSelectCat = { cat = $0 }; state.onImportCat = { imported += 1 }; state.onShowCats = { shown += 1 }
        state.onImportCodexBarHistory = { history += 1 }; state.onOpenConfig = { config += 1 }; state.onShowConfigFolder = { folder += 1 }
        state.onOpenNotificationSystemSettings = { permission += 1 }
        state.availableCleanTerminals = [.ghostty, .terminal]
        actions.setLogin(true); actions.selectTerminal(.ghostty)
        guard login == true, !state.loginEnabled, terminal == .ghostty,
              actions.terminalTitle(.automatic) == "自动（当前：Ghostty）", !actions.terminalEnabled(.iterm) else { return false }
        actions.selectTerminal(.iterm)
        guard terminal == .ghostty, actions.cats.map(\.id) == CatPackageLoader.builtinIDs,
              actions.cats.first?.selected == true else { return false }
        actions.selectCat("builtin.round"); state.onImportCat(); state.onShowCats()
        actions.importHistory(); state.showsCodexBarImport = false; actions.importHistory()
        state.onOpenConfig(); state.onShowConfigFolder()
        state.onOpenNotificationSystemSettings()
        guard cat == "builtin.round", imported == 1, shown == 1, history == 1, config == 1, folder == 1, permission == 1 else { return false }
        var values: [NotificationSettings] = []
        state.onSetNotificationSettings = { values.append($0); state.notificationSettings = $0 }
        for category in NotificationCategory.allCases {
            actions.setCategory(category, enabled: false)
            guard !state.notificationSettings.categories.contains(category) else { return false }
            actions.setCategory(category, enabled: true)
            guard state.notificationSettings.categories.contains(category) else { return false }
        }
        actions.setNotifications(false)
        let count = values.count; actions.setCategory(.source, enabled: false)
        guard values.count == count, !state.notificationSettings.enabled else { return false }
        let controller = SettingsWindowController(state: state)
        controller.open(section: .general, load: false)
        defer { controller.closeWithoutConfirmation() }
        guard let window = controller.window else { return false }
        SettingsControlTestSupport.settle(window)
        guard let toggle = SettingsControlTestSupport.element(window, id: "settings.login") as? NSSwitch else { return false }
        login = nil; toggle.state = .on; _ = toggle.sendAction(toggle.action, to: toggle.target)
        guard login == true, !state.loginEnabled, toggle.state == .off,
              SettingsControlTestSupport.element(window, id: "settings.history") == nil else { return false }
        controller.open(section: .notifications, load: false)
        SettingsControlTestSupport.settle(window)
        guard let global = SettingsControlTestSupport.element(window, id: "settings.notifications") as? NSSwitch else { return false }
        state.onSetNotificationSettings = { values.append($0) }
        global.state = .on; _ = global.sendAction(global.action, to: global.target)
        guard !state.notificationSettings.enabled, global.state == .off, values.last?.enabled == true else { return false }
        state.onSetNotificationSettings = { values.append($0); state.notificationSettings = $0 }
        global.state = .on; _ = global.sendAction(global.action, to: global.target); SettingsControlTestSupport.settle(window)
        guard state.notificationSettings.enabled else { return false }
        guard let category = SettingsControlTestSupport.element(window, id: "alerts.notify.source.failure") as? NSButton else { return false }
        state.onSetNotificationSettings = { values.append($0) }
        category.state = .off; _ = category.sendAction(category.action, to: category.target)
        guard state.notificationSettings.categories.contains(.source), category.state == .on,
              values.last?.categories.contains(.source) == false else { return false }
        state.onSetNotificationSettings = { values.append($0); state.notificationSettings = $0 }
        global.state = .off; _ = global.sendAction(global.action, to: global.target); SettingsControlTestSupport.settle(window)
        return NotificationCategory.allCases.flatMap(NotificationSettings.ruleIDs).allSatisfy { id in
            (SettingsControlTestSupport.element(window, id: "alerts.notify." + id) as? NSButton)?.isEnabled == false
        }
    }
    static func previews() async -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MEOWMAC_UNIFIED_RENDER_DIR"] else { return true }
        do {
            let state = PanelPreviewRenderer.syntheticState()
            state.notificationsAuthorized = false
            state.availableCleanTerminals = [.ghostty, .terminal]
            let root = URL(fileURLWithPath: "build/acceptance/unified-settings/synthetic-app")
            CatRuntime.initialize(state: state, store: CatStore(rootURL: root), environment: [:])
            state.styleStore = StyleStore(rootURL: root)
            let client = CodexBarClient(path: "/synthetic/cli", executor: { _, _, _, _ in throw QuotaSourceError.invalid })
            let quota = QuotaCoordinator(state: state, config: LocalConfig(), history: QuotaHistoryStore(directory: root.appendingPathComponent("history")), client: client, sourceStore: QuotaSourceStore(root: root))
            let catalog = QuotaCatalog.usageNames.keys.sorted().compactMap { QuotaCatalog.entry(QuotaProvider(rawValue: $0)!) }
            var settings = NetworkSettingsTests.fixture()
            settings.sites = [Site(id: "example-search", name: "示例搜索", group: .mainland, url: URL(string: "https://search.example.com")!, isKey: false, inLightProbe: true)]
            let network = AppModel(settings: settings, now: { state.now() })
            let controller = SettingsWindowController(state: state, network: network, quotaCoordinator: quota, quotaCatalog: catalog)
            controller.open(load: false)
            defer { controller.closeWithoutConfirmation() }
            guard let window = controller.window else { return false }
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for section in SettingsSection.allCases {
                controller.open(section: section, load: false)
                for dark in [false, true] {
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    SettingsControlTestSupport.settle(window)
                    guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(section.rawValue + (dark ? "-dark.png" : "-light.png")))
                }
            }
            // 空渠道链接沿用生产面板容器，不展开页面或替换材质。
            state.applyQuotaSources(QuotaSourceList(providers: []))
            state.selectedTab = .quota
            let panel = PanelHosting.make(state: state)
            let panelWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
            panelWindow.contentViewController = panel.controller
            defer { panelWindow.contentViewController = nil; panelWindow.close() }
            for dark in [false, true] {
                panelWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                _ = try await PanelPreviewRenderer.settleLayout(panel.controller)
                SettingsControlTestSupport.settle(panelWindow)
                let view = panel.controller.view
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("quota-empty" + (dark ? "-dark.png" : "-light.png")))
            }
            return true
        } catch { print("统一设置预览失败：\(error)"); return false }
    }
    static func quotaLink() -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        state.applyQuotaSources(QuotaSourceList(providers: []))
        var section: SettingsSection?
        state.onOpenSettings = { section = $0 }
        state.openQuotaSourceSettings()
        return section == .quotaSources && state.quotaProviders.isEmpty && state.quotaEmptyMessage.contains("额度源")
    }
}
