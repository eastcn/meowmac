import Foundation
import MeowMacCore
import MeowMacUI

enum CustomRuleTests {
    static let now = RuleClockTests.base
    static func custom(level: HealthLevel = .warn, quota: Bool = false, reset: Date? = nil) -> Reminder {
        .init(kind: .custom, object: "u-12345678." + (quota ? "claude.primary" : "system"), tab: quota ? .quota : .system,
              level: level, title: "自定义规则", detail: "内存压力 80%，超过 70% · 已持续 10 分钟",
              sampledAt: now, resetAt: reset, provider: quota ? .claude : nil)
    }
    static var tests: [(String, @MainActor () throws -> Bool)] { [
        ("Core.CustomRule/真实评估、正文、猫形态与暂缓档位", {
            var config = LocalConfig(); config.alertRules.custom = [RuleClockTests.rule(duration: 0)]
            let state = PanelState(configResult: .init(config: config, error: nil)); state.now = { now }
            state.snapshot = RuleClockTests.input(0).system
            guard let reminder = state.allReminders.first(where: { $0.kind == .custom }), reminder.id == "custom.u-12345678.system",
                  reminder.canSnooze, reminder.tab == .system, state.health.level == .warn,
                  reminder.detail.contains("内存压力 80%"), reminder.detail.contains("超过 70%") else { return false }
            let notice = NotificationContent.notice(for: reminder, now: now)
            guard notice.title == reminder.title, notice.body == reminder.detail, !custom(level: .severe).canSnooze else { return false }
            var tracker = ReminderTracker(); tracker.reconcile(.init(reminders: [reminder]), now: now)
            tracker.snoozes[reminder.id] = try SnoozeRecord(reminder: reminder, acknowledgedAt: now, until: now.addingTimeInterval(3600))
            return tracker.health(now: now).level == .normal
        }),
        ("Core.CustomRule/去重、1 小时冷却与严重升级", {
            let warn = custom(), severe = custom(level: .severe)
            var records: [String: NotifiedRecord] = [:]
            let id = [warn.id]
            let same = NotificationTests.run([(0, [warn]), (60, [warn]), (120, [severe])], records: &records)
            records = [:]
            let short = NotificationTests.run([(0, [warn]), (60, []), (60 + 3599, [warn])], records: &records)
            records = [:]
            let long = NotificationTests.run([(0, [warn]), (60, []), (60 + 3600, [warn])], records: &records)
            return same == [id, [], id] && short == [id, [], []] && long == [id, [], id]
        }),
        ("Core.CustomRule/额度周期一次、新周期清暂缓和直到重置", {
            let reset = now.addingTimeInterval(18000)
            let issue = custom(quota: true, reset: reset)
            let record = try SnoozeRecord(reminder: issue, acknowledgedAt: now, until: reset)
            guard issue.isCycleReminder, record.cycleResetAt == reset else { return false }
            var records: [String: NotifiedRecord] = [:]
            let once = NotificationTests.run([(0, [issue]), (60, []), (7200, [issue])], records: &records)
            var newer = issue; newer.resetAt = reset.addingTimeInterval(18000)
            let next = NotificationTests.run([(8000, [newer])], records: &records)
            var tracker = ReminderTracker(); tracker.snoozes[issue.id] = record
            tracker.reconcile(.init(reminders: [newer]), now: now)
            return once == [[issue.id], [], []] && next == [[issue.id]] && tracker.snoozes.isEmpty
        }),
        ("Core.CustomRule/自定义额度暂缓重启与真实直到重置", {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/alert-rules/restart-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let issue = custom(quota: true, reset: now.addingTimeInterval(18000))
            let store = ReminderStore(rootURL: root)
            try store.save([SnoozeRecord(reminder: issue, acknowledgedAt: now, until: issue.resetAt!)])
            var config = LocalConfig()
            config.alertRules.custom = [.init(id: "u-12345678", name: "自定义额度", metric: "quota.remaining", comparison: .lte, threshold: 50)]
            let state = PanelState(configResult: .init(config: config, error: nil)); state.now = { now }
            state.initializeReminders(store: store)
            guard let restored = state.allReminders.first(where: { $0.kind == .custom }), restored.tab == .quota,
                  restored.provider == .claude, restored.title == "自定义额度", !restored.confirmed,
                  state.snoozedReminders.count == 1 else { return false }
            state.quotas[.claude] = .init(provider: .claude, source: "fixture", updatedAt: now,
                windows: [.init(usedPercent: 80, windowMinutes: 300, resetsAt: issue.resetAt, resetDescription: nil)], paceSummary: nil, credits: nil)
            try state.restoreReminder(issue.id)
            try state.snooze(issue.id, untilReset: true)
            return store.load().records.first?.cycleResetAt == issue.resetAt && state.snoozedReminders.count == 1
        }),
        ("Core.CustomRule/停用立即清除刚写过的暂缓文件", {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/alert-rules/disable-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ReminderStore(rootURL: root), issue = custom()
            try store.save([SnoozeRecord(reminder: issue, acknowledgedAt: now, until: now.addingTimeInterval(60))])
            var config = LocalConfig(); config.alertRules.custom = [RuleClockTests.rule(duration: 0)]
            let state = PanelState(configResult: .init(config: config, error: nil)); state.now = { now.addingTimeInterval(60) }
            state.initializeReminders(store: store)
            state.snapshot = RuleClockTests.input(60).system
            try state.snooze(issue.id, seconds: 3600)
            guard store.load().records.count == 1 else { return false }
            config.alertRules.custom[0].enabled = false; state.configResult = .init(config: config, error: nil)
            return store.load().records.isEmpty && state.allReminders.isEmpty
        }),
        ("Core.CustomRule/删除与停用清提醒、暂缓和通知记录", {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/alert-rules/custom-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = NotificationStore(rootURL: root)
            let issue = custom(); var tracker = ReminderTracker()
            tracker.reconcile(.init(reminders: [issue]), now: now)
            let coordinator = NotificationCoordinator(store: store, startedAt: now) { _ in }
            coordinator.process(tracker, batch: nil, now: now)
            guard coordinator.records[issue.id] != nil else { return false }
            tracker.snoozes[issue.id] = try SnoozeRecord(reminder: issue, acknowledgedAt: now, until: now.addingTimeInterval(3600))
            var batch = ReminderBatch(reminders: []); batch.activeCustomRuleIDs = []
            tracker.reconcile(batch, now: now); coordinator.process(tracker, batch: batch, now: now)
            return tracker.current.isEmpty && tracker.snoozes.isEmpty && coordinator.records.isEmpty && store.load().records.isEmpty
        }),
        ("Core.Notification/窗口和余额规则的开关独立", {
            var settings = NotificationSettings(); settings.rules["quota.low"] = false
            let low = Reminder(kind: .quotaLow, object: "claude.primary", tab: .quota, title: "额度剩余不足")
            let balance = BalanceAlertTests.balanceReminder()!
            var records: [String: NotifiedRecord] = [:]
            let first = NotificationTests.run([(0, [low, balance])], settings: settings, records: &records)
            settings.rules["quota.low"] = true; settings.rules["quota.balance"] = false; records = [:]
            let second = NotificationTests.run([(0, [low, balance])], settings: settings, records: &records)
            return first == [[balance.id]] && second == [[low.id]]
        }),
        ("Core.Notification/旧类别迁移和兼容写盘", {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/alert-rules/notify-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = NotificationStore(rootURL: root)
            try Data(#"{"schemaVersion":1,"settings":{"enabled":true,"categories":["network","quotaLow"]},"records":[]}"#.utf8).write(to: store.fileURL)
            let old = store.load().settings
            guard old.allows(ruleID: "quota.low"), old.allows(ruleID: "quota.balance"), old.allows(ruleID: "network.fault"),
                  !old.allows(ruleID: "system.disk"), old.allows(ruleID: "u-12345678") else { return false }
            try store.save(settings: old, records: [:])
            let rootObject = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
            let settings = rootObject["settings"] as! [String: Any]
            return settings["categories"] != nil && settings["rules"] != nil && store.load().settings == old
        })
    ] }
}
