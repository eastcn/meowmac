import Foundation

public struct MetricReading {
    public let object: String
    public let value: Double
    public let sampledAt: Date
    public var resetAt: Date? = nil
    public var provider: QuotaProvider? = nil
    public var subject: String? = nil
}

public enum AlertMetric: String, Codable, CaseIterable, Identifiable {
    case cpuUsage = "cpu.usage", memoryPressure = "memory.pressure", memoryUsed = "memory.used"
    case swapUsed = "swap.used", diskFree = "disk.free", diskFreeBytes = "disk.freeBytes"
    case netDown = "net.down", netUp = "net.up", powerSystem = "power.system", batteryTemp = "battery.temp"
    case cpuTemp = "cpu.temp", gpuTemp = "gpu.temp", fanSpeed = "fan.speed", quotaRemaining = "quota.remaining"
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .cpuUsage: return "CPU 使用率"
        case .memoryPressure: return "内存压力"
        case .memoryUsed: return "内存已用"
        case .swapUsed: return "Swap 已用"
        case .diskFree, .diskFreeBytes: return "磁盘剩余"
        case .netDown: return "网络下行"
        case .netUp: return "网络上行"
        case .powerSystem: return "整机功耗"
        case .batteryTemp: return "电池温度"
        case .cpuTemp: return "CPU 温度"
        case .gpuTemp: return "GPU 温度"
        case .fanSpeed: return "风扇转速"
        case .quotaRemaining: return "额度窗口剩余"
        }
    }
    public var unit: String {
        switch self {
        case .cpuUsage, .memoryPressure, .memoryUsed, .diskFree, .quotaRemaining: return "%"
        case .swapUsed, .diskFreeBytes: return "GB"
        case .netDown, .netUp: return "MB/s"
        case .powerSystem: return "W"
        case .batteryTemp, .cpuTemp, .gpuTemp: return "°C"
        case .fanSpeed: return "% 最大值"
        }
    }
    public var group: String {
        switch self {
        case .quotaRemaining: return "额度"
        case .powerSystem, .batteryTemp, .cpuTemp, .gpuTemp, .fanSpeed: return "能耗与温度"
        default: return "系统"
        }
    }
    public var tab: PanelTab { self == .quotaRemaining ? .quota : .system }
    public var hasObjects: Bool { self == .quotaRemaining }
    public var sampleSeconds: Double { self == .quotaRemaining ? 1800 : 2 }
    public func read(_ input: HealthInputs) -> [MetricReading] {
        if self == .quotaRemaining {
            guard input.failedSources["quota", default: 0] == 0 else { return [] }
            return input.quotaSnapshots.flatMap { snapshot -> [MetricReading] in
                guard input.failedSources["quota." + snapshot.provider.rawValue, default: 0] == 0,
                      snapshot.updatedAt <= input.now else { return [] }
                return snapshot.windows.compactMap { window in
                    guard window.usedPercent.isFinite, window.resetsAt.map({ $0 > input.now }) ?? true else { return nil }
                    return MetricReading(object: snapshot.provider.rawValue + "." + window.identifier,
                                         value: window.remainingPercent, sampledAt: snapshot.updatedAt,
                                         resetAt: window.resetsAt, provider: snapshot.provider,
                                         subject: snapshot.provider.displayName + " " + window.displayName)
                }
            }
        }
        guard let system = input.system, input.failedSources["system", default: 0] == 0,
              system.timestamp <= input.now else { return [] }
        let value: Double?
        switch self {
        case .cpuUsage: value = system.cpuUsage.map { $0 * 100 }
        case .memoryPressure: value = system.memoryPressurePercent
        case .memoryUsed: value = system.memoryUsedFraction.map { $0 * 100 }
        case .swapUsed: value = system.swapUsedBytes.map { Double($0) / 1_000_000_000 }
        case .diskFree: value = system.diskRemainingFraction.map { $0 * 100 }
        case .diskFreeBytes: value = system.diskAvailableBytes.map { Double($0) / 1_000_000_000 }
        case .netDown: value = system.networkReceivedBytesPerSecond.map { $0 / 1_000_000 }
        case .netUp: value = system.networkSentBytesPerSecond.map { $0 / 1_000_000 }
        case .powerSystem: value = system.battery.systemPowerWatts
        case .batteryTemp: value = system.battery.temperatureCelsius
        case .cpuTemp: value = system.sensors?.cpuMaxCelsius
        case .gpuTemp: value = system.sensors?.gpuAverageCelsius
        case .fanSpeed: value = system.sensors?.leadingFan?.fraction.map { $0 * 100 }
        case .quotaRemaining: value = nil
        }
        guard let value, value.isFinite else { return [] }
        return [MetricReading(object: "system", value: value, sampledAt: system.timestamp)]
    }
}

