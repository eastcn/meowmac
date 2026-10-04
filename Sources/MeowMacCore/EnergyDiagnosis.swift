import Foundation

public struct ProcessEnergy: Equatable, Codable {
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let impact: Double

    public init(pid: Int32, name: String, cpuPercent: Double, impact: Double) {
        self.pid = pid; self.name = name; self.cpuPercent = cpuPercent; self.impact = impact
    }
}

public enum TopParser {
    public static func secondSample(_ text: String) -> [ProcessEnergy]? {
        let lines = text.components(separatedBy: .newlines)
        let headers = lines.indices.filter { lines[$0].hasPrefix("PID ") && lines[$0].contains("%CPU") && lines[$0].contains("POWER") }
        guard headers.count >= 2 else { return nil }
        var result: [ProcessEnergy] = []
        for line in lines[(headers[1] + 1)...] {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4, let pid = Int32(fields[0]), let cpu = Double(fields[fields.count - 2]),
                  let impact = Double(fields[fields.count - 1]) else {
                if !result.isEmpty { break }
                continue
            }
            let name = fields[1..<(fields.count - 2)].joined(separator: " ")
            result.append(ProcessEnergy(pid: pid, name: name, cpuPercent: cpu, impact: impact))
        }
        return result.sorted { $0.impact > $1.impact }
    }
}

public struct SleepAssertion: Equatable, Codable {
    public let pid: Int32
    public let type: String
    public let startedAt: Date
    public let processName: String?

    public init(pid: Int32, type: String, startedAt: Date, processName: String? = nil) {
        self.pid = pid; self.type = type; self.startedAt = startedAt; self.processName = processName
    }


}

public struct EnergyDiagnosis: Codable {
    public let topFive: [ProcessEnergy]
    public let runaway: [ProcessEnergy]
    /// 保留旧数据结构，断言不再参与诊断。
    public let longAssertions: [SleepAssertion]
    public let prolongedMemoryPressure: Bool
    public let runawayDurations: [Int32: TimeInterval]
    public let memoryPressureDuration: TimeInterval?

    public init(topFive: [ProcessEnergy], runaway: [ProcessEnergy], longAssertions: [SleepAssertion], prolongedMemoryPressure: Bool,
                runawayDurations: [Int32: TimeInterval] = [:], memoryPressureDuration: TimeInterval? = nil) {
        self.topFive = topFive; self.runaway = runaway; self.longAssertions = longAssertions
        self.prolongedMemoryPressure = prolongedMemoryPressure
        self.runawayDurations = runawayDurations
        self.memoryPressureDuration = memoryPressureDuration
    }
}

/// 失控进程和内存压力的持续判定。
///
/// 每次判定的 CPU 必须是覆盖整个采样间隔的平均值（`top -s` 的第二次采样就是），
/// 瞬时值会让每分钟一次的短峰反复撞上采样点。相邻两次判定的间隔超过
/// 采样间隔的 2.5 倍（休眠、采样失败、应用暂停）时，已累计的时长清零，
/// 因为断档里没有观测，不能当作持续高占用。
public struct EnergyTracker {
    private var aboveSince: [Int32: Date] = [:]
    private var pressureSince: Date?
    private var lastWindowEnd: Date?
    private var lastRunaway: [ProcessEnergy] = []

    public init() {}

    /// - Parameter coverage: 这次 CPU 数据覆盖的时长，默认等于 `processSampleSeconds`。
    ///   短于采样间隔一半的样本（启动、唤醒）只替换排行；失控进程和内存压力沿用上一次完整样本的结论，
    ///   因为 1 秒的瞬时值既不能确认也不能推翻“持续”。
    public mutating func evaluate(processes: [ProcessEnergy], assertions: [SleepAssertion] = [],
                                  pressure: MemoryPressure, now: Date, config: LocalConfig,
                                  coverage: TimeInterval? = nil) -> EnergyDiagnosis {
        let window = coverage ?? config.processSampleSeconds
        guard window >= config.processSampleSeconds / 2 else { return preview(processes, now: now, config: config) }
        if let last = lastWindowEnd, now.timeIntervalSince(last) > config.processSampleSeconds * 2.5 {
            aboveSince.removeAll()
            pressureSince = nil
        }
        lastWindowEnd = now
        let currentPIDs = Set(processes.map(\.pid))
        aboveSince = aboveSince.filter { currentPIDs.contains($0.key) }
        for process in processes {
            if process.cpuPercent >= config.runawayCPU {
                if aboveSince[process.pid] == nil { aboveSince[process.pid] = now.addingTimeInterval(-window) }
            } else { aboveSince.removeValue(forKey: process.pid) }
        }
        if pressure.isElevated {
            if pressureSince == nil { pressureSince = now }
        } else { pressureSince = nil }
        let result = diagnosis(processes: processes, now: now, config: config)
        lastRunaway = result.runaway
        return result
    }

    /// 短样本：排行来自这次样本，持续性判断来自上一次完整样本，时长按当前时间推算。
    private func preview(_ processes: [ProcessEnergy], now: Date, config: LocalConfig) -> EnergyDiagnosis {
        let runaway = lastRunaway.filter { aboveSince[$0.pid] != nil }
        return EnergyDiagnosis(topFive: Array(processes.prefix(5)), runaway: runaway, longAssertions: [],
                               prolongedMemoryPressure: pressureSince.map { now.timeIntervalSince($0) >= config.memoryPressureSeconds } ?? false,
                               runawayDurations: Dictionary(uniqueKeysWithValues: runaway.compactMap { process in
                                   aboveSince[process.pid].map { (process.pid, now.timeIntervalSince($0)) }
                               }),
                               memoryPressureDuration: pressureSince.map { now.timeIntervalSince($0) })
    }

    private func diagnosis(processes: [ProcessEnergy], now: Date, config: LocalConfig) -> EnergyDiagnosis {
        let runaway = processes.filter { process in
            guard let since = aboveSince[process.pid] else { return false }
            return now.timeIntervalSince(since) >= config.runawaySeconds
        }
        return EnergyDiagnosis(topFive: Array(processes.prefix(5)), runaway: runaway,
                               longAssertions: [],
                               prolongedMemoryPressure: pressureSince.map { now.timeIntervalSince($0) >= config.memoryPressureSeconds } ?? false,
                               runawayDurations: Dictionary(uniqueKeysWithValues: runaway.compactMap { process in
                                   aboveSince[process.pid].map { (process.pid, now.timeIntervalSince($0)) }
                               }),
                               memoryPressureDuration: pressureSince.map { now.timeIntervalSince($0) })
    }
}
