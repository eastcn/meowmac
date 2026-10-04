import Foundation
import MeowMacCore

/// D41 的判定和文案。只用合成数据。
enum NotificationTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let utc = TimeZone(identifier: "UTC")!

    static func disk(confirmed: Bool = true) -> Reminder {
        Reminder(kind: .disk, object: "system", tab: .system, title: "磁盘剩余不足", confirmed: confirmed,
                 facts: ReminderFacts(diskRemainingFraction: 0.08, diskAvailableBytes: 41_000_000_000))
    }
    static func quota(resetAt: Date?, level: HealthLevel = .warn) -> Reminder {
        Reminder(kind: .quotaLow, object: "claude.primary", tab: .quota, level: level, title: "Claude 5 小时额度剩余不足",
                 resetAt: resetAt, provider: .claude, facts: ReminderFacts(subject: "Claude 5 小时窗口", remainingPercent: 12))
    }
    static func network(level: HealthLevel) -> Reminder {
        Reminder(kind: .network, object: "group.overseas", tab: .network, level: level, title: "海外站点连续 3 轮探测失败",
                 facts: ReminderFacts(hint: "检查代理是否运行"))
    }

    /// 连续几轮判定，返回每轮发送的键。
    static func run(_ rounds: [(TimeInterval, [Reminder])], settings: NotificationSettings = NotificationSettings(),
                    snoozed: Set<String> = [], records: inout [String: NotifiedRecord]) -> [[String]] {
        rounds.map { offset, reminders in
            let decision = NotificationDecider.decide(reminders: reminders, isSnoozed: { snoozed.contains($0.id) },
                                                      records: records, settings: settings, now: now.addingTimeInterval(offset))
            records = decision.records
            return decision.reminders.map(\.id)
        }
    }

    static var tests: [(String, @MainActor () async -> Bool)] { [
        ("Core.Notifications/首次出现与持续只发一次", {
            var records: [String: NotifiedRecord] = [:]
            let sent = run([(0, [disk()]), (60, [disk()]), (7200, [disk()])], records: &records)
            return sent == [["disk.system"], [], []]
        }),
        ("Core.Notifications/未确认不发也不算恢复", {
            var records: [String: NotifiedRecord] = [:]
            // 未确认时不建记录；确认后才发；之后再次变成未确认仍在列表里，不算恢复。
            let sent = run([(0, [disk(confirmed: false)]), (60, [disk()]), (120, [disk(confirmed: false)]), (7200, [disk()])], records: &records)
            return sent == [[], ["disk.system"], [], []] && records["disk.system"]?.recoveredAt == nil
        }),
        ("Core.Notifications/恢复不满 1 小时不再发，满 1 小时再发", {
            var records: [String: NotifiedRecord] = [:]
            let short = run([(0, [disk()]), (60, []), (60 + 3599, [disk()])], records: &records)
            records = [:]
            let long = run([(0, [disk()]), (60, []), (60 + 3600, [disk()])], records: &records)
            return short == [["disk.system"], [], []] && long == [["disk.system"], [], ["disk.system"]]
        }),
        ("Core.Notifications/严重档 10 分钟冷却与升级立即发", {
            var records: [String: NotifiedRecord] = [:]
            let severe = run([(0, [network(level: .severe)]), (60, []), (60 + 599, [network(level: .severe)]),
                              (700, []), (700 + 600, [network(level: .severe)])], records: &records)
            records = [:]
            let upgrade = run([(0, [network(level: .warn)]), (60, [network(level: .severe)]), (120, [network(level: .warn)]),
                               (180, [network(level: .severe)])], records: &records)
            return severe == [["network.group.overseas"], [], [], [], ["network.group.overseas"]]
                && upgrade == [["network.group.overseas"], ["network.group.overseas"], [], []]
        }),
        ("Core.Notifications/额度同周期一次，新周期再发", {
            var records: [String: NotifiedRecord] = [:]
            let reset = now.addingTimeInterval(4 * 3600)
            // 恢复满 1 小时后同周期再出现不发；重置时间抖动 5 分钟仍算同周期；新周期立即发。
            let sent = run([(0, [quota(resetAt: reset)]), (60, []), (7200, [quota(resetAt: reset.addingTimeInterval(300))]),
                            (7260, [quota(resetAt: reset.addingTimeInterval(5 * 3600))])], records: &records)
            return sent == [["quotaLow.claude.primary"], [], [], ["quotaLow.claude.primary"]]
        }),
        ("Core.Notifications/额度没有重置时间时按 1 小时冷却", {
            var records: [String: NotifiedRecord] = [:]
            let sent = run([(0, [quota(resetAt: nil)]), (60, []), (1800, [quota(resetAt: nil)]), (1860, []), (1860 + 3600, [quota(resetAt: nil)])], records: &records)
            return sent == [["quotaLow.claude.primary"], [], [], [], ["quotaLow.claude.primary"]]
        }),
        ("Core.Notifications/暂缓中不发，到期仍在补发一次", {
            var records: [String: NotifiedRecord] = [:]
            let id = disk().id
            let during = run([(0, [disk()]), (60, [disk()])], snoozed: [id], records: &records)
            let after = run([(3600, [disk()]), (3660, [disk()])], records: &records)
            // 暂缓期间恢复，就不补发。
            var other: [String: NotifiedRecord] = [:]
            let recovered = run([(0, [disk()]), (60, [])], snoozed: [id], records: &other)
                + run([(120, [disk()])], records: &other)
            return during == [[], []] && after == [["disk.system"], []] && recovered == [[], [], []]
        }),
        ("Core.Notifications/开关关闭照样维护记录", {
            var settings = NotificationSettings(); settings.enabled = false
            var records: [String: NotifiedRecord] = [:]
            let off = run([(0, [disk()])], settings: settings, records: &records)
            let on = run([(60, [disk()])], records: &records)
            var source = NotificationSettings(); source.categories.remove(.disk)
            var other: [String: NotifiedRecord] = [:]
            let category = run([(0, [disk(), quota(resetAt: nil)])], settings: source, records: &other)
            return off == [[]] && on == [[]] && records["disk.system"] != nil && category == [["quotaLow.claude.primary"]]
                && !NotificationSettings().allows(.source) && NotificationSettings().allows(.egress)
        }),
        ("Core.Notifications/降温不通知与排序", {
            var records: [String: NotifiedRecord] = [:]
            let cooling = Reminder(kind: .cooling, object: "fan", tab: .system, level: .warn, title: "建议降温")
            let sent = run([(0, [disk(), cooling, network(level: .severe), quota(resetAt: nil)])], records: &records)
            return sent == [["network.group.overseas", "disk.system", "quotaLow.claude.primary"]] && records["cooling.fan"] == nil
        }),
        ("Core.Notifications/记录清理与上限", {
            var records: [String: NotifiedRecord] = [:]
            for index in 0..<300 {
                records["disk.\(index)"] = NotifiedRecord(key: "disk.\(index)", level: .warn, notifiedAt: now,
                                                          recoveredAt: now.addingTimeInterval(Double(index)))
            }
            records["quotaLow.a"] = NotifiedRecord(key: "quotaLow.a", level: .warn, notifiedAt: now,
                                                   cycleResetAt: now.addingTimeInterval(86400), recoveredAt: now)
            let capped = NotificationDecider.prune(records, now: now.addingTimeInterval(300))
            let later = NotificationDecider.prune(records, now: now.addingTimeInterval(7200))
            return capped.count == NotificationDecider.maxRecords && capped["disk.299"] != nil && capped["disk.0"] == nil
                && later.keys.sorted() == ["quotaLow.a"]
        }),
        ("Core.Notifications/文案", {
            let reset = now.addingTimeInterval(2 * 3600)   // 同一天
            var pace = quota(resetAt: now.addingTimeInterval(3 * 86400))
            pace = Reminder(kind: .quotaPace, object: "codex.secondary", tab: .quota, title: "Codex 7 天额度偏快",
                            resetAt: pace.resetAt, provider: .codex,
                            facts: ReminderFacts(subject: "Codex 7 天窗口", secondsUntilExhaustion: 7800))
            let process = Reminder(kind: .process, object: "42", tab: .system, title: "BTLEServer · 进程 CPU 持续偏高",
                                   facts: ReminderFacts(subject: "BTLEServer", cpuPercent: 98.4, duration: 720))
            let memory = Reminder(kind: .memory, object: "system", tab: .system, title: "内存压力持续偏高",
                                  facts: ReminderFacts(duration: 900, pressurePercent: 82))
            let thermal = Reminder(kind: .thermal, object: "system", tab: .system, title: "温度偏高，未发现异常进程，建议降温或用 AI 诊断",
                                   facts: ReminderFacts(thermalState: "serious"))
            let source = Reminder(kind: .source, object: "quota.claude", tab: .quota, title: "数据源失效：Claude",
                                  facts: ReminderFacts(subject: "Claude", failures: 3, cachedAt: now.addingTimeInterval(-1800)))
            let aggregate = Reminder(kind: .source, object: "quota", tab: .quota, title: "数据源失效：额度",
                                     facts: ReminderFacts(subject: "额度", failures: 2))
            func body(_ reminder: Reminder) -> String {
                NotificationContent.notice(for: reminder, now: now, timeZone: utc, redact: { $0.replacingOccurrences(of: "代理", with: "[已隐藏]") }).body
            }
            let expectedReset = NotificationContent.time(reset, now: now, timeZone: utc)
            let paceReset = NotificationContent.time(pace.resetAt!, now: now, timeZone: utc)
            let checks = [
                body(quota(resetAt: reset)) == "Claude 5 小时窗口剩余 12%，\(expectedReset) 重置",
                body(pace) == "Codex 7 天窗口按当前速度约 2 小时 10 分后用完，\(paceReset) 才重置",
                body(disk()).hasPrefix("磁盘可用 8%（") && body(disk()).hasSuffix("），可在系统页清理"),
                body(process) == "BTLEServer 占用 CPU 98%，已持续 12 分钟",
                body(memory) == "内存压力 82%，已持续 15 分钟",
                body(thermal) == "热状态 serious，温度偏高，未发现异常进程，建议降温或用 AI 诊断",
                body(source) == "Claude 数据连续 3 次采集失败，面板显示的是 \(NotificationContent.time(now.addingTimeInterval(-1800), now: now, timeZone: utc)) 的缓存",
                body(aggregate) == "额度数据连续 2 次采集失败",
                body(network(level: .severe)) == "海外站点连续 3 轮探测失败。检查[已隐藏]是否运行",
                NotificationContent.notice(for: network(level: .severe), now: now).sound,
                !NotificationContent.notice(for: disk(), now: now).sound,
                NotificationContent.notice(for: process, now: now).subtitle == "进程 CPU 持续偏高",
            ]
            return !checks.contains(false)
        }),
        ("Core.Notifications/时间写法与同轮汇总", {
            let base = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC，周五
            let sameDay = NotificationContent.time(base.addingTimeInterval(3 * 3600), now: base, timeZone: utc)
            let week = NotificationContent.time(base.addingTimeInterval(6 * 86400), now: base, timeZone: utc)
            let far = NotificationContent.time(base.addingTimeInterval(10 * 86400), now: base, timeZone: utc)
            let reminders = [network(level: .severe), disk(), quota(resetAt: nil),
                             Reminder(kind: .memory, object: "system", tab: .system, title: "内存压力持续偏高")]
            let notices = NotificationContent.notices(for: reminders, now: base, timeZone: utc)
            let three = NotificationContent.notices(for: Array(reminders.prefix(3)), now: base, timeZone: utc)
            return sameDay == "11:00" && week == "周四 08:00" && far == "1月25日 08:00"
                && notices.count == 3 && notices[2].subtitle == "另有 2 条提醒" && notices[2].body == "额度不足、内存压力持续偏高，打开面板查看全部提醒"
                && three.count == 3 && three.allSatisfy { $0.key != "summary" }
        }),
        ("Core.Notifications/提醒带上具体数值", {
            let window = QuotaWindow(usedPercent: 88, windowMinutes: 300, resetsAt: now.addingTimeInterval(3600), resetDescription: nil)
            let snapshot = QuotaSnapshot(provider: .claude, source: "test", updatedAt: now, windows: [window], paceSummary: nil, credits: nil)
            let batch = ReminderCollector.collect(HealthInputs(system: nil, energy: nil, quotaUsedPercent: [], network: .green,
                failedSources: ["quota.claude": 3], fairSince: nil, now: now, quotaSnapshots: [snapshot],
                networkSignals: [NetworkReminderSignal(key: "dns", message: "DNS 未恢复", level: .severe, hint: "重开 TUN")]), config: LocalConfig())
            let low = batch.reminders.first { $0.kind == .quotaLow }
            let source = batch.reminders.first { $0.kind == .source }
            let net = batch.reminders.first { $0.kind == .network }
            return low?.facts?.subject == "Claude 5 小时窗口" && low?.facts?.remainingPercent == 12
                && source?.facts?.failures == 3 && source?.facts?.cachedAt == now && source?.facts?.subject == "Claude"
                && net?.facts?.hint == "重开 TUN"
        }),
    ] }
}
