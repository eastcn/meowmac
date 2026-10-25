import Foundation

/// 桌面猫贴着的屏幕角（D45）。
public enum DesktopCatCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    public var isTop: Bool { self == .topLeft || self == .topRight }
    public var title: String {
        switch self {
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomLeft: return "左下角"
        case .bottomRight: return "右下角"
        }
    }
}

/// 位置只记“哪块屏幕的哪个角”。`display` 为 nil 表示主屏。
public struct DesktopCatPlacement: Codable, Equatable, Sendable {
    public var display: String?
    public var corner: DesktopCatCorner
    public init(display: String? = nil, corner: DesktopCatCorner = .bottomRight) {
        self.display = display; self.corner = corner
    }
    public static let `default` = DesktopCatPlacement()
}

public enum DesktopCatError: Error, LocalizedError, Equatable {
    case full, lastMetric, duplicate, unknownMetric, notSelected, invalid(String)
    public var errorDescription: String? {
        switch self {
        case .full: return "最多显示 \(DesktopCatConfig.maxMetrics) 项指标"
        case .lastMetric: return "至少保留 1 项指标"
        case .duplicate: return "这项指标已经选了"
        case .unknownMetric: return "指标无效"
        case .notSelected: return "这项指标没有选"
        case .invalid(let reason): return "桌面猫配置无效：\(reason)"
        }
    }
}

/// `config.json` 的 `desktopCat` 字段（D8）。坏值按字段回退，诊断只记原因，不含路径。
public struct DesktopCatConfig: Codable, Equatable, Sendable {
    /// 最多 8 项，2 列最多 4 行（D47）。
    public static let maxMetrics = 8
    public static let defaultMetrics = ["system.cpu", "system.memory", "quota.claude.minutes:300", "network.speed"]
    public var enabled = false
    public var metrics: [String] = DesktopCatConfig.defaultMetrics
    public var placement = DesktopCatPlacement()
    /// 用哪只 Codex 宠物，存 `$CODEX_HOME/pets` 下的目录名；nil 表示跟随当前猫。
    public var pet: String?
    /// 猫的高度（pt），36～104，默认 52（D47）。坏值按 52 运行，不改写文件。
    public var catHeight = Double(DesktopCatSize.defaultHeight)
    /// 读取时的回退原因，不写回文件。
    public var diagnostics: [String] = []

    public init(enabled: Bool = false, metrics: [String] = DesktopCatConfig.defaultMetrics,
                placement: DesktopCatPlacement = DesktopCatPlacement(), pet: String? = nil,
                catHeight: Double = Double(DesktopCatSize.defaultHeight), diagnostics: [String] = []) {
        self.enabled = enabled; self.metrics = metrics; self.placement = placement; self.pet = pet
        self.catHeight = catHeight; self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey { case enabled, metrics, placement, pet, catHeight }
    private enum PlacementKeys: String, CodingKey { case display, corner }

    /// 字段类型错误时抛错，由 `LocalConfig` 把整个桌面猫配置回退到默认值。
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try fields.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        var notes: [String] = []
        if let raw = try fields.decodeIfPresent([String].self, forKey: .metrics) {
            let result = Self.normalized(raw)
            metrics = result.metrics; notes += result.notes
        }
        if fields.contains(.placement) {
            let placementFields = try fields.nestedContainer(keyedBy: PlacementKeys.self, forKey: .placement)
            let display = try placementFields.decodeIfPresent(String.self, forKey: .display)
            let cornerName = try placementFields.decodeIfPresent(String.self, forKey: .corner)
            let corner = cornerName.flatMap(DesktopCatCorner.init(rawValue:))
            if cornerName != nil && corner == nil { notes.append("桌面猫的角无效，已放到右下角") }
            placement = DesktopCatPlacement(display: display?.isEmpty == true ? nil : display, corner: corner ?? .bottomRight)
        }
        if let name = try fields.decodeIfPresent(String.self, forKey: .pet) {
            if CodexPetManifest.isValidDirectoryName(name) { pet = name }
            else { notes.append("桌面猫的宠物名无效，已跟随当前猫") }
        }
        // 大小坏了只回退这一项，不影响其他字段。
        if fields.contains(.catHeight) {
            if let height = try? fields.decode(Double.self, forKey: .catHeight), DesktopCatSize.isValid(height) { catHeight = height }
            else { notes.append("桌面猫的大小无效，已按 52 pt 显示") }
        }
        diagnostics = notes
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(enabled, forKey: .enabled)
        try fields.encode(metrics, forKey: .metrics)
        var placementFields = fields.nestedContainer(keyedBy: PlacementKeys.self, forKey: .placement)
        try placementFields.encodeIfPresent(placement.display, forKey: .display)
        try placementFields.encode(placement.corner.rawValue, forKey: .corner)
        try fields.encodeIfPresent(pet, forKey: .pet)
        try fields.encode(catHeight, forKey: .catHeight)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enabled == rhs.enabled && lhs.metrics == rhs.metrics && lhs.placement == rhs.placement && lhs.pet == rhs.pet
            && lhs.catHeight == rhs.catHeight
    }

