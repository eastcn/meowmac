import Foundation
import MeowMacCore
import MeowMacUI

enum RuleClockTests {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static func input(_ seconds: Double, value: Double? = 80) -> HealthInputs {
        let time = base.addingTimeInterval(seconds)
        let system = SystemSnapshot(timestamp: time, cpuUsage: nil, memoryPressure: .normal, swapUsedBytes: nil,
            diskAvailableBytes: nil, diskTotalBytes: nil, networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
            battery: .init(temperatureCelsius: nil, systemPowerWatts: nil), thermal: .nominal, memoryPressurePercent: value)
        return HealthInputs(system: system, energy: nil, quotaUsedPercent: [], network: .green, failedSources: [:], fairSince: nil, now: time)
    }
    static func rule(duration: Double = 10) -> AlertRule {
        .init(id: "u-12345678", name: "内存规则", metric: "memory.pressure", threshold: 70, durationSeconds: duration)
    }
    static func memoryEvaluation(endingAt time: Date) -> RuleEvaluation {
        var clock = RuleClock(); let memory = LocalConfig().alertRules.memoryRule(config: LocalConfig())
        for second in stride(from: 0.0, through: 600, by: 2) {
            let date = time.addingTimeInterval(second - 600)
            let system = SystemSnapshot(timestamp: date, cpuUsage: nil, memoryPressure: .warn, swapUsedBytes: nil,
                diskAvailableBytes: nil, diskTotalBytes: nil, networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
                battery: .init(temperatureCelsius: nil, systemPowerWatts: nil), thermal: .nominal, memoryPressurePercent: 80)
            clock.update(rules: [memory], input: HealthInputs(system: system, energy: nil, quotaUsedPercent: [], network: .green,
                failedSources: [:], fairSince: nil, now: date))
        }
        return clock.evaluations[0]
    }
    static var tests: [(String, @MainActor () throws -> Bool)] { [
        ("Core.RuleClock/持续边界、回落和缺测", {
            var clock = RuleClock(); let rules = [rule()]
            for second in [Double](arrayLiteral: 0, 2, 4, 6, 8, 9) { clock.update(rules: rules, input: input(second)) }
            guard clock.evaluations.first?.triggered == false else { return false }
            clock.update(rules: rules, input: input(10))
            guard clock.evaluations.first?.triggered == true, clock.evaluations.first?.duration == 10 else { return false }
            clock.update(rules: rules, input: input(12, value: nil))
            guard clock.evaluations.isEmpty else { return false }
            clock.update(rules: rules, input: input(14))
            guard clock.evaluations.first?.triggered == true, clock.evaluations.first?.duration == 14 else { return false }
            clock.update(rules: rules, input: input(16, value: 69))
            return clock.evaluations.first?.triggered == false && clock.evaluations.first?.duration == 0
        }),
        ("Core.RuleClock/缺测不重计、断档清空与边界", {
            var clock = RuleClock(); let rules = [rule()]
            clock.update(rules: rules, input: input(0))
            clock.update(rules: rules, input: input(2, value: nil))
            clock.update(rules: rules, input: input(4))
            guard clock.evaluations.first?.duration == 4 else { return false }
            clock.update(rules: rules, input: input(9))
            guard clock.evaluations.first?.duration == 9 else { return false }
            clock.update(rules: rules, input: input(15))
            return clock.evaluations.first?.duration == 0 && clock.evaluations.first?.triggered == false
        }),
        ("Core.RuleClock/编辑阈值、停用启用和缓存不累计", {
            var clock = RuleClock(); var r = rule()
            for second in [Double](arrayLiteral: 0, 2, 4, 6) { clock.update(rules: [r], input: input(second)) }
            clock.update(rules: [r], input: input(6))
            guard clock.evaluations.first?.duration == 6 else { return false }
            r.threshold = 75
            clock.update(rules: [r], input: input(8))
            guard clock.evaluations.first?.duration == 0 else { return false }
            r.enabled = false; clock.update(rules: [r], input: input(10))
            guard clock.evaluations.isEmpty else { return false }
            r.enabled = true; clock.update(rules: [r], input: input(12))
            return clock.evaluations.first?.duration == 0
        }),
        ("Core.RuleClock/首次读取旧缓存从当前观察时刻计时", {
            let rule = AlertRule(id: "u-12345678", name: "额度持续", metric: "quota.remaining", comparison: .lte, threshold: 50, durationSeconds: 3600)
            var clock = RuleClock()
            func cached(_ sampled: Double, observed: Double) -> HealthInputs {
                let snapshot = QuotaSnapshot(provider: .claude, source: "fixture", updatedAt: base.addingTimeInterval(sampled),
                    windows: [.init(usedPercent: 80, windowMinutes: 300, resetsAt: base.addingTimeInterval(30000), resetDescription: nil)], paceSummary: nil, credits: nil)
                return HealthInputs(system: nil, energy: nil, quotaUsedPercent: [], network: .green, failedSources: [:], fairSince: nil,
                    now: base.addingTimeInterval(observed), quotaSnapshots: [snapshot])
            }
            clock.update(rules: [rule], input: cached(0, observed: 1800))
            clock.update(rules: [rule], input: cached(3600, observed: 3600))
            return clock.evaluations.first?.duration == 1800 && clock.evaluations.first?.triggered == false
        }),
        ("Core.RuleClock/改名和严重升级保留持续时长", {
            var clock = RuleClock(); var r = rule()
            for second in stride(from: 0.0, through: 10, by: 2) { clock.update(rules: [r], input: input(second)) }
            r.name = "新名称"; r.level = .severe
            clock.update(rules: [r], input: input(10))
            return clock.evaluations.first?.duration == 10 && clock.evaluations.first?.triggered == true
                && clock.evaluations.first?.rule.name == "新名称" && clock.evaluations.first?.rule.level == .severe
        }),
        ("Core.RuleClock/额度休眠 60 分钟不累计、缓存不重计", {
            var clock = RuleClock()
            let r = AlertRule(id: "u-12345678", name: "额度规则", metric: "quota.remaining", comparison: .lte, threshold: 50, durationSeconds: 3600)
            func quota(_ second: Double) -> HealthInputs {
                let time = base.addingTimeInterval(second)
                let snap = QuotaSnapshot(provider: .claude, source: "fixture", updatedAt: time,
                    windows: [.init(usedPercent: 80, windowMinutes: 300, resetsAt: base.addingTimeInterval(20000), resetDescription: nil)], paceSummary: nil, credits: nil)
                return HealthInputs(system: nil, energy: nil, quotaUsedPercent: [], network: .green, failedSources: [:], fairSince: nil, now: time, quotaSnapshots: [snap])
            }
            clock.update(rules: [r], input: quota(0)); clock.update(rules: [r], input: quota(1800))
            clock.sleep(); clock.update(rules: [r], input: quota(1800))
            guard clock.evaluations.isEmpty else { return false }
            clock.update(rules: [r], input: quota(5400))
            return clock.evaluations.first?.duration == 0 && clock.evaluations.first?.triggered == false
        }),
        ("Core.RuleClock/内存新口径与休眠后待确认", {
            let state = PanelState(configResult: .init(config: LocalConfig(), error: nil))
            state.now = { base }
            for second in stride(from: 0.0, through: 600, by: 2) {
                state.now = { base.addingTimeInterval(second) }; state.snapshot = input(second).system
            }
            guard let memory = state.allReminders.first(where: { $0.id == "memory.system" }),
                  memory.facts?.pressureThreshold == 61, memory.facts?.duration == 600 else { return false }
            state.rulesWillSleep()
            guard state.allReminders.first(where: { $0.id == "memory.system" })?.confirmed == false else { return false }
            state.now = { base.addingTimeInterval(4200) }; state.snapshot = input(4200, value: nil).system
            guard state.allReminders.contains(where: { $0.id == "memory.system" }) else { return false }
            state.snapshot = input(4200, value: 60).system
            return !state.allReminders.contains(where: { $0.id == "memory.system" })
        }),
        ("Core.RuleClock/停用内置立即清除提醒和暂缓", {
            let state = PanelState(configResult: .init(config: LocalConfig(), error: nil)); state.now = { base }
            let issue = Reminder(kind: .disk, object: "system", tab: .system, title: "磁盘剩余不足")
            var tracker = ReminderTracker(); tracker.reconcile(.init(reminders: [issue]), now: base)
            tracker.snoozes[issue.id] = try SnoozeRecord(reminder: issue, acknowledgedAt: base, until: base.addingTimeInterval(3600))
            var config = LocalConfig(); config.alertRules.builtin[BuiltinAlertRule.disk.id] = .init(enabled: false)
            state.configResult = .init(config: config, error: nil)
            tracker.reconcile(state.reminderBatch, now: base)
            return tracker.current.isEmpty && tracker.snoozes.isEmpty
        })
    ] }
}
