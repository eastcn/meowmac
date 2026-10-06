import Foundation

/// 系统通知的类别（D41）。降温提示不通知，所以没有对应类别。
public enum NotificationCategory: String, Codable, CaseIterable {
    case network, egress, quotaLow, quotaPace, disk, process, memory, thermal, source

    public init?(kind: ReminderKind) {
        switch kind {
        case .network: self = .network
        case .quotaLow: self = .quotaLow
        case .quotaPace: self = .quotaPace
        case .disk: self = .disk
        case .process: self = .process
        case .memory: self = .memory
        case .thermal: self = .thermal
        case .source: self = .source
        case .cooling, .custom: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .network: return "网络故障"
        case .egress: return "出口 IP"
        case .quotaLow: return "额度不足"
        case .quotaPace: return "额度偏快"
        case .disk: return "磁盘不足"
        case .process: return "进程 CPU 持续偏高"
        case .memory: return "内存压力持续偏高"
        case .thermal: return "系统已降频"
        case .source: return "数据源失效"
        }
    }

    /// 默认全开，数据源失效默认关。
    public static let defaultEnabled = Set(allCases).subtracting([.source])
}

/// 通知开关，本机设置，不进猫包。
public struct NotificationSettings: Codable, Equatable {
    public var enabled = true
    public var rules: [String: Bool] = [:]
    public init() { rules = Self.defaultRules }
    public static var defaultRules: [String: Bool] {
        Dictionary(BuiltinAlertRule.allCases.map { ($0.id, $0 != .source && $0 != .cooling) }, uniquingKeysWith: { first, _ in first })
    }
    /// 兼容旧菜单和旧文件。写盘仍带类别，独立规则开关以 rules 为准。
    public var categories: Set<NotificationCategory> {
        get { Set(NotificationCategory.allCases.filter { category in Self.ruleIDs(category).contains { rules[$0] ?? Self.defaultRules[$0] ?? true } }) }
        set { for category in NotificationCategory.allCases { for id in Self.ruleIDs(category) { rules[id] = newValue.contains(category) } } }
    }
    public static func ruleIDs(_ category: NotificationCategory) -> [String] {
        switch category {
        case .network: return ["network.fault"]
        case .egress: return ["network.egress"]
        case .quotaLow: return ["quota.low", "quota.balance"]
        case .quotaPace: return ["quota.pace"]
        case .disk: return ["system.disk"]
        case .process: return ["system.process"]
        case .memory: return ["system.memory"]
        case .thermal: return ["system.thermal"]
        case .source: return ["source.failure"]
        }
    }
    public func allows(ruleID: String) -> Bool { enabled && (rules[ruleID] ?? Self.defaultRules[ruleID] ?? true) }
    public func allows(_ category: NotificationCategory) -> Bool { enabled && categories.contains(category) }
    private enum CodingKeys: String, CodingKey { case enabled, categories, rules }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if let categories = try c.decodeIfPresent([String].self, forKey: .categories) {
            self.categories = Set(categories.compactMap(NotificationCategory.init(rawValue:)))
        }
        if let rules = try c.decodeIfPresent([String: Bool].self, forKey: .rules) {
            self.rules.merge(rules) { _, new in new }
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled); try c.encode(categories.map(\.rawValue).sorted(), forKey: .categories)
        try c.encode(rules, forKey: .rules)
    }
}

public func ruleID(for reminder: Reminder) -> String? { ruleID(forKey: reminder.id) }
public func ruleID(forKey key: String) -> String? {
    let fields = key.split(separator: ".")
    guard let kindName = fields.first, let kind = ReminderKind(rawValue: String(kindName)) else { return nil }
    switch kind {
    case .custom: return fields.count >= 3 ? String(fields[1]) : nil
    case .quotaLow: return key.hasSuffix(".balance") ? "quota.balance" : "quota.low"
    case .quotaPace: return "quota.pace"
    case .disk: return "system.disk"
    case .process: return "system.process"
    case .memory: return "system.memory"
    case .thermal: return "system.thermal"
    case .network: return "network.fault"
    case .source: return "source.failure"
    case .cooling: return nil
    }
}