    /// 未知 id 跳过，重复去重，多出的取前 `maxMetrics` 项；全部无效时回到默认 4 项。
    public static func normalized(_ raw: [String]) -> (metrics: [String], notes: [String]) {
        var notes: [String] = []
        let known = raw.filter { DesktopCatMetric(id: $0) != nil }
        if known.count < raw.count { notes.append("桌面猫有 \(raw.count - known.count) 项未知指标，已跳过") }
        var seen = Set<String>()
        let unique = known.filter { seen.insert($0).inserted }
        if unique.count < known.count { notes.append("桌面猫的指标有重复，已去重") }
        if unique.count > maxMetrics { notes.append("桌面猫最多 \(maxMetrics) 项指标，已取前 \(maxMetrics) 项") }
        let result = Array(unique.prefix(maxMetrics))
        if result.isEmpty { notes.append("桌面猫没有有效指标，已用默认指标"); return (defaultMetrics, notes) }
        return (result, notes)
    }

    /// 写回前的校验：1～`maxMetrics` 项、不重复、id 都有效。
    public func validated() throws -> Self {
        guard (1...Self.maxMetrics).contains(metrics.count) else { throw DesktopCatError.invalid("指标数量必须是 1～\(Self.maxMetrics) 项") }
        guard Set(metrics).count == metrics.count else { throw DesktopCatError.duplicate }
        guard metrics.allSatisfy({ DesktopCatMetric(id: $0) != nil }) else { throw DesktopCatError.unknownMetric }
        if let display = placement.display {
            guard !display.isEmpty, display.count <= 128, display.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
                throw DesktopCatError.invalid("显示器标识无效")
            }
        }
        if let pet { guard CodexPetManifest.isValidDirectoryName(pet) else { throw DesktopCatError.invalid("宠物名无效") } }
        guard DesktopCatSize.isValid(catHeight) else { throw DesktopCatError.invalid("大小必须是 36～104 pt") }
        return self
    }

    public func adding(_ id: String) throws -> Self {
        guard DesktopCatMetric(id: id) != nil else { throw DesktopCatError.unknownMetric }
        guard !metrics.contains(id) else { throw DesktopCatError.duplicate }
        guard metrics.count < Self.maxMetrics else { throw DesktopCatError.full }
        var next = self; next.metrics.append(id); return next
    }

    public func removing(_ id: String) throws -> Self {
        guard metrics.contains(id) else { throw DesktopCatError.notSelected }
        guard metrics.count > 1 else { throw DesktopCatError.lastMetric }
        var next = self; next.metrics.removeAll { $0 == id }; return next
    }

    /// 已选就取消，未选就添加。
    public func toggling(_ id: String) throws -> Self {
        metrics.contains(id) ? try removing(id) : try adding(id)
    }

    /// 把 `id` 移到 `index`（按移走之后的位置计）。
    public func moving(_ id: String, to index: Int) throws -> Self {
        guard let from = metrics.firstIndex(of: id) else { throw DesktopCatError.notSelected }
        var next = self
        next.metrics.remove(at: from)
        next.metrics.insert(id, at: min(max(0, index), next.metrics.count))
        return next
    }

    public func with(enabled: Bool) -> Self { var next = self; next.enabled = enabled; return next }
    public func with(placement: DesktopCatPlacement) -> Self { var next = self; next.placement = placement; return next }
    public func with(pet: String?) -> Self { var next = self; next.pet = pet; return next }
    public func with(catHeight: Double) -> Self { var next = self; next.catHeight = catHeight; return next }
}