public enum AlertComparison: String, Codable, CaseIterable {
    case gte, lte
    public var symbol: String { self == .gte ? "≥" : "≤" }
    public func matches(_ value: Double, threshold: Double) -> Bool { self == .gte ? value >= threshold : value <= threshold }
}
public enum AlertRuleLevel: String, Codable, CaseIterable {
    case warn, severe
    public var health: HealthLevel { self == .warn ? .warn : .severe }
    public var title: String { self == .warn ? "提醒" : "严重" }
}
public struct AlertScope: Codable, Equatable {
    public var provider: String?
    public var window: String?
    public init(provider: String? = nil, window: String? = nil) { self.provider = provider; self.window = window }
    public func contains(_ reading: MetricReading) -> Bool {
        (provider == nil || reading.provider?.rawValue == provider)
            && (window == nil || reading.object == (reading.provider?.rawValue ?? "") + "." + window!)
    }
}
public struct AlertRule: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// 用字符串保存未知指标，版本升级后仍能显示和编辑这条规则。
    public var metric: String
    public var comparison: AlertComparison
    public var threshold: Double
    public var durationSeconds: Double
    public var level: AlertRuleLevel
    public var enabled: Bool
    public var scope: AlertScope?
    public var available: Bool { AlertMetric(rawValue: metric) != nil }
    public init(id: String, name: String, metric: String, comparison: AlertComparison = .gte,
                threshold: Double, durationSeconds: Double = 0, level: AlertRuleLevel = .warn,
                enabled: Bool = true, scope: AlertScope? = nil) {
        self.id = id; self.name = name; self.metric = metric; self.comparison = comparison
        self.threshold = threshold; self.durationSeconds = durationSeconds; self.level = level
        self.enabled = enabled; self.scope = scope
    }
    public func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: #"^u-[0-9a-f]{8}$"#, options: .regularExpression) != nil,
              (1...40).contains(result.name.count), threshold.isFinite,
              durationSeconds.isFinite, (0...86400).contains(durationSeconds),
              scope?.provider.map({ QuotaProvider(rawValue: $0) != nil }) ?? true,
              scope?.window.map({ !$0.isEmpty && $0.utf8.count <= 80 && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 } }) ?? true else {
            throw AlertRuleError.invalid("规则的名称、身份、条件或对象无效")
        }
        return result
    }
    private enum CodingKeys: String, CodingKey { case id, name, metric, comparison, threshold, durationSeconds, level, enabled, scope }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        metric = try c.decode(String.self, forKey: .metric); comparison = try c.decode(AlertComparison.self, forKey: .comparison)
        threshold = try c.decode(Double.self, forKey: .threshold)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        level = try c.decodeIfPresent(AlertRuleLevel.self, forKey: .level) ?? .warn
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        scope = try c.decodeIfPresent(AlertScope.self, forKey: .scope)
    }
}
public typealias CustomAlertRule = AlertRule
public enum AlertRuleError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return nil }
}

