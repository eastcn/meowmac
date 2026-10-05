import Foundation
import MeowMacCore

/// 余额偏低提醒（D13 2026-10-05 补充）。只用虚构金额。
enum BalanceAlertTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func snapshot(_ amount: String, provider: QuotaProvider = .deepseek) -> QuotaSnapshot {
        QuotaSnapshot(provider: provider, source: "api", updatedAt: now.addingTimeInterval(-60), windows: [], paceSummary: nil,
                      credits: nil, balance: QuotaBalance(amount: amount, detail: nil))
    }
    static func collect(_ snapshots: [QuotaSnapshot], warn: [String: Double] = [:], failed: [String: Int] = [:]) -> ReminderBatch {
        ReminderCollector.collect(HealthInputs(system: nil, energy: nil, quotaUsedPercent: [], network: .green, failedSources: failed,
                                               fairSince: nil, now: now, quotaSnapshots: snapshots, balanceWarn: warn), config: LocalConfig())
    }
    static func balanceReminder() -> Reminder? { collect([snapshot("¥8.20")]).reminders.first { $0.id == "quotaLow.deepseek.balance" } }

    static var tests: [(String, @MainActor () async -> Bool)] { [
        ("Core.Balance/金额与币种解析", {
            QuotaBalance(amount: "¥1,234.50", detail: nil).value == 1234.5 && QuotaBalance(amount: "¥1,234.50", detail: nil).currency == "¥"
                && QuotaBalance(amount: "$5", detail: nil).value == 5 && QuotaBalance(amount: "$5", detail: nil).currency == "$"
                && QuotaBalance(amount: "未知", detail: nil).value == nil
                && QuotaBalance(amount: "¥8.20 (paid ¥5)", detail: nil).value == 8.2
                && QuotaBalance(amount: "CNY 12", detail: nil).format(10) == "CNY 10" && QuotaBalance(amount: "¥12", detail: nil).format(10) == "¥10"
                && MetricFormat.money(10) == "10" && MetricFormat.money(8.2) == "8.20"
        }),
        ("Core.Balance/低于默认阈值 10 提醒，等于或高于不提醒", {
            guard let reminder = balanceReminder() else { return false }
            let equal = collect([snapshot("¥10.00")]).reminders.filter { $0.kind == .quotaLow }
            let above = collect([snapshot("¥12.00")])
            return reminder.title == "DeepSeek 余额不足" && reminder.detail == "余额 ¥8.20，低于 ¥10" && reminder.level == .warn
                && reminder.resetAt == nil && reminder.provider == .deepseek && reminder.tab == .quota && reminder.confirmed
                && reminder.kind.allowsSnooze && equal.isEmpty && above.reminders.isEmpty
                && above.confirmedKeys.contains("quotaLow.deepseek.balance")
        }),
        ("Core.Balance/按渠道阈值，0 不提醒，金额解析不出不提醒", {
            let custom = collect([snapshot("¥12.00")], warn: ["deepseek": 20]).reminders.first
            let off = collect([snapshot("¥1.00")], warn: ["deepseek": 0]).reminders
            let unknown = collect([snapshot("余额未知")])
            return custom?.detail == "余额 ¥12.00，低于 ¥20" && off.isEmpty
                && unknown.reminders.isEmpty && !unknown.confirmedKeys.contains("quotaLow.deepseek.balance")
        }),
        ("Core.Balance/数据源失效时不确认、不算恢复", {
            let batch = collect([snapshot("¥8.20")], failed: ["quota.deepseek": 2])
            return batch.reminders.first?.confirmed == false && !batch.confirmedKeys.contains("quotaLow.deepseek.balance")
        }),
        ("Core.Balance/健康档位为提醒", {
            let summary = HealthEvaluator.evaluate(HealthInputs(system: nil, energy: nil, quotaUsedPercent: [], network: .green, failedSources: [:],
                                                                fairSince: nil, now: now, quotaSnapshots: [snapshot("¥8.20")]), config: LocalConfig())
            return summary.level == .warn && summary.worst?.message == "DeepSeek 余额不足"
        }),
        ("Core.Balance/通知正文与类别", {
            guard let reminder = balanceReminder() else { return false }
            let notice = NotificationContent.notice(for: reminder, now: now)
            return notice.subtitle == "额度不足" && notice.body == "DeepSeek 余额 ¥8.20，低于 ¥10" && notice.tab == .quota
        }),
        ("Core.Balance/通知去重、暂缓与恢复 1 小时规则", {
            guard let reminder = balanceReminder() else { return false }
            var records: [String: NotifiedRecord] = [:]
            let short = NotificationTests.run([(0, [reminder]), (600, [reminder]), (660, []), (660 + 3599, [reminder])], records: &records)
            records = [:]
            let long = NotificationTests.run([(0, [reminder]), (60, []), (60 + 3600, [reminder])], records: &records)
            records = [:]
            let snoozed = NotificationTests.run([(0, [reminder])], snoozed: [reminder.id], records: &records)
            var off = NotificationSettings(); off.categories.remove(.quotaLow)
            records = [:]
            let disabled = NotificationTests.run([(0, [reminder])], settings: off, records: &records)
            let id = [reminder.id]
            return short == [id, [], [], []] && long == [id, [], id] && snoozed == [[]] && disabled == [[]]
        }),
        ("Core.Balance/本机清单读写阈值与旧文件兼容", {
            let old = #"{"providers":["deepseek"]}"#
            let new = #"{"providers":["deepseek"],"balanceWarn":{"deepseek":25}}"#
            let bad = #"{"providers":["deepseek"],"balanceWarn":{"deepseek":-1}}"#
            let decoder = JSONDecoder()
            guard let legacy = try? decoder.decode(QuotaSourceList.self, from: Data(old.utf8)).validated(),
                  let current = try? decoder.decode(QuotaSourceList.self, from: Data(new.utf8)).validated(),
                  let invalid = try? decoder.decode(QuotaSourceList.self, from: Data(bad.utf8)) else { return false }
            var list = current; list.balanceWarn["deepseek"] = 0
            guard let data = try? JSONEncoder().encode(list), let round = try? decoder.decode(QuotaSourceList.self, from: data) else { return false }
            return legacy.balanceThreshold(.deepseek) == 10 && current.balanceThreshold(.deepseek) == 25
                && (try? invalid.validated()) == nil && round.balanceThreshold(.deepseek) == 0
        }),
    ] }
}
