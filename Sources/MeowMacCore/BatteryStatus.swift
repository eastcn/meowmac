import CoreFoundation
import Foundation

/// 供电与充放电状态（D44）。判定顺序见 `BatteryStatus.parse`。
public enum BatteryPowerState: String, Codable, CaseIterable {
    case noBattery, battery, charging, charged, acNotCharging

    /// 界面上的状态文案。无电池时卡片不显示，这里只作兜底。
    public var title: String {
        switch self {
        case .noBattery: return "无电池"
        case .battery: return "使用电池"
        case .charging: return "充电中"
        case .charged: return "已充满"
        case .acNotCharging: return "接电源 · 未充电"
        }
    }

    public var isExternalPower: Bool { self == .charging || self == .charged || self == .acNotCharging }
}

/// `AppleSmartBattery` 的白名单字段。只有这些键可以被读取和传给解析函数，不包含任何序列号键。
public enum BatteryRegistryKeys {
    public static let topLevel = [
        "BatteryInstalled", "ExternalConnected", "IsCharging", "FullyCharged",
        "CurrentCapacity", "MaxCapacity", "AppleRawMaxCapacity", "DesignCapacity",
        "CycleCount", "DesignCycleCount9C", "Voltage", "Amperage",
        "AvgTimeToEmpty", "AvgTimeToFull", "Temperature",
    ]
    /// 嵌套字典只保留列出的子键。
    public static let nested: [String: [String]] = [
        "PowerTelemetryData": ["SystemLoad"],
        "AdapterDetails": ["Watts"],
    ]
    public static var all: Set<String> { Set(topLevel).union(nested.keys) }

    /// 只保留白名单内的键和子键。`read` 每次只读一个白名单键，不会被要求读其他键。
    public static func filtered(read: (String) -> Any?) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in topLevel { if let value = read(key) { result[key] = value } }
        for (key, children) in nested {
            guard let value = read(key) else { continue }
            // 不是字典时整项丢弃，不把未知内容传给解析函数。
            guard let dictionary = value as? [String: Any] else { continue }
            var kept: [String: Any] = [:]
            for child in children { if let item = dictionary[child] { kept[child] = item } }
            result[key] = kept
        }
        return result
    }
}

/// 解析时发现的字段问题。只含白名单键名和类别，不含读到的原文。
public struct BatteryFieldIssue: Equatable, CustomStringConvertible {
    public enum Category: String { case missing, wrongType }
    public let key: String
    public let category: Category
    public var description: String { "\(key):\(category.rawValue)" }
}

/// 电池读数（D44）。所有字段缺失或类型不符时为 nil，只影响对应一项。
public struct BatteryStatus: Equatable, Codable {
    public let state: BatteryPowerState
    /// 当前电量百分比（`CurrentCapacity`）。
    public let percent: Int?
    /// 系统口径的最大容量百分比（`MaxCapacity`），与“系统设置 › 电池”一致。
    public let maxCapacityPercent: Int?
    /// 原始满充容量（`AppleRawMaxCapacity`），mAh。
    public let rawMaxCapacity: Int?
    /// 设计容量（`DesignCapacity`），mAh。
    public let designCapacity: Int?
    public let cycleCount: Int?
    public let designCycleCount: Int?
    /// 充放电功率的绝对值，W。电流为 0 时为 0。
    public let powerWatts: Double?
    /// 系统给出的平均预计放电分钟数。65535、0、负数视为不可用。
    public let minutesToEmpty: Int?
    /// 系统给出的平均预计充满分钟数。65535、0、负数视为不可用。
    public let minutesToFull: Int?
    /// 适配器额定功率，W。
    public let adapterWatts: Int?

    public init(state: BatteryPowerState, percent: Int? = nil, maxCapacityPercent: Int? = nil, rawMaxCapacity: Int? = nil,
                designCapacity: Int? = nil, cycleCount: Int? = nil, designCycleCount: Int? = nil, powerWatts: Double? = nil,
                minutesToEmpty: Int? = nil, minutesToFull: Int? = nil, adapterWatts: Int? = nil) {
        self.state = state; self.percent = percent; self.maxCapacityPercent = maxCapacityPercent
        self.rawMaxCapacity = rawMaxCapacity; self.designCapacity = designCapacity
        self.cycleCount = cycleCount; self.designCycleCount = designCycleCount; self.powerWatts = powerWatts
        self.minutesToEmpty = minutesToEmpty; self.minutesToFull = minutesToFull; self.adapterWatts = adapterWatts
    }

    public static let noBattery = BatteryStatus(state: .noBattery)
    public var hasBattery: Bool { state != .noBattery }

    /// 原始满充与设计容量换算的百分比。
    public var rawHealthPercent: Double? {
        guard let raw = rawMaxCapacity, let design = designCapacity, raw >= 0, design > 0 else { return nil }
        return Double(raw) / Double(design) * 100
    }