/// 某个提醒的通知状态。恢复后保留到冷却结束，用来判断能否再次通知。
public struct NotifiedRecord: Codable, Equatable {
    public let key: String
    public var level: HealthLevel
    public var notifiedAt: Date
    /// 额度类的重置时间，同一周期内最多通知一次。
    public var cycleResetAt: Date?
    public var recoveredAt: Date?
    /// 暂缓期间出现或仍在的问题，暂缓结束后补发一次。
    public var pendingAfterSnooze: Bool
    /// 恢复后在冷却期内重现、没有通知时，记下那次恢复的时刻。之后升级也要满足新档位的冷却。
    public var silentSince: Date?
    /// 最近一次出现在提醒里的时刻。长期既不出现也得不到确认的记录按恢复处理。
    public var lastSeenAt: Date?
    /// 上次通知时的档位。重现或升级时高于它，说明用户还没收到这一档的通知。旧记录缺省时用 `level`。
    public var notifiedLevel: HealthLevel?
    public init(key: String, level: HealthLevel, notifiedAt: Date, cycleResetAt: Date? = nil,
                recoveredAt: Date? = nil, pendingAfterSnooze: Bool = false, silentSince: Date? = nil, lastSeenAt: Date? = nil,
                notifiedLevel: HealthLevel? = nil) {
        self.key = key; self.level = level; self.notifiedAt = notifiedAt; self.cycleResetAt = cycleResetAt
        self.recoveredAt = recoveredAt; self.pendingAfterSnooze = pendingAfterSnooze
        self.silentSince = silentSince; self.lastSeenAt = lastSeenAt; self.notifiedLevel = notifiedLevel
    }
}

public struct NotificationDecision {
    /// 需要发送的提醒，按严重程度和标签页排序。
    public var reminders: [Reminder]
    public var records: [String: NotifiedRecord]
}

public enum NotificationDecider {
    public static let recoveryCooldown: TimeInterval = 3600
    public static let severeRecoveryCooldown: TimeInterval = 600
    public static let maxRecords = 256
    /// 进行中的记录连续这么久既不出现、也得不到确认（渠道被移除、窗口标识变化等），按恢复处理。
    public static let unseenTimeout: TimeInterval = 86400
    static func cooldown(for level: HealthLevel) -> TimeInterval { level == .severe ? severeRecoveryCooldown : recoveryCooldown }