public enum DesktopCatCategory: String, CaseIterable, Sendable {
    case system, sensor, quota, network
    public var title: String {
        switch self {
        case .system: return "系统"
        case .sensor: return "传感器与电池"
        case .quota: return "额度"
        case .network: return "网络"
        }
    }
}

/// 指标 id 的解析（D9）。额度窗口的选择器沿用总览的 `OverviewQuota.selector(for:among:)`。
public enum DesktopCatMetric: Hashable, Sendable {
    case cpu, memory, power, disk, temperature, fan, battery
    case quotaWindow(QuotaProvider, String)
    case quotaBalance(QuotaProvider)
    case costToday
    case networkSpeed, networkStatus, proxyToday

    private static let fixed: [String: DesktopCatMetric] = [
        "system.cpu": .cpu, "system.memory": .memory, "system.power": .power, "system.disk": .disk,
        "sensor.temperature": .temperature, "sensor.fan": .fan, "battery.level": .battery,
        "quota.cost.today": .costToday,
        "network.speed": .networkSpeed, "network.status": .networkStatus, "network.proxy.today": .proxyToday,
    ]

    public init?(id: String) {
        if let metric = Self.fixed[id] { self = metric; return }
        guard id.hasPrefix("quota.") else { return nil }
        let rest = id.dropFirst(6)
        guard let dot = rest.firstIndex(of: "."), let provider = QuotaProvider(rawValue: String(rest[..<dot])) else { return nil }
        let selector = String(rest[rest.index(after: dot)...])
        if selector == "balance" { self = .quotaBalance(provider); return }
        guard Self.validSelector(selector) else { return nil }
        self = .quotaWindow(provider, selector)
    }

    static func validSelector(_ selector: String) -> Bool {
        if selector.hasPrefix("minutes:") {
            let text = String(selector.dropFirst(8))
            guard let minutes = Int(text), minutes > 0, String(minutes) == text else { return false }
            return true
        }
        return selector.hasPrefix("id:") && selector.count > 3 && selector.count <= 131
            && selector.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }

    public var id: String {
        switch self {
        case .cpu: return "system.cpu"
        case .memory: return "system.memory"
        case .power: return "system.power"
        case .disk: return "system.disk"
        case .temperature: return "sensor.temperature"
        case .fan: return "sensor.fan"
        case .battery: return "battery.level"
        case .quotaWindow(let provider, let selector): return "quota.\(provider.rawValue).\(selector)"
        case .quotaBalance(let provider): return "quota.\(provider.rawValue).balance"
        case .costToday: return "quota.cost.today"
        case .networkSpeed: return "network.speed"
        case .networkStatus: return "network.status"
        case .proxyToday: return "network.proxy.today"
        }
    }

    public var category: DesktopCatCategory {
        switch self {
        case .cpu, .memory, .power, .disk: return .system
        case .temperature, .fan, .battery: return .sensor
        case .quotaWindow, .quotaBalance, .costToday: return .quota
        case .networkSpeed, .networkStatus, .proxyToday: return .network
        }
    }

    /// 目录与菜单里的固定顺序。额度窗口按渠道和窗口的实际顺序插在余额之前。
    var sortKey: Int {
        switch self {
        case .cpu: return 0
        case .memory: return 1
        case .power: return 2
        case .disk: return 3
        case .temperature: return 10
        case .fan: return 11
        case .battery: return 12
        case .quotaWindow, .quotaBalance: return 20
        case .costToday: return 29
        case .networkSpeed: return 30
        case .networkStatus: return 31
        case .proxyToday: return 32
        }
    }
}

/// 目录里的一项：只列当前可用的指标。
public struct DesktopCatCatalogEntry: Equatable, Sendable {
    public let id: String
    public let category: DesktopCatCategory
    /// 菜单和设置里的名称，例如“Claude · 5 小时”。
    public let title: String
}

/// 气泡里一项指标的颜色角色。`state` 是总览的状态色。
public enum DesktopCatColor: Equatable {
    case blue, teal, gray, orange, indigo, brown
    case state(HealthLevel)
}

