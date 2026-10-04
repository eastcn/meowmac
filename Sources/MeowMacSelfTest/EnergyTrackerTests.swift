import Foundation
import MeowMacCore
import MeowMacSystem

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

    /// 短样本的输出：排行换成这次样本，失控进程沿用上一次完整样本，不闪烁，CPU 也不是瞬时值。
    static func shortSampleKeepsRunaway() -> Bool {
        var tracker = EnergyTracker()
        guard let long = feed(&tracker, minutes: 0..<10, cpu: 95), long.runaway.map(\.pid) == [42] else { return false }
        let other = ProcessEnergy(pid: 7, name: "Other", cpuPercent: 30, impact: 9)
        // 失控进程这 1 秒没进前 10，或者只有 1%：都不能让它从失控列表里消失。
        let absent = tracker.evaluate(processes: [other], pressure: .normal, now: at(9).addingTimeInterval(20), config: config, coverage: 1)
        let quiet = tracker.evaluate(processes: [process(1), other], pressure: .normal, now: at(9).addingTimeInterval(30), config: config, coverage: 1)
        guard absent.topFive.map(\.pid) == [7], absent.runaway.map(\.pid) == [42], absent.runaway.first?.cpuPercent == 95,
              quiet.topFive.map(\.pid) == [42, 7], quiet.runaway.first?.cpuPercent == 95,
              quiet.runawayDurations[42] == 630 else { return false }
        // 完整样本落回阈值以下后，短样本不再显示它。
        _ = tracker.evaluate(processes: [process(10)], pressure: .normal, now: at(10), config: config)
        return tracker.evaluate(processes: [process(95)], pressure: .normal, now: at(10).addingTimeInterval(10), config: config, coverage: 1).runaway.isEmpty
    }

    /// 断档阈值是采样间隔的 2.5 倍：149 秒的间隔继续累计，151 秒清零。
    static func gapBoundary() -> Bool {
        // 判定后的 aboveSince 通过持续时长间接观察：用一个很短的 runawaySeconds 读出来。
        var short = config; short.runawaySeconds = 100
        func duration(gap: TimeInterval) -> TimeInterval? {
            var tracker = EnergyTracker()
            _ = tracker.evaluate(processes: [process(95)], pressure: .normal, now: start, config: short)
            return tracker.evaluate(processes: [process(95)], pressure: .normal, now: start.addingTimeInterval(gap), config: short).runawayDurations[42]
        }
        return duration(gap: 149) == 209 && duration(gap: 150) == 210 && duration(gap: 151) == nil
    }

    /// 采样间隔来自用户可编辑的配置，越界回退默认值；`top` 的参数再限制一次。
    static func sampleSecondsValidation() -> Bool {
        func decode(_ value: String) -> Double? {
            (try? JSONDecoder().decode(LocalConfig.self, from: Data("{\"processSampleSeconds\": \(value)}".utf8)))?.processSampleSeconds
        }
        let fallback = LocalConfig().processSampleSeconds
        guard decode("42") == 42, decode("10") == 10, decode("600") == 600,
              decode("-1") == fallback, decode("0") == fallback, decode("9.9") == fallback,
              decode("601") == fallback, decode("1e300") == fallback else { return false }
        func seconds(_ window: TimeInterval) -> String? {
            let arguments = EnergySampler.arguments(window: window)
            return arguments.firstIndex(of: "-s").map { arguments[$0 + 1] }
        }
        return seconds(60) == "60" && seconds(.nan) == "1" && seconds(-5) == "1" && seconds(1e300) == "600"
            && EnergySampler.arguments(window: 60).starts(with: ["-l", "2"])
    }
}