    /// 输入是 reconcile 之后的全部提醒（含未确认的）。不在列表里、且 `confirmsRecovery` 认可的键才算恢复；
    /// 刚启动还没有检测结果时，不在列表里只表示未知，记录保持不变。
    /// 开关关闭时照样维护记录，只是不发送，重新打开时不会把已有问题一次补发出来。
    /// `observingSince` 是本次开始观察的时刻（应用启动）。应用关闭期间不计入“长期未出现”。
    public static func decide(reminders: [Reminder], isSnoozed: (Reminder) -> Bool, records: [String: NotifiedRecord],
                              settings: NotificationSettings, now: Date,
                              confirmsRecovery: (String) -> Bool = { _ in true },
                              observingSince: Date = .distantPast) -> NotificationDecision {
        var next = records
        let present = Set(reminders.map(\.id))
        for (key, var record) in next where !present.contains(key) && record.recoveredAt == nil {
            let stale = now.timeIntervalSince(max(record.lastSeenAt ?? record.notifiedAt, observingSince)) >= unseenTimeout
            guard confirmsRecovery(key) || stale else { continue }
            record.recoveredAt = now; record.pendingAfterSnooze = false; record.silentSince = nil
            next[key] = record
        }
        var out: [Reminder] = []
        for reminder in reminders where reminder.level > .normal {
            guard let ruleID = ruleID(for: reminder), reminder.confirmed else { continue }
            let key = reminder.id
            let quota = reminder.isCycleReminder
            let cycle = quota ? reminder.resetAt : nil
            let old = next[key]
            var notify = true
            if let old {
                let upgraded = reminder.level > old.level
                let newCycle = quota && sameCycle(old.cycleResetAt, cycle) == false
                // 高于上次通知的档位：用户还没收到这一档，立即通知。
                let aboveNotified = reminder.level > (old.notifiedLevel ?? old.level)
                // 静默重现后回到已通知过的档位，要离那次恢复满该档的冷却，避免来回波动时反复通知。
                let upgradeAllowed = upgraded && (aboveNotified || old.silentSince.map { now.timeIntervalSince($0) >= cooldown(for: reminder.level) } ?? true)
                if old.recoveredAt == nil {
                    notify = upgradeAllowed || newCycle || old.pendingAfterSnooze
                } else if quota && sameCycle(old.cycleResetAt, cycle) == true {
                    notify = upgraded
                } else if newCycle {
                    notify = true
                } else {
                    notify = aboveNotified || old.recoveredAt.map { now.timeIntervalSince($0) >= cooldown(for: reminder.level) } ?? true
                }
            }
            if isSnoozed(reminder) {
                next[key] = NotifiedRecord(key: key, level: max(old?.level ?? reminder.level, reminder.level),
                                           notifiedAt: old?.notifiedAt ?? now, cycleResetAt: cycle ?? old?.cycleResetAt,
                                           pendingAfterSnooze: true, lastSeenAt: now, notifiedLevel: old?.notifiedLevel ?? old?.level)
                continue
            }
            if notify && settings.allows(ruleID: ruleID) { out.append(reminder) }
            // 恢复后重现算新的一轮：档位从当前档开始，之后升级为严重时能再通知。
            let restart = notify || old?.recoveredAt != nil
            let silentSince = notify ? nil : old?.recoveredAt ?? old?.silentSince
            next[key] = NotifiedRecord(key: key, level: restart ? reminder.level : max(old?.level ?? reminder.level, reminder.level),
                                       notifiedAt: notify ? now : old?.notifiedAt ?? now,
                                       cycleResetAt: cycle ?? old?.cycleResetAt, silentSince: silentSince, lastSeenAt: now,
                                       notifiedLevel: notify ? reminder.level : old?.notifiedLevel ?? old?.level)
        }
        return NotificationDecision(reminders: out.sorted(by: order), records: prune(next, now: now))
    }

    /// nil 表示无法判断（缺少可靠的重置时间）。
    static func sameCycle(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        guard let lhs, let rhs else { return nil }
        return abs(lhs.timeIntervalSince(rhs)) <= QuotaHistorySeries.resetTolerance
    }

    static func order(_ lhs: Reminder, _ rhs: Reminder) -> Bool {
        if lhs.level != rhs.level { return lhs.level > rhs.level }
        let tabs = PanelTab.allCases
        if lhs.tab != rhs.tab { return tabs.firstIndex(of: lhs.tab)! < tabs.firstIndex(of: rhs.tab)! }
        return lhs.id < rhs.id
    }

    /// 冷却已过、额度周期已过的恢复记录删除；总数超过上限时先删最早恢复的。
    public static func prune(_ records: [String: NotifiedRecord], now: Date) -> [String: NotifiedRecord] {
        var kept = records.filter { _, record in
            guard let recovered = record.recoveredAt else { return true }
            let cooled = now.timeIntervalSince(recovered) >= recoveryCooldown
            return !cooled || (record.cycleResetAt.map { $0 > now } ?? false)
        }
        if kept.count > maxRecords {
            let removable = kept.values.filter { $0.recoveredAt != nil }
                .sorted { ($0.recoveredAt!, $0.key) < ($1.recoveredAt!, $1.key) }
            for record in removable.prefix(kept.count - maxRecords) { kept.removeValue(forKey: record.key) }
        }
        return kept
    }
}

/// 一条要发出的系统通知。
public struct SystemNotice: Equatable {
    public let key: String
    public let tab: PanelTab
    public let subtitle: String
    public let body: String
    public let sound: Bool
    public let title: String?
    public init(key: String, tab: PanelTab, subtitle: String, body: String, sound: Bool, title: String? = nil) {
        self.title = title
        self.key = key; self.tab = tab; self.subtitle = subtitle; self.body = body; self.sound = sound
    }
}

/// 通知文案（D41：写明对象、当前数值，以及重置时间、预计用完时间或已持续的时长）。
public enum NotificationContent {
    public static let title = "MeowMac"
    /// D41：每个问题一条通知，不合并。系统按标签页分组显示。
    public static func notices(for reminders: [Reminder], now: Date, timeZone: TimeZone = .current,
                               redact: (String) -> String = { $0 }) -> [SystemNotice] {
        reminders.map { notice(for: $0, now: now, timeZone: timeZone, redact: redact) }
    }