public struct AlertRuleOverride: Codable, Equatable {
    public var enabled: Bool?
    public var threshold: Double?
    public var durationSeconds: Double?
    public var fairThermalSeconds: Double?
    public var fanHighSeconds: Double?
    public init(enabled: Bool? = nil, threshold: Double? = nil, durationSeconds: Double? = nil,
                fairThermalSeconds: Double? = nil, fanHighSeconds: Double? = nil) {
        self.enabled = enabled; self.threshold = threshold; self.durationSeconds = durationSeconds
        self.fairThermalSeconds = fairThermalSeconds; self.fanHighSeconds = fanHighSeconds
    }
}
public enum BuiltinAlertRule: String, CaseIterable, Codable, Identifiable {
    case memory = "system.memory", disk = "system.disk", process = "system.process", thermal = "system.thermal"
    case cooling = "system.cooling", quotaLow = "quota.low", balance = "quota.balance", pace = "quota.pace"
    case network = "network.fault", egress = "network.egress", source = "source.failure"
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .memory: return "内存压力持续偏高"
        case .disk: return "磁盘剩余不足"
        case .process: return "进程 CPU 持续偏高"
        case .thermal: return "系统已降频"
        case .cooling: return "建议降温"
        case .quotaLow: return "额度剩余不足"
        case .balance: return "余额不足"
        case .pace: return "额度偏快"
        case .network: return "网络故障"
        case .egress: return "出口 IP 变化"
        case .source: return "数据源失效"
        }
    }
    public var group: String {
        switch self {
        case .quotaLow, .balance, .pace: return "额度"
        case .network, .egress: return "网络"
        case .source: return "数据源"
        default: return "系统"
        }
    }
    public var defaults: AlertRuleOverride {
        switch self {
        case .memory: return .init(enabled: true, threshold: 61, durationSeconds: 600)
        case .disk: return .init(enabled: true, threshold: 10)
        case .process: return .init(enabled: true, threshold: 90, durationSeconds: 600)
        case .cooling: return .init(enabled: true, threshold: 80, fairThermalSeconds: 300, fanHighSeconds: 300)
        case .quotaLow: return .init(enabled: true, threshold: 20)
        case .source: return .init(enabled: true, threshold: 2)
        default: return .init(enabled: true)
        }
    }
    public var thresholdRange: ClosedRange<Double>? {
        switch self {
        case .memory: return 1...99
        case .disk: return 1...50
        case .process: return 10...800
        case .cooling: return 50...100
        case .quotaLow: return 1...90
        case .source: return 1...10
        default: return nil
        }
    }
    public var legacyKeys: [String] {
        switch self {
        case .memory: return ["memoryPressureSeconds"]
        case .disk: return ["diskRemainingWarn"]
        case .process: return ["runawayCPU", "runawaySeconds"]
        case .cooling: return ["fairThermalSeconds", "fanHighFraction", "fanHighSeconds"]
        case .quotaLow: return ["quotaRemainingWarn"]
        case .source: return ["sourceFailureCount"]
        default: return []
        }
    }
    public func sanitized(_ override: AlertRuleOverride, fallback: AlertRuleOverride) -> AlertRuleOverride {
        func valid(_ value: Double?, _ range: ClosedRange<Double>?, _ fallback: Double?) -> Double? {
            guard let value else { return fallback }
            guard let range, value.isFinite, range.contains(value) else { return fallback }
            return value
        }
        return .init(enabled: override.enabled ?? fallback.enabled,
                     threshold: valid(override.threshold, thresholdRange, fallback.threshold),
                     durationSeconds: valid(override.durationSeconds, defaults.durationSeconds == nil ? nil : 60...86400, fallback.durationSeconds),
                     fairThermalSeconds: valid(override.fairThermalSeconds, self == .cooling ? 60...7200 : nil, fallback.fairThermalSeconds),
                     fanHighSeconds: valid(override.fanHighSeconds, self == .cooling ? 60...7200 : nil, fallback.fanHighSeconds))
    }
}