    /// 当前状态下应显示的系统预计时间（D3）：放电取 `AvgTimeToEmpty`，充电取 `AvgTimeToFull`，其余不显示。
    public var estimateMinutes: Int? {
        switch state {
        case .battery: return minutesToEmpty
        case .charging: return minutesToFull
        default: return nil
        }
    }

    /// 输入只应是白名单字段组成的字典（见 `BatteryRegistryKeys.filtered`）。纯逻辑，不做 I/O。
    /// D8：`ExternalConnected` 为假是使用电池；为真时依次看 `IsCharging`、`FullyCharged`，其余为接电源未充电。
    /// 字典为空或 `BatteryInstalled` 为假时是无电池。
    public static func parse(_ properties: [String: Any]) -> BatteryStatus {
        guard !properties.isEmpty, BatteryValue.bool(properties["BatteryInstalled"]) != false else { return .noBattery }
        let external = BatteryValue.bool(properties["ExternalConnected"])
        let state: BatteryPowerState
        if external == false { state = .battery }
        else if external == true {
            if BatteryValue.bool(properties["IsCharging"]) == true { state = .charging }
            else if BatteryValue.bool(properties["FullyCharged"]) == true { state = .charged }
            else { state = .acNotCharging }
        } else {
            // 缺 ExternalConnected 时无法判断供电，按使用电池处理，预计时间仍只取系统值。
            state = .battery
        }
        let int = { (key: String) in BatteryValue.int(properties[key]) }
        let power: Double?
        if let amperage = int("Amperage") {
            if amperage == 0 { power = 0 }
            else if let voltage = int("Voltage"), voltage > 0 { power = Double(voltage) * Double(abs(amperage)) / 1_000_000 }
            else { power = nil }
        } else { power = nil }
        let adapter = (properties["AdapterDetails"] as? [String: Any]).flatMap { BatteryValue.int($0["Watts"]) }
        return BatteryStatus(state: state,
                             percent: int("CurrentCapacity").flatMap { (0...100).contains($0) ? $0 : nil },
                             maxCapacityPercent: int("MaxCapacity").flatMap { (0...200).contains($0) ? $0 : nil },
                             rawMaxCapacity: int("AppleRawMaxCapacity").flatMap { $0 > 0 ? $0 : nil },
                             designCapacity: int("DesignCapacity").flatMap { $0 > 0 ? $0 : nil },
                             cycleCount: int("CycleCount").flatMap { $0 >= 0 ? $0 : nil },
                             designCycleCount: int("DesignCycleCount9C").flatMap { $0 > 0 ? $0 : nil },
                             powerWatts: power,
                             minutesToEmpty: minutes(int("AvgTimeToEmpty")),
                             minutesToFull: minutes(int("AvgTimeToFull")),
                             adapterWatts: adapter.flatMap { $0 > 0 ? $0 : nil })
    }

    /// 65535（系统的“未知”）、0 和负数都表示没有可用的预计时间。
    static func minutes(_ value: Int?) -> Int? {
        guard let value, value > 0, value != 65535 else { return nil }
        return value
    }

    /// 列出缺失或类型不符的白名单字段，只含键名和类别。
    public static func issues(_ properties: [String: Any]) -> [BatteryFieldIssue] {
        var result: [BatteryFieldIssue] = []
        let booleans: Set<String> = ["BatteryInstalled", "ExternalConnected", "IsCharging", "FullyCharged"]
        for key in BatteryRegistryKeys.topLevel {
            guard let value = properties[key] else { result.append(.init(key: key, category: .missing)); continue }
            let ok = booleans.contains(key) ? BatteryValue.bool(value) != nil : BatteryValue.int(value) != nil
            if !ok { result.append(.init(key: key, category: .wrongType)) }
        }
        for (key, children) in BatteryRegistryKeys.nested.sorted(by: { $0.key < $1.key }) {
            guard let value = properties[key] else { result.append(.init(key: key, category: .missing)); continue }
            guard let dictionary = value as? [String: Any] else { result.append(.init(key: key, category: .wrongType)); continue }
            for child in children {
                guard let item = dictionary[child] else { result.append(.init(key: "\(key).\(child)", category: .missing)); continue }
                if BatteryValue.int(item) == nil { result.append(.init(key: "\(key).\(child)", category: .wrongType)) }
            }
        }
        return result
    }
}

/// IORegistry 的值是 CFNumber / CFBoolean。布尔和数字严格区分，不互相冒充。
enum BatteryValue {
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// 整数读数。IOKit 可能把负电流存成 64 位无符号数，按位模式还原为有符号数。
    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        if CFNumberIsFloatType(number) {
            let double = number.doubleValue
            guard double.isFinite, double.rounded() == double, abs(double) < 1e15 else { return nil }
            return Int(double)
        }
        return Int(truncatingIfNeeded: number.int64Value)
    }
}
