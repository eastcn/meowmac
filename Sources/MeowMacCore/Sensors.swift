import Foundation

/// 传感器读数的来源。SMC 和 IOHID 都是非公开接口，新芯片上可能失效（D9）。
public enum SensorSource: String, Codable {
    case smc, iohid
}

public struct FanReading: Codable, Equatable {
    public let rpm: Double
    public let maxRPM: Double?

    public init(rpm: Double, maxRPM: Double?) {
        self.rpm = rpm; self.maxRPM = maxRPM
    }

    /// 占最大转速的比例；最大转速缺失或为 0 时不计算。
    public var fraction: Double? {
        guard let maxRPM, maxRPM > 0 else { return nil }
        return rpm / maxRPM
    }
}

public struct SensorReadings: Codable, Equatable {
    public let cpuAverageCelsius: Double?
    public let cpuMaxCelsius: Double?
    public let cpuSource: SensorSource?
    public let gpuAverageCelsius: Double?
    /// nil 表示读不到风扇；空数组表示本机没有风扇。
    public let fans: [FanReading]?
    /// 传感器服务整体不可用时的原因。
    public let failure: String?

    public init(cpuAverageCelsius: Double?, cpuMaxCelsius: Double?, cpuSource: SensorSource?,
                gpuAverageCelsius: Double?, fans: [FanReading]?, failure: String? = nil) {
        self.cpuAverageCelsius = cpuAverageCelsius; self.cpuMaxCelsius = cpuMaxCelsius; self.cpuSource = cpuSource
        self.gpuAverageCelsius = gpuAverageCelsius; self.fans = fans; self.failure = failure
    }

    public static func unavailable(_ reason: String) -> SensorReadings {
        SensorReadings(cpuAverageCelsius: nil, cpuMaxCelsius: nil, cpuSource: nil, gpuAverageCelsius: nil, fans: nil, failure: reason)
    }

    /// 占最大转速比例最高的风扇；都没有比例时取转速最高的。
    public var leadingFan: FanReading? {
        guard let fans, !fans.isEmpty else { return nil }
        let rated = fans.filter { $0.fraction != nil }
        if let best = rated.max(by: { $0.fraction! < $1.fraction! }) { return best }
        return fans.max { $0.rpm < $1.rpm }
    }

    /// 任一风扇超过阈值。没有可判定的风扇时返回 nil，表示不判定。
    public func fanHigh(threshold: Double) -> Bool? {
        guard let fans else { return nil }
        let fractions = fans.compactMap(\.fraction)
        guard !fractions.isEmpty else { return nil }
        return fractions.contains { $0 > threshold }
    }
}

/// SMC 键值的字节解码。SMC 的整数和定点数是大端，`flt ` 是本机字节序的 Float。
public enum SMCDecoder {
    public static func value(type: String, bytes: [UInt8]) -> Double? {
        func big(_ count: Int) -> UInt64? {
            guard bytes.count >= count else { return nil }
            return bytes.prefix(count).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let value = Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
            return value.isFinite ? value : nil
        case "fpe2": return big(2).map { Double($0) / 4 }
        case "sp78": return big(2).map { Double(Int16(bitPattern: UInt16($0))) / 256 }
        case "ui8 ": return big(1).map { Double($0) }
        case "ui16": return big(2).map { Double($0) }
        case "ui32": return big(4).map { Double($0) }
        default: return nil
        }
    }

    public static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    public static func string(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, as: UTF8.self)
    }
}

/// 把原始键值归并成卡片要显示的读数。
public enum SensorAggregator {
    /// 超出这个范围的温度视为无效读数。
    public static let validCelsius = 5.0...120.0

    public static func isCPUKey(_ key: String) -> Bool { key.hasPrefix("Tp") }
    public static func isGPUKey(_ key: String) -> Bool { key.hasPrefix("Tg") }
    public static func isDieSensor(_ name: String) -> Bool { name.hasPrefix("PMU") && name.contains("tdie") }

    /// - Parameters:
    ///   - smcTemperatures: SMC 温度键及其读数。
    ///   - hidTemperatures: IOHID 温度传感器名称及其读数，只在没有 `Tp*` 时使用。
    ///   - fanCount: `FNum`；nil 表示读不到。
    ///   - fans: 每个风扇的实际转速和最大转速；实际转速读不到的风扇为 nil。
    public static func make(smcTemperatures: [String: Double], hidTemperatures: [String: Double],
                            fanCount: Int?, fans: [(rpm: Double?, max: Double?)], failure: String? = nil) -> SensorReadings {
        func valid(_ values: [Double]) -> [Double] { values.filter { $0.isFinite && validCelsius.contains($0) } }
        var cpu = valid(smcTemperatures.filter { isCPUKey($0.key) }.map(\.value))
        var source: SensorSource? = cpu.isEmpty ? nil : .smc
        if cpu.isEmpty {
            cpu = valid(hidTemperatures.filter { isDieSensor($0.key) }.map(\.value))
            source = cpu.isEmpty ? nil : .iohid
        }
        let gpu = valid(smcTemperatures.filter { isGPUKey($0.key) }.map(\.value))
        var fanReadings: [FanReading]?
        if let fanCount {
            if fanCount <= 0 {
                fanReadings = []
            } else {
                let readable = fans.prefix(fanCount).compactMap { fan in
                    fan.rpm.flatMap { rpm in rpm.isFinite && rpm >= 0 ? FanReading(rpm: rpm, maxRPM: fan.max.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }) : nil }
                }
                fanReadings = readable.isEmpty ? nil : readable
            }
        }
        let anything = !cpu.isEmpty || !gpu.isEmpty || fanReadings != nil
        return SensorReadings(cpuAverageCelsius: average(cpu), cpuMaxCelsius: cpu.max(), cpuSource: source,
                              gpuAverageCelsius: average(gpu), fans: fanReadings,
                              failure: anything ? nil : (failure ?? "没有匹配的传感器"))
    }

    static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

/// 风扇持续高转速的计时。与 `fairSince` 一样只保存开始时刻。
/// 回落时重置；读不到或无法判定时保持原样，采集失败不代表恢复（D40）。
public enum FanHighTracker {
    public static func next(since: Date?, readings: SensorReadings?, at time: Date, config: LocalConfig) -> Date? {
        switch readings?.fanHigh(threshold: config.fanHighFraction) {
        case true?: return since ?? time
        case false?: return nil
        case nil: return since
        }
    }
}