public struct AlertRuleSet: Codable, Equatable {
    public var builtin: [String: AlertRuleOverride]
    public var custom: [CustomAlertRule]
    public private(set) var diagnostics: [String] = []
    public init(builtin: [String: AlertRuleOverride] = [:], custom: [CustomAlertRule] = [], diagnostics: [String] = []) {
        self.builtin = builtin; self.custom = custom; self.diagnostics = diagnostics
    }
    private enum CodingKeys: String, CodingKey { case builtin, custom }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
        init(stringValue: String) { self.stringValue = stringValue }
    }
    public init(from decoder: Decoder) throws {
        builtin = [:]; custom = []
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.builtin) {
            do {
                let values = try c.nestedContainer(keyedBy: Key.self, forKey: .builtin)
                for key in values.allKeys {
                    do {
                        let override = try values.decode(AlertRuleOverride.self, forKey: key)
                        builtin[key.stringValue] = override
                        do { _ = try AlertRuleSet(builtin: [key.stringValue: override]).validated() }
                        catch { diagnostics.append("内置规则 \(key.stringValue) 越界字段已回退默认值") }
                    }
                    catch { diagnostics.append("内置规则 \(key.stringValue) 无效，已丢弃") }
                }
            } catch { diagnostics.append("内置规则列表无效，已回退默认值") }
        }
        if c.contains(.custom) {
            do {
                var values = try c.nestedUnkeyedContainer(forKey: .custom)
                var seen = Set<String>()
                while !values.isAtEnd {
                    let entry = try values.superDecoder()
                    do {
                        let rule = try CustomAlertRule(from: entry).validated()
                        guard seen.insert(rule.id).inserted else { diagnostics.append("重复规则 \(rule.id)，已丢弃"); continue }
                        guard custom.count < 32 else { diagnostics.append("自定义规则超过 32 条，已丢弃"); continue }
                        custom.append(rule)
                    } catch { diagnostics.append("自定义规则无效，已丢弃：\(error.localizedDescription)") }
                }
            } catch { diagnostics.append("自定义规则列表无效，已丢弃") }
        }
    }
    public func effective(_ rule: BuiltinAlertRule, config: LocalConfig) -> AlertRuleOverride {
        let old: AlertRuleOverride
        switch rule {
        case .memory: old = .init(durationSeconds: config.memoryPressureSeconds)
        case .disk: old = .init(threshold: config.diskRemainingWarn * 100)
        case .process: old = .init(threshold: config.runawayCPU, durationSeconds: config.runawaySeconds)
        case .cooling: old = .init(threshold: config.fanHighFraction * 100, fairThermalSeconds: config.fairThermalSeconds, fanHighSeconds: config.fanHighSeconds)
        case .quotaLow: old = .init(threshold: config.quotaRemainingWarn * 100)
        case .source: old = .init(threshold: Double(config.sourceFailureCount))
        default: old = .init()
        }
        let legacy = rule.sanitized(old, fallback: rule.defaults)
        // 显式新字段越界时用默认值，不让旧字段重新接管。
        var fresh = builtin[rule.id] ?? .init()
        if let v = fresh.threshold, rule.thresholdRange?.contains(v) != true || !v.isFinite { fresh.threshold = rule.defaults.threshold }
        if let v = fresh.durationSeconds, !(60...86400).contains(v) || !v.isFinite { fresh.durationSeconds = rule.defaults.durationSeconds }
        if let v = fresh.fairThermalSeconds, !(60...7200).contains(v) || !v.isFinite { fresh.fairThermalSeconds = rule.defaults.fairThermalSeconds }
        if let v = fresh.fanHighSeconds, !(60...7200).contains(v) || !v.isFinite { fresh.fanHighSeconds = rule.defaults.fanHighSeconds }
        if rule == .source, let v = fresh.threshold, v.rounded() != v { fresh.threshold = rule.defaults.threshold }
        return rule.sanitized(fresh, fallback: legacy)
    }
    public func enabled(_ rule: BuiltinAlertRule, config: LocalConfig) -> Bool { effective(rule, config: config).enabled != false }
    public func validated() throws -> Self {
        guard custom.count <= 32, Set(custom.map(\.id)).count == custom.count else { throw AlertRuleError.invalid("规则超过 32 条或身份重复") }
        var result = self
        result.custom = try custom.map { try $0.validated() }
        for (id, value) in builtin {
            guard let rule = BuiltinAlertRule(rawValue: id) else { continue }
            let normalized = rule.sanitized(value, fallback: rule.defaults)
            if let v = value.threshold, v != normalized.threshold || (rule == .source && v.rounded() != v) { throw AlertRuleError.invalid("\(rule.name)阈值越界") }
            if let v = value.durationSeconds, v != normalized.durationSeconds { throw AlertRuleError.invalid("持续时长越界") }
            if let v = value.fairThermalSeconds, v != normalized.fairThermalSeconds { throw AlertRuleError.invalid("fair 持续时长越界") }
            if let v = value.fanHighSeconds, v != normalized.fanHighSeconds { throw AlertRuleError.invalid("风扇持续时长越界") }
        }
        return result
    }
    public func memoryRule(config: LocalConfig) -> AlertRule {
        let value = effective(.memory, config: config)
        return .init(id: BuiltinAlertRule.memory.id, name: BuiltinAlertRule.memory.name, metric: AlertMetric.memoryPressure.id,
                     threshold: value.threshold!, durationSeconds: value.durationSeconds!, enabled: value.enabled!)
    }
    /// 老检测器继续使用原单位，转换只集中在此处。
    public func detectorConfig(_ config: LocalConfig) -> LocalConfig {
        var next = config
        next.diskRemainingWarn = effective(.disk, config: config).threshold! / 100
        next.quotaRemainingWarn = effective(.quotaLow, config: config).threshold! / 100
        let process = effective(.process, config: config)
        next.runawayCPU = process.threshold!; next.runawaySeconds = process.durationSeconds!
        let cooling = effective(.cooling, config: config)
        next.fairThermalSeconds = cooling.fairThermalSeconds!; next.fanHighFraction = cooling.threshold! / 100; next.fanHighSeconds = cooling.fanHighSeconds!
        next.sourceFailureCount = Int(effective(.source, config: config).threshold!)
        return next
    }
}
