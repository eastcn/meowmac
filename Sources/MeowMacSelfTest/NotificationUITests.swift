import AppKit
import Foundation
import MeowMacCore
import MeowMacUI
import TunCanaryCore
import TunCanaryUI
import UserNotifications

/// D41 的存储、发送请求、点击路由、协调器和设置菜单。只用合成数据和临时目录。
@MainActor
enum NotificationUITests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meowmac-notify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func tracker(_ reminders: [Reminder]) -> ReminderTracker {
        var value = ReminderTracker(); value.reconcile(ReminderBatch(reminders: reminders), now: now); return value
    }

    /// 用 TunCanary 的真实出口状态机生成告警：IP 变化、地域超出范围、地域恢复。
    static func egressAlerts() -> [EgressAlert] {
        var state = EgressMonitorState(), settings = EgressMonitoringSettings()
        settings.notifyIPChanges = true
        settings.allowedRegions[EgressIPTarget.cloudflare.rawValue] = ["JP"]
        func observe(_ ip: String, _ country: String, _ offset: TimeInterval) -> [EgressAlert] {
            let at = now.addingTimeInterval(offset)
            let result = EgressIPResult(target: .cloudflare, checkedAt: at, ip: ip, ipVersion: .ipv4, location: nil, failure: nil)
            return state.record(EgressObservation(result: result, geo: EgressGeo(ip: ip, countryCode: country, checkedAt: at)), settings: settings)
        }
        return observe("203.0.113.1", "JP", 0) + observe("203.0.113.2", "US", 300) + observe("203.0.113.2", "US", 600)
            + observe("203.0.113.3", "JP", 900)
    }

    static var tests: [(String, @MainActor () async -> Bool)] { [
        ("UI.Notifications/存储往返、权限与坏文件改名", {
            guard let root = try? temporaryRoot() else { return false }
            defer { try? FileManager.default.removeItem(at: root) }
            let store = NotificationStore(rootURL: root)
            guard store.load().settings == NotificationSettings(), store.load().records.isEmpty else { return false }
            var settings = NotificationSettings(); settings.categories.insert(.source); settings.categories.remove(.disk)
            let record = NotifiedRecord(key: "disk.system", level: .warn, notifiedAt: now, cycleResetAt: now, recoveredAt: now, pendingAfterSnooze: true)
            guard (try? store.save(settings: settings, records: [record.key: record])) != nil else { return false }
            let loaded = NotificationStore(rootURL: root).load()
            let mode = (try? FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int) ?? 0
            guard loaded.settings == settings, loaded.records == [record.key: record], loaded.recoveryReason == nil, mode == 0o600 else { return false }
            try? Data("{broken".utf8).write(to: store.fileURL)
            let bad = NotificationStore(rootURL: root).load()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return bad.settings == NotificationSettings() && bad.records.isEmpty && bad.recoveryReason != nil
                && names.contains { $0.hasPrefix("notifications.json.bad-") } && !names.contains("notifications.json")
        }),
        ("UI.Notifications/请求内容与点击路由", {
            let notice = SystemNotice(key: "quotaLow.claude.primary", tab: .quota, subtitle: "额度不足", body: "Claude 5 小时窗口剩余 12%", sound: false)
            let request = MeowMacNotifier.request(for: notice, at: now)
            let loud = MeowMacNotifier.request(for: SystemNotice(key: "network.dns", tab: .network, subtitle: "网络故障", body: "DNS", sound: true), at: now)
            let content = request.content
            return request.identifier == "meowmac.quotaLow.claude.primary.1800000000" && content.title == "MeowMac"
                && content.subtitle == "额度不足" && content.body == "Claude 5 小时窗口剩余 12%" && content.sound == nil
                && content.threadIdentifier == "meowmac.quota" && loud.content.sound != nil
                && MeowMacNotifier.tab(for: content.userInfo) == .quota
                && MeowMacNotifier.tab(for: [:]) == .network && MeowMacNotifier.tab(for: ["tab": "bogus"]) == .network
        }),
        ("UI.Notifications/包外不碰系统通知中心", {
            let notifier = MeowMacNotifier(environment: AppBundleEnvironment(bundleIdentifier: nil, bundlePath: ""))
            let granted = await notifier.requestAuthorization()
            let status = await notifier.authorizationStatus()
            await notifier.deliver(SystemNotice(key: "disk.system", tab: .system, subtitle: "磁盘不足", body: "示例", sound: false))
            return !notifier.isAvailable && !granted && status == .denied
        }),
        ("UI.Notifications/协调器去重、重启不重发与开关保存", {
            guard let root = try? temporaryRoot() else { return false }
            defer { try? FileManager.default.removeItem(at: root) }
            var sent: [SystemNotice] = []
            let disk = NotificationTests.disk()
            let first = NotificationCoordinator(store: NotificationStore(rootURL: root)) { sent.append($0) }
            first.process(tracker([disk]), now: now)
            first.process(tracker([disk]), now: now.addingTimeInterval(60))
            let restarted = NotificationCoordinator(store: NotificationStore(rootURL: root)) { sent.append($0) }
            restarted.process(tracker([disk]), now: now.addingTimeInterval(120))
            guard sent.map(\.key) == ["disk.system"], sent[0].subtitle == "磁盘不足", sent[0].tab == .system else { return false }
            var off = restarted.settings; off.categories.remove(.network)
            guard restarted.update(off) else { return false }
            let reloaded = NotificationCoordinator(store: NotificationStore(rootURL: root)) { sent.append($0) }
            // 网络类关闭后不发，但记录照样维护；网络正文经过脱敏。
            reloaded.process(tracker([disk, NotificationTests.network(level: .severe)]), now: now.addingTimeInterval(180),
                             redact: { $0.replacingOccurrences(of: "代理", with: "[已隐藏]") })
            var on = reloaded.settings; on.categories.insert(.network); reloaded.update(on)
            let quota = NotificationTests.quota(resetAt: nil)
            reloaded.process(tracker([disk, quota]), now: now.addingTimeInterval(240))
            return reloaded.settings.categories.contains(.network) && !reloaded.records.isEmpty
                && reloaded.records["network.group.overseas"] != nil
                && sent.map(\.key) == ["disk.system", "quotaLow.claude.primary"]
        }),
        ("UI.Notifications/出口告警：变化与超出范围发送，恢复不发", {
            guard let root = try? temporaryRoot() else { return false }
            defer { try? FileManager.default.removeItem(at: root) }
            let alerts = egressAlerts()
            var sent: [SystemNotice] = []
            let coordinator = NotificationCoordinator(store: NotificationStore(rootURL: root)) { sent.append($0) }
            for alert in alerts { coordinator.process(alert, redact: { $0 }) }
            var off = coordinator.settings; off.categories.remove(.egress); coordinator.update(off)
            for alert in alerts { coordinator.process(alert, redact: { $0 }) }
            let subtitles = sent.map(\.subtitle)
            return alerts.count == 4
                && subtitles == ["出口 IP 已变化", "出口地域超出允许范围", "出口 IP 已变化"]
                && sent[1].sound && !sent[0].sound && sent.allSatisfy { $0.tab == .network }
                && sent[1].body.hasSuffix("：美国") && sent[1].body.contains(EgressIPTarget.cloudflare.host)
        }),
        ("UI.Notifications/设置子菜单与提醒回调", {
            let state = PanelPreviewRenderer.syntheticState()
            var saved: NotificationSettings?, opened = false, prepared = 0
            state.onSetNotificationSettings = { saved = $0 }
            state.onOpenNotificationSystemSettings = { opened = true }
            state.onPrepareNotificationMenu = { prepared += 1 }
            state.notificationsAuthorized = false
            let settingsMenu = SettingsMenu.make(state: state)
            guard let menu = settingsMenu.items.first(where: { $0.title == "系统通知" })?.submenu else { return false }
            // 直接经 NSApplication 发送菜单动作；performActionForItem 在单独运行时不会触发。
            func press(_ index: Int) { _ = menu.items[index].action.map { NSApplication.shared.sendAction($0, to: menu.items[index].target, from: menu.items[index]) } }
            let titles = menu.items.map(\.title)
            let expected = ["未授权，打开系统设置…", "", "发送系统通知", ""] + NotificationCategory.allCases.map(\.displayName)
            guard titles == expected, menu.items[2].state == .on,
                  menu.items.first(where: { $0.title == "数据源失效" })?.state == .off,
                  menu.items.first(where: { $0.title == "网络故障" })?.state == .on else { return false }
            press(0)
            press(titles.firstIndex(of: "数据源失效")!)
            guard opened, saved?.categories.contains(.source) == true, saved?.enabled == true else { return false }
            press(2)
            guard saved?.enabled == false else { return false }
            state.notificationSettings.enabled = false; state.notificationsAuthorized = true
            let disabled = SettingsMenu.notificationMenu(state: state)
            let categoryItems = disabled.items.filter { item in NotificationCategory.allCases.contains { $0.displayName == item.title } }
            guard disabled.items.first?.title == "发送系统通知", categoryItems.count == 9, categoryItems.allSatisfy({ !$0.isEnabled }) else { return false }
            var refreshed: ReminderTracker?
            state.onRemindersRefreshed = { refreshed = $0 }
            state.refreshReminders()
            return prepared == 2 && refreshed != nil
        }),
    ] }
}