/// 气泡里的一项：标签、附注、数值、横线和提示。
public struct DesktopCatItem: Equatable {
    public let id: String
    public let label: String
    /// 标签右侧的附注，放不下时先去掉。
    public let note: String?
    public let value: String
    /// 横线长度 0～1；nil 表示横线留空（缺数据或这类指标没有横线）。
    public let bar: Double?
    public let color: DesktopCatColor
    /// 数值文字用状态色；nil 表示正文色。
    public let valueLevel: HealthLevel?
    public let missing: Bool
    /// 提示里的全称，例如“Claude 5 小时窗口剩余”。
    public let fullName: String
    public let updatedAt: Date?

    public init(id: String, label: String, note: String? = nil, value: String, bar: Double?, color: DesktopCatColor,
                valueLevel: HealthLevel? = nil, missing: Bool = false, fullName: String, updatedAt: Date? = nil) {
        self.id = id; self.label = label; self.note = note; self.value = value; self.bar = bar.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        self.color = color; self.valueLevel = valueLevel; self.missing = missing; self.fullName = fullName; self.updatedAt = updatedAt
    }

    /// 悬停提示：全称和数据时间，例如“Claude 5 小时窗口剩余 72% · 13:57 更新”。
    public func tooltip(timeZone: TimeZone = .current) -> String {
        if missing { return fullName + " · 暂无数据" }
        guard let updatedAt else { return fullName + " " + value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = timeZone; formatter.dateFormat = "HH:mm"
        return fullName + " " + value + " · " + formatter.string(from: updatedAt) + " 更新"
    }
}

/// 计算目录和气泡数值所需的现有数据。全部来自已有采集，不新增数据源（D45）。
public struct DesktopCatInputs {
    public var snapshot: SystemSnapshot?
    public var quotaProviders: [QuotaProvider] = []
    public var quotas: [QuotaProvider: QuotaSnapshot] = [:]
    public var quotaBasis: QuotaBasis = .remaining
    public var balanceThresholds: [QuotaProvider: Double] = [:]
    /// Claude 与 Codex 今日花费之和；两边都没有花费数据时为 nil。
    public var costToday: Double?
    public var costAvailable = false
    public var costUpdatedAt: Date?
    public var networkAvailable = false
    public var networkTone: NetworkTone = .gray
    /// 网络状态的附注，例如最严重的检查项名称。
    public var networkReason: String?
    public var networkCheckedAt: Date?
    public var proxyEnabled = false
    /// 今日经代理的上下行合计；读不到控制接口时为 nil。
    public var proxyTodayBytes: Double?
    public var proxyUpdatedAt: Date?
    public init() {}
}

public enum DesktopCatCatalog {
    /// 当前可用的指标，按四类和固定顺序排列。
    public static func entries(_ inputs: DesktopCatInputs) -> [DesktopCatCatalogEntry] {
        var result: [(DesktopCatMetric, String)] = [(.cpu, "CPU"), (.memory, "内存压力"), (.power, "整机功耗"), (.disk, "磁盘剩余")]
        let sensors = inputs.snapshot?.sensors
        if sensors?.cpuAverageCelsius != nil { result.append((.temperature, "SoC 温度")) }
        if let fans = sensors?.fans, !fans.isEmpty { result.append((.fan, "风扇")) }
        if inputs.snapshot?.battery.status?.hasBattery == true { result.append((.battery, "电池电量")) }
        for provider in inputs.quotaProviders {
            let quota = inputs.quotas[provider]
            let windows = quota?.windows ?? []
            for window in windows {
                let selector = OverviewQuota.selector(for: window, among: windows)
                result.append((.quotaWindow(provider, selector), provider.displayName + " · " + windowName(window)))
            }
            if quota?.balance != nil { result.append((.quotaBalance(provider), provider.displayName + " · 余额")) }
        }
        if inputs.costAvailable { result.append((.costToday, "今日花费")) }
        result += [(.networkSpeed, "网速"), (.networkStatus, "网络状态")]
        if inputs.proxyEnabled { result.append((.proxyToday, "今日代理流量")) }
        return result.enumerated().sorted { a, b in
            a.element.0.sortKey == b.element.0.sortKey ? a.offset < b.offset : a.element.0.sortKey < b.element.0.sortKey
        }.map { DesktopCatCatalogEntry(id: $0.element.0.id, category: $0.element.0.category, title: $0.element.1) }
    }

