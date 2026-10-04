import Foundation
import MeowMacCore

/// 失控进程和内存压力的持续判定。每个样本代表一个完整采样间隔的平均 CPU。
enum EnergyTrackerTests {
    private static let start = Date(timeIntervalSince1970: 1_000_000)
    private static let config = LocalConfig()

    private static func process(_ cpu: Double) -> ProcessEnergy {
        ProcessEnergy(pid: 42, name: "Example", cpuPercent: cpu, impact: 2)
    }

    private static func at(_ minute: Double) -> Date { start.addingTimeInterval(minute * 60) }

    private static func feed(_ tracker: inout EnergyTracker, minutes: Range<Int>, cpu: Double,
                             pressure: MemoryPressure = .normal) -> EnergyDiagnosis? {
        var last: EnergyDiagnosis?
        for minute in minutes {
            last = tracker.evaluate(processes: [process(cpu)], pressure: pressure, now: at(Double(minute)), config: config)
        }
        return last
    }

    /// 持续高占用：第 10 个样本才告警，起点按样本窗口回推，时长恰好 600 秒。
    static func sustainedAlerts() -> Bool {
        var tracker = EnergyTracker()
        guard feed(&tracker, minutes: 0..<9, cpu: 95)?.runaway.isEmpty == true else { return false }
        let tenth = tracker.evaluate(processes: [process(95)], pressure: .normal, now: at(9), config: config)
        return tenth.runaway.map(\.pid) == [42] && tenth.runawayDurations[42] == 600
    }

    /// 每分钟一个 95% 的短峰，其余时间接近 0：平均值不会过线，一小时内都不告警。
    static func periodicSpikeIgnored() -> Bool {
        var tracker = EnergyTracker()
        for minute in 0..<60 {
            // 整分钟平均：2 秒 100% 加 58 秒 1%，约 4%。
            let average = (2 * 100.0 + 58 * 1.0) / 60
            let diagnosis = tracker.evaluate(processes: [process(average)], pressure: .normal, now: at(Double(minute)), config: config)
            if !diagnosis.runaway.isEmpty { return false }
        }
        return true
    }

    /// 中途回落到阈值以下、或者掉出排行榜，累计时长清零。
    static func dropResetsStreak() -> Bool {
        var tracker = EnergyTracker()
        _ = feed(&tracker, minutes: 0..<9, cpu: 95)
        _ = tracker.evaluate(processes: [process(20)], pressure: .normal, now: at(9), config: config)
        guard feed(&tracker, minutes: 10..<19, cpu: 95)?.runaway.isEmpty == true else { return false }
        _ = tracker.evaluate(processes: [], pressure: .normal, now: at(19), config: config)
        guard feed(&tracker, minutes: 20..<29, cpu: 95)?.runaway.isEmpty == true else { return false }
        return tracker.evaluate(processes: [process(95)], pressure: .normal, now: at(29), config: config).runaway.count == 1
    }

    /// 休眠或采样失败造成的断档不算持续高占用：断档前后的高值各自重新计时。
    static func gapResetsStreak() -> Bool {
        var tracker = EnergyTracker()
        _ = feed(&tracker, minutes: 0..<9, cpu: 95)
        // 断档 20 分钟后第一个高值：不能把断档算进去。
        let resumed = tracker.evaluate(processes: [process(95)], pressure: .normal, now: at(29), config: config)
        guard resumed.runaway.isEmpty, resumed.runawayDurations.isEmpty else { return false }
        guard feed(&tracker, minutes: 30..<38, cpu: 95)?.runaway.isEmpty == true else { return false }
        return tracker.evaluate(processes: [process(95)], pressure: .normal, now: at(38), config: config).runawayDurations[42] == 600
    }

    /// 启动、手动刷新用的短窗口样本只更新排行，不能启动、延长或打断持续计时。
    static func shortSampleKeepsStreak() -> Bool {
        var tracker = EnergyTracker()
        let short = tracker.evaluate(processes: [process(99)], pressure: .normal, now: at(0), config: config, coverage: 1)
        guard short.runaway.isEmpty, short.topFive.count == 1 else { return false }
        _ = feed(&tracker, minutes: 1..<5, cpu: 95)
        // 中间插一个 1 秒的低值样本：不应清零。
        _ = tracker.evaluate(processes: [process(1)], pressure: .normal, now: at(5).addingTimeInterval(20), config: config, coverage: 1)
        _ = feed(&tracker, minutes: 5..<10, cpu: 95)
        return tracker.evaluate(processes: [process(95)], pressure: .normal, now: at(10), config: config).runawayDurations[42] == 600
    }

    /// 内存压力同样按连续样本计时，断档后重新开始。
    static func pressureGapResets() -> Bool {
        var tracker = EnergyTracker()
        _ = feed(&tracker, minutes: 0..<9, cpu: 1, pressure: .critical)
        guard let resumed = feed(&tracker, minutes: 29..<30, cpu: 1, pressure: .critical),
              !resumed.prolongedMemoryPressure, resumed.memoryPressureDuration == 0 else { return false }
        return feed(&tracker, minutes: 30..<40, cpu: 1, pressure: .critical)?.prolongedMemoryPressure == true
    }
}
