import Foundation

public enum MemoryPressure: String, Codable {
    case normal, warn, critical, unavailable

    public var isElevated: Bool { self == .warn || self == .critical }

    public func load(config: LocalConfig) -> Double {
        switch self {
        case .normal: return config.memoryNormalLoad
        case .warn: return config.memoryWarnLoad
        case .critical: return config.memoryCriticalLoad
        case .unavailable: return 0
        }
    }
}

public enum ThermalLevel: String, Codable {
    case nominal, fair, serious, critical, unavailable
}

public struct CPUTicks: Equatable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }

    public static func usage(previous: CPUTicks, current: CPUTicks) -> Double? {
        guard current.user >= previous.user, current.system >= previous.system,
              current.idle >= previous.idle, current.nice >= previous.nice else { return nil }
        let busy = Double(current.user - previous.user + current.system - previous.system + current.nice - previous.nice)
        let idle = Double(current.idle - previous.idle)
        guard busy + idle > 0 else { return nil }
        return busy / (busy + idle)
    }
}

public struct ByteCounters: Equatable {
    public let received: UInt64
    public let sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received; self.sent = sent
    }

    public static func rates(previous: ByteCounters, current: ByteCounters, seconds: Double) -> (received: Double, sent: Double)? {
        guard seconds > 0, current.received >= previous.received, current.sent >= previous.sent else { return nil }
        return (Double(current.received - previous.received) / seconds, Double(current.sent - previous.sent) / seconds)
    }
}

public struct BatteryMetrics: Equatable, Codable {
    public let temperatureCelsius: Double?
    public let systemPowerWatts: Double?

    public init(temperatureCelsius: Double?, systemPowerWatts: Double?) {
        self.temperatureCelsius = temperatureCelsius
        self.systemPowerWatts = systemPowerWatts
    }

    public static func parse(temperature: Int?, systemLoad: Int?) -> BatteryMetrics {
        let temperature = temperature.map { Double($0) / 100 }
        let power = systemLoad.map { Double($0) / 1000 }
        return BatteryMetrics(temperatureCelsius: temperature, systemPowerWatts: power)
    }
}

public struct SystemSnapshot: Codable {
    public let timestamp: Date
    public let cpuUsage: Double?
    public let memoryPressure: MemoryPressure
    public let swapUsedBytes: UInt64?
    public let diskAvailableBytes: Int64?
    public let diskTotalBytes: Int64?
    public let networkReceivedBytesPerSecond: Double?
    public let networkSentBytesPerSecond: Double?
    public let battery: BatteryMetrics
    public let thermal: ThermalLevel
    public let memoryUsedBytes: UInt64?
    public let memoryTotalBytes: UInt64?
    public let memoryPressurePercent: Double?

    public var memoryUsedFraction: Double? {
        guard let used = memoryUsedBytes, let total = memoryTotalBytes, total > 0 else { return nil }
        return Double(used) / Double(total)
    }

    public init(timestamp: Date, cpuUsage: Double?, memoryPressure: MemoryPressure, swapUsedBytes: UInt64?,
                diskAvailableBytes: Int64?, diskTotalBytes: Int64?, networkReceivedBytesPerSecond: Double?,
                networkSentBytesPerSecond: Double?, battery: BatteryMetrics, thermal: ThermalLevel,
                memoryUsedBytes: UInt64? = nil, memoryTotalBytes: UInt64? = nil, memoryPressurePercent: Double? = nil) {
        self.timestamp = timestamp; self.cpuUsage = cpuUsage; self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes; self.diskAvailableBytes = diskAvailableBytes
        self.diskTotalBytes = diskTotalBytes; self.networkReceivedBytesPerSecond = networkReceivedBytesPerSecond
        self.networkSentBytesPerSecond = networkSentBytesPerSecond; self.battery = battery; self.thermal = thermal
        self.memoryUsedBytes = memoryUsedBytes; self.memoryTotalBytes = memoryTotalBytes
        self.memoryPressurePercent = memoryPressurePercent
    }

    public var diskRemainingFraction: Double? {
        guard let available = diskAvailableBytes, let total = diskTotalBytes, total > 0 else { return nil }
        return Double(available) / Double(total)
    }
}

public struct ChartPoint: Identifiable, Codable {
    public var id: Date { timestamp }
    public let timestamp: Date
    public let cpuUsage: Double?
    public let memoryUsedBytes: UInt64?
    public let systemPowerWatts: Double?
    public let batteryTemperatureCelsius: Double?
    public let thermal: ThermalLevel

    public init(snapshot: SystemSnapshot) {
        timestamp = snapshot.timestamp; cpuUsage = snapshot.cpuUsage; memoryUsedBytes = snapshot.memoryUsedBytes
        systemPowerWatts = snapshot.battery.systemPowerWatts
        batteryTemperatureCelsius = snapshot.battery.temperatureCelsius
        thermal = snapshot.thermal
    }
}

public struct ChartHistory {
    private var points: [ChartPoint] = []
    private let retentionSeconds: TimeInterval
    private let sampleSeconds: TimeInterval

    public init(retentionSeconds: TimeInterval = 3600, sampleSeconds: TimeInterval = 10) {
        self.retentionSeconds = retentionSeconds; self.sampleSeconds = sampleSeconds
    }

    public var all: [ChartPoint] { points }

    public mutating func append(_ snapshot: SystemSnapshot, force: Bool = false) {
        let cutoff = snapshot.timestamp.addingTimeInterval(-retentionSeconds)
        points.removeAll { $0.timestamp < cutoff }
        if !force, let last = points.last, snapshot.timestamp.timeIntervalSince(last.timestamp) < sampleSeconds { return }
        points.append(ChartPoint(snapshot: snapshot))
    }
}