    /// 已选但当前不在目录里的指标在菜单和设置里显示的名称。
    public static func title(for id: String, inputs: DesktopCatInputs) -> String {
        if let entry = entries(inputs).first(where: { $0.id == id }) { return entry.title }
        guard let metric = DesktopCatMetric(id: id) else { return id }
        switch metric {
        case .cpu: return "CPU"
        case .memory: return "内存压力"
        case .power: return "整机功耗"
        case .disk: return "磁盘剩余"
        case .temperature: return "SoC 温度"
        case .fan: return "风扇"
        case .battery: return "电池电量"
        case .quotaWindow(let provider, let selector):
            if selector.hasPrefix("minutes:"), let minutes = Int(selector.dropFirst(8)) {
                return provider.displayName + " · " + windowName(QuotaWindow(usedPercent: 0, windowMinutes: minutes, resetsAt: nil, resetDescription: nil))
            }
            return provider.displayName + " · " + String(selector.dropFirst(3))
        case .quotaBalance(let provider): return provider.displayName + " · 余额"
        case .costToday: return "今日花费"
        case .networkSpeed: return "网速"
        case .networkStatus: return "网络状态"
        case .proxyToday: return "今日代理流量"
        }
    }

    /// 与总览“额度”格子的窗口名一致：5 小时、7 天，其余去掉“窗口”二字。
    public static func windowName(_ window: QuotaWindow) -> String {
        switch window.effectiveWindowMinutes {
        case 300: return "5 小时"
        case 10080: return "7 天"
        default: return window.displayName.replacingOccurrences(of: "窗口", with: "").trimmingCharacters(in: .whitespaces)
        }
    }