    public static func notice(for reminder: Reminder, now: Date, timeZone: TimeZone = .current,
                              redact: (String) -> String = { $0 }) -> SystemNotice {
        let category = NotificationCategory(kind: reminder.kind)
        // 网络黄色提醒不是故障，副标题写“网络提醒”。
        let subtitle = reminder.kind == .network && reminder.level < .severe ? "网络提醒" : category?.displayName ?? reminder.title
        return SystemNotice(key: reminder.id, tab: reminder.tab,
                            subtitle: subtitle,
                            body: body(for: reminder, now: now, timeZone: timeZone, redact: redact),
                            sound: reminder.level == .severe, title: reminder.kind == .custom ? reminder.title : nil)
    }

    static func body(for reminder: Reminder, now: Date, timeZone: TimeZone, redact: (String) -> String) -> String {
        let facts = reminder.facts ?? ReminderFacts()
        func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
        switch reminder.kind {
        case .quotaLow:
            if let balance = facts.balance {
                return (facts.subject ?? reminder.title) + " " + balance + (facts.balanceThreshold.map { "，低于 " + $0 } ?? "")
            }
            var text = (facts.subject ?? reminder.title) + (facts.remainingPercent.map { "剩余 " + percent($0) } ?? "剩余不足")
            if let reset = reminder.resetAt { text += "，" + time(reset, now: now, timeZone: timeZone) + " 重置" }
            return text
        case .quotaPace:
            var text = (facts.subject ?? reminder.title)
            if let seconds = facts.secondsUntilExhaustion, seconds.isFinite, seconds > 0 {
                text += "按当前速度约 " + MetricFormat.duration(seconds) + "后用完"
            } else {
                text += "按当前速度会在重置前用完"
            }
            if let reset = reminder.resetAt { text += "，" + time(reset, now: now, timeZone: timeZone) + " 才重置" }
            return text
        case .disk:
            guard let fraction = facts.diskRemainingFraction else { return "磁盘剩余不足，可在系统页打开清理" }
            let bytes = facts.diskAvailableBytes.map { "（" + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + "）" } ?? ""
            return "磁盘可用 " + percent(fraction * 100) + bytes + "，可在系统页打开清理"
        case .process:
            var text = (facts.subject ?? "某个进程") + (facts.cpuPercent.map { " 占用 CPU " + percent($0) } ?? " CPU 持续偏高")
            if let duration = facts.duration { text += "，已持续 " + MetricFormat.duration(duration) }
            return text
        case .memory:
            var text = facts.pressurePercent.map { "内存压力 " + percent($0) } ?? "内存压力持续偏高"
            if let threshold = facts.pressureThreshold { text += "，超过 " + percent(threshold) }
            if let duration = facts.duration { text += "，已持续 " + MetricFormat.duration(duration) }
            return text
        case .thermal:
            return (facts.thermalState.map { "热状态 \($0)，" } ?? "") + reminder.title
        case .source:
            // 渠道名是英文时与“数据”之间留空格，例如“Claude 数据”。
            let subject = facts.subject.map { $0.last?.isASCII == true ? $0 + " 数据" : $0 + "数据" } ?? "数据源"
            var text = subject + (facts.failures.map { "连续 \($0) 次采集失败" } ?? "采集失败")
            if let cached = facts.cachedAt { text += "，面板显示的是 " + time(cached, now: now, timeZone: timeZone) + " 的缓存" }
            return text
        case .network:
            let hint = facts.hint.flatMap { $0.isEmpty ? nil : $0 }
            return redact(reminder.title + (hint.map { "。" + $0 } ?? ""))
        case .custom:
            return reminder.detail
        case .cooling:
            return reminder.title
        }
    }

    /// 当天写“19:30”，7 天内写“周四 08:00”，更远写“10月12日 08:00”；过去的时间同理。
    public static func time(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = timeZone
        let days = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 99)
        formatter.dateFormat = days == 0 ? "HH:mm" : days < 7 ? "EEE HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