    /// 气泡附注里的短窗口名：5h、7d。
    public static func shortWindowName(_ window: QuotaWindow) -> String {
        guard let minutes = window.effectiveWindowMinutes, minutes > 0 else { return windowName(window) }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// 已选指标按顺序换成气泡里的项。没有数据的项显示“—”，不替换、不删除（D7）。
    public static func items(selected: [String], inputs: DesktopCatInputs) -> [DesktopCatItem] {
        selected.compactMap { id in DesktopCatMetric(id: id).map { item($0, inputs: inputs) } }
    }

    static func missing(_ metric: DesktopCatMetric, label: String, note: String? = nil, fullName: String) -> DesktopCatItem {
        DesktopCatItem(id: metric.id, label: label, note: note, value: "—", bar: nil, color: .gray, missing: true, fullName: fullName)
    }

    public static func item(_ metric: DesktopCatMetric, inputs: DesktopCatInputs) -> DesktopCatItem {
        let snapshot = inputs.snapshot
        let sampledAt = snapshot?.timestamp
        func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
        switch metric {
        case .cpu:
            guard let cpu = snapshot?.cpuUsage, cpu.isFinite else { return missing(metric, label: "CPU", fullName: "CPU 使用率") }
            return DesktopCatItem(id: metric.id, label: "CPU", value: percent(cpu * 100), bar: cpu, color: .blue,
                                  fullName: "CPU 使用率", updatedAt: sampledAt)
        case .memory:
            guard let memory = snapshot?.memoryPressurePercent, memory.isFinite else { return missing(metric, label: "内存", fullName: "内存压力") }
            let level: HealthLevel = snapshot?.memoryPressure == .critical ? .severe : snapshot?.memoryPressure == .warn ? .warn : .normal
            return DesktopCatItem(id: metric.id, label: "内存", value: percent(memory), bar: memory / 100, color: .state(level),
                                  valueLevel: level == .normal ? nil : level, fullName: "内存压力", updatedAt: sampledAt)
        case .power:
            guard let watts = snapshot?.battery.systemPowerWatts, watts.isFinite, watts >= 0 else { return missing(metric, label: "功耗", fullName: "整机功耗") }
            return DesktopCatItem(id: metric.id, label: "功耗", value: String(format: "%.1f W", watts), bar: watts / 40, color: .teal,
                                  fullName: "整机功耗", updatedAt: sampledAt)
        case .disk:
            guard let disk = snapshot.flatMap({ DiskCapacity(available: $0.diskAvailableBytes, total: $0.diskTotalBytes) }) else {
                return missing(metric, label: "磁盘", note: "可用", fullName: "磁盘可用空间")
            }
            let low = Double(disk.availableBytes) / Double(disk.totalBytes) < 0.1
            return DesktopCatItem(id: metric.id, label: "磁盘", note: "可用", value: String(format: "%.0f G", Double(disk.availableBytes) / 1_000_000_000),
                                  bar: Double(disk.usedBytes) / Double(disk.totalBytes), color: low ? .orange : .gray,
                                  valueLevel: low ? .warn : nil, fullName: "磁盘可用空间", updatedAt: sampledAt)
        case .temperature:
            guard let celsius = snapshot?.sensors?.cpuAverageCelsius, celsius.isFinite else { return missing(metric, label: "温度", fullName: "SoC 平均温度") }
            return DesktopCatItem(id: metric.id, label: "温度", value: String(format: "%.0f °C", celsius), bar: (celsius - 30) / 70, color: .indigo,
                                  fullName: "SoC 平均温度", updatedAt: sampledAt)
        case .fan:
            guard let fan = snapshot?.sensors?.leadingFan, fan.rpm.isFinite else { return missing(metric, label: "风扇", fullName: "风扇转速") }
            return DesktopCatItem(id: metric.id, label: "风扇", value: String(format: "%.0f rpm", fan.rpm), bar: fan.fraction ?? 0, color: .brown,
                                  fullName: "风扇转速", updatedAt: sampledAt)
        case .battery:
            guard let status = snapshot?.battery.status, status.hasBattery, let level = status.percent else {
                return missing(metric, label: "电池", fullName: "电池电量")
            }
            let note: String = status.state == .battery ? "放电" : status.state == .charging ? "⚡" : "接电源"
            return DesktopCatItem(id: metric.id, label: "电池", note: note, value: "\(level)%", bar: Double(level) / 100,
                                  color: level <= 20 ? .orange : .gray, fullName: "电池电量（\(status.state.title)）", updatedAt: sampledAt)
        case .quotaWindow(let provider, let selector):
            let quota = inputs.quotaProviders.contains(provider) ? inputs.quotas[provider] : nil
            guard let window = OverviewQuota(provider: provider, window: selector).selectedWindow(in: quota) else {
                let name = title(for: metric.id, inputs: DesktopCatInputs())
                let short = selector.hasPrefix("minutes:") ? Int(selector.dropFirst(8)).map {
                    shortWindowName(QuotaWindow(usedPercent: 0, windowMinutes: $0, resetsAt: nil, resetDescription: nil))
                } : nil
                return missing(metric, label: provider.displayName, note: short, fullName: name.replacingOccurrences(of: " · ", with: " ") + " 窗口")
            }
            let remaining = window.remainingPercent
            let shown = inputs.quotaBasis == .remaining ? remaining : window.usedPercent
            let level = HealthLevel.quotaLevel(remaining: remaining)
            let basis = inputs.quotaBasis == .remaining ? "剩余" : "已用"
            return DesktopCatItem(id: metric.id, label: provider.displayName, note: shortWindowName(window), value: percent(shown),
                                  bar: shown / 100, color: .state(level), valueLevel: level == .normal ? nil : level,
                                  fullName: provider.displayName + " " + windowName(window) + "窗口" + basis, updatedAt: quota?.updatedAt)
        case .quotaBalance(let provider):
            let quota = inputs.quotaProviders.contains(provider) ? inputs.quotas[provider] : nil
            guard let balance = quota?.balance else { return missing(metric, label: provider.displayName, fullName: provider.displayName + " 余额") }
            let threshold = inputs.balanceThresholds[provider] ?? QuotaSourceList.defaultBalanceWarn
            let low = threshold > 0 && (balance.value.map { $0 < threshold } ?? false)
            return DesktopCatItem(id: metric.id, label: provider.displayName, value: balance.amount, bar: nil, color: .gray,
                                  valueLevel: low ? .warn : nil, fullName: provider.displayName + " 余额", updatedAt: quota?.updatedAt)
        case .costToday:
            guard inputs.costAvailable, let cost = inputs.costToday, cost.isFinite else {
                return missing(metric, label: "花费", note: "今日", fullName: "今日花费（Claude + Codex）")
            }
            return DesktopCatItem(id: metric.id, label: "花费", note: "今日", value: String(format: "$%.2f", cost), bar: nil, color: .gray,
                                  fullName: "今日花费（Claude + Codex）", updatedAt: inputs.costUpdatedAt)
        case .networkSpeed:
            guard let down = snapshot?.networkReceivedBytesPerSecond, down.isFinite else {
                return missing(metric, label: "网络", fullName: "整机网速")
            }
            // 与总览“网络”格子同口径：数值是下行，附注是上行，满长横线用结论色。
            let up = snapshot?.networkSentBytesPerSecond.map { "↑" + MetricFormat.rate($0) }
            return DesktopCatItem(id: metric.id, label: "网络", note: up, value: "↓" + MetricFormat.rate(down), bar: 1,
                                  color: networkColor(inputs.networkTone), fullName: "整机网速", updatedAt: sampledAt)
        case .networkStatus:
            guard inputs.networkAvailable else { return missing(metric, label: "网络", fullName: "网络状态") }
            let value: String, level: HealthLevel?
            switch inputs.networkTone {
            case .green: value = "正常"; level = nil
            case .yellow: value = "提醒"; level = .warn
            case .red: value = "异常"; level = .severe
            case .gray: value = "待确认"; level = nil
            }
            return DesktopCatItem(id: metric.id, label: "网络", note: inputs.networkTone == .green ? nil : inputs.networkReason, value: value, bar: 1,
                                  color: networkColor(inputs.networkTone), valueLevel: level,
                                  fullName: "网络状态" + (inputs.networkReason.map { "（\($0)）" } ?? ""), updatedAt: inputs.networkCheckedAt)
        case .proxyToday:
            guard inputs.proxyEnabled, let bytes = inputs.proxyTodayBytes, bytes.isFinite else {
                return missing(metric, label: "代理", note: "今日", fullName: "今日代理流量")
            }
            return DesktopCatItem(id: metric.id, label: "代理", note: "今日", value: ProxyTrafficFormat.bytes(bytes), bar: nil, color: .gray,
                                  fullName: "今日代理流量", updatedAt: inputs.proxyUpdatedAt)
        }
    }

    static func networkColor(_ tone: NetworkTone) -> DesktopCatColor {
        switch tone {
        case .green: return .state(.normal)
        case .yellow: return .state(.warn)
        case .red: return .state(.severe)
        case .gray: return .gray
        }
    }
}

public extension HealthLevel {
    /// 额度剩余的状态档位：不低于 50% 正常，20%～50% 提醒，低于 20% 严重。总览和桌面猫共用。
    static func quotaLevel(remaining: Double) -> HealthLevel { remaining >= 50 ? .normal : remaining >= 20 ? .warn : .severe }
}

public extension ConfigStore {
    /// 只写 `desktopCat` 一个字段，保留其他字段和未知字段。整个文件无效时拒绝，不覆盖原文件。
    static func saveDesktopCat(_ config: DesktopCatConfig, to url: URL = defaultURL) throws {
        let valid = try config.validated()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
        try updateField("desktopCat", value: object, at: url)
    }

    /// 只写 `desktopCat.catHeight`，`desktopCat` 的其他字段和未知字段原样保留（plan D16）。
    /// 文件里的 `desktopCat` 结构无效（整组按默认值运行）时，改为整组写入 `fallback`（界面正在使用的配置），
    /// 否则新的大小仍会随整组一起被忽略。
    static func saveDesktopCatHeight(_ height: Double, fallback: DesktopCatConfig, to url: URL = defaultURL) throws {
        guard DesktopCatSize.isValid(height) else { throw DesktopCatError.invalid("大小必须是 36～104 pt") }
        let raw = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["desktopCat"]
        if var object = raw as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: object),
           (try? JSONDecoder().decode(DesktopCatConfig.self, from: data)) != nil {
            object["catHeight"] = height
            try updateField("desktopCat", value: object, at: url)
        } else {
            try saveDesktopCat(fallback.with(catHeight: height), to: url)
        }
    }
}
