import Foundation

public enum ReminderKind: String, Codable, CaseIterable {
    case quotaLow, quotaPace, disk, source, process, memory, thermal, network, cooling, custom
    public var allowsSnooze: Bool { [.quotaLow, .quotaPace, .disk, .source, .custom].contains(self) }
}

/// 写具体通知用的数值（D41）。面板不显示这些字段。
public struct ReminderFacts: Codable, Equatable {
    /// 通知正文的主语，例如“Claude 5 小时窗口”、进程名或数据源名。
    public var subject: String?
    public var remainingPercent: Double?
    public var secondsUntilExhaustion: TimeInterval?
    public var cpuPercent: Double?
    public var duration: TimeInterval?
    public var pressurePercent: Double?
    public var pressureThreshold: Double?
    public var diskRemainingFraction: Double?
    public var diskAvailableBytes: Int64?
    public var thermalState: String?
    public var failures: Int?
    public var cachedAt: Date?
    public var hint: String?
    /// 余额提醒：当前余额和阈值，均带币种，例如 “¥8.20”“¥10”。
    public var balance: String?
    public var balanceThreshold: String?
    public init(subject: String? = nil, remainingPercent: Double? = nil, secondsUntilExhaustion: TimeInterval? = nil,
                cpuPercent: Double? = nil, duration: TimeInterval? = nil, pressurePercent: Double? = nil, pressureThreshold: Double? = nil,
                diskRemainingFraction: Double? = nil, diskAvailableBytes: Int64? = nil, thermalState: String? = nil,
                failures: Int? = nil, cachedAt: Date? = nil, hint: String? = nil, balance: String? = nil, balanceThreshold: String? = nil) {
        self.subject = subject; self.remainingPercent = remainingPercent; self.secondsUntilExhaustion = secondsUntilExhaustion
        self.cpuPercent = cpuPercent; self.duration = duration; self.pressurePercent = pressurePercent
        self.pressureThreshold = pressureThreshold
        self.diskRemainingFraction = diskRemainingFraction; self.diskAvailableBytes = diskAvailableBytes
        self.thermalState = thermalState; self.failures = failures; self.cachedAt = cachedAt; self.hint = hint
        self.balance = balance; self.balanceThreshold = balanceThreshold
    }
}

public struct Reminder: Identifiable, Codable, Equatable {
    public let kind: ReminderKind
    public let object: String
    public let tab: PanelTab
    public let level: HealthLevel
    public var title: String
    public var detail: String
    public var sampledAt: Date?
    public var resetAt: Date?
    public var confirmed: Bool
    public let provider: QuotaProvider?
    public var facts: ReminderFacts?
    public var id: String { kind.rawValue + "." + object }
    public var isCycleReminder: Bool {
        kind == .quotaPace || (kind == .quotaLow && !object.hasSuffix(".balance")) || (kind == .custom && tab == .quota)
    }
    public var canSnooze: Bool { kind.allowsSnooze && level == .warn && SnoozeRecord.validKey(id, kind: kind) }
    public init(kind: ReminderKind, object: String, tab: PanelTab, level: HealthLevel = .warn,
                title: String, detail: String = "", sampledAt: Date? = nil, resetAt: Date? = nil,
                confirmed: Bool = true, provider: QuotaProvider? = nil, facts: ReminderFacts? = nil) {
        self.kind = kind; self.object = object; self.tab = tab; self.level = level
        self.title = title; self.detail = detail; self.sampledAt = sampledAt; self.resetAt = resetAt
        self.confirmed = confirmed; self.provider = provider; self.facts = facts
    }
}

public struct NetworkReminderSignal {
    public let key: String, message: String
    public let level: HealthLevel
    public let hint: String?
    public init(key: String, message: String, level: HealthLevel, hint: String? = nil) {
        self.key = key; self.message = message; self.level = level; self.hint = hint
    }
}

public struct ReminderBatch {
    public var reminders: [Reminder]
    public var confirmedKinds: Set<ReminderKind>
    public var confirmedKeys: Set<String>
    public var disabledQuotaRules: Set<String> = []
    public var disabledRuleIDs: Set<String> = []
    public var disabledQuotaProviders: [String: Set<String>] = [:]
    public var activeCustomRuleIDs: Set<String>? = nil
    public var customRuleScopes: [String: AlertScope] = [:]
    public var resetRuleIDs: Set<String> = []
    public func forgets(_ key: String) -> Bool {
        guard let id = ruleID(forKey: key) else { return false }
        if let providers = disabledQuotaProviders[id], let provider = key.split(separator: ".").dropFirst().first,
           providers.contains(String(provider)) { return true }
        if let scope = customRuleScopes[id], !scope.contains(object: String(key.dropFirst("custom.".count + id.count + 1))) { return true }
        return disabledRuleIDs.contains(id) || resetRuleIDs.contains(id)
            || (id.hasPrefix("u-") && activeCustomRuleIDs.map { !$0.contains(id) } == true)
    }
    public init(reminders: [Reminder], confirmedKinds: Set<ReminderKind> = [], confirmedKeys: Set<String> = []) {
        self.reminders = reminders; self.confirmedKinds = confirmedKinds; self.confirmedKeys = confirmedKeys
    }
    public func confirms(_ key: String, kind: ReminderKind) -> Bool {
        forgets(key) || confirmedKinds.contains(kind) || confirmedKeys.contains(key)
            || (kind == .quotaLow && disabledQuotaRules.contains(key.hasSuffix(".balance") ? "quota.balance" : "quota.low"))
    }
}

public enum ReminderCollector {
    /// 统一检测入口。确认“恢复”必须有该来源的有效数据。
    public static func collect(_ input: HealthInputs, config originalConfig: LocalConfig) -> ReminderBatch {
        let rules = originalConfig.alertRules
        let config = rules.detectorConfig(originalConfig)
        var batch = ReminderBatch(reminders: [])
        func add(_ reminder: Reminder) { batch.reminders.append(reminder) }
        let networkValid = input.networkConfirmed && input.network != .gray
        if networkValid { batch.confirmedKinds.insert(.network) }
        if let signals = input.networkSignals, !signals.isEmpty {
            for signal in signals where signal.level > .normal {
                add(Reminder(kind: .network, object: signal.key, tab: .network, level: signal.level,
                             title: signal.message, sampledAt: input.networkCheckedAt, confirmed: networkValid,
                             facts: ReminderFacts(hint: signal.hint)))
            }
        } else if input.network == .red || input.network == .yellow {
            add(Reminder(kind: .network, object: "overall", tab: .network,
                         level: input.network == .red ? .severe : .warn,
                         title: input.network == .red ? "网络检测失败" : "网络状态待确认",
                         sampledAt: input.networkCheckedAt, confirmed: networkValid))
        }

        for snapshot in input.quotaSnapshots.sorted(by: { $0.provider.rawValue < $1.provider.rawValue }) {
            let sourceValid = input.failedSources["quota", default: 0] == 0
                && input.failedSources["quota.\(snapshot.provider.rawValue)", default: 0] == 0
                && snapshot.updatedAt <= input.now
            // 余额型渠道（D13 2026-10-05 补充）：低于阈值按额度不足提醒，没有重置周期。
            if let balance = snapshot.balance, let value = balance.value, value.isFinite {
                let threshold = input.balanceWarn[snapshot.provider.rawValue] ?? QuotaSourceList.defaultBalanceWarn
                let object = snapshot.provider.rawValue + ".balance"
                if sourceValid { batch.confirmedKeys.insert(ReminderKind.quotaLow.rawValue + "." + object) }
                if threshold > 0 && value < threshold {
                    let limit = balance.format(threshold)
                    add(Reminder(kind: .quotaLow, object: object, tab: .quota, title: snapshot.provider.displayName + " 余额不足",
                                 detail: "余额 \(balance.amount)，低于 \(limit)", sampledAt: snapshot.updatedAt,
                                 resetAt: nil, confirmed: sourceValid, provider: snapshot.provider,
                                 facts: ReminderFacts(subject: snapshot.provider.displayName + " 余额", balance: balance.amount, balanceThreshold: limit)))
                }
            }
            for window in snapshot.windows where window.usedPercent.isFinite {
                let object = snapshot.provider.rawValue + "." + window.identifier
                // 到期缓存不建立新周期，也不作为恢复证据。
                let valid = sourceValid && (window.resetsAt.map { $0 > input.now } ?? true)
                let prefix = snapshot.provider.displayName + " " + window.displayName.replacingOccurrences(of: "窗口", with: "")
                let reset = valid ? window.resetsAt : nil
                let subject = snapshot.provider.displayName + " " + window.displayName
                if valid { batch.confirmedKeys.insert(ReminderKind.quotaLow.rawValue + "." + object) }
                if window.remainingPercent < rules.quotaRemainingThreshold(snapshot.provider, config: originalConfig) {
                    add(Reminder(kind: .quotaLow, object: object, tab: .quota, title: prefix + "额度剩余不足",
                                 detail: "剩余 \(Int(window.remainingPercent.rounded()))%", sampledAt: snapshot.updatedAt,
                                 resetAt: reset, confirmed: valid, provider: snapshot.provider,
                                 facts: ReminderFacts(subject: subject, remainingPercent: window.remainingPercent)))
                }
                if let pace = QuotaPace.calculate(window: window, now: input.now) {
                    if valid { batch.confirmedKeys.insert(ReminderKind.quotaPace.rawValue + "." + object) }
                    if pace.exhaustsBeforeReset {
                        add(Reminder(kind: .quotaPace, object: object, tab: .quota, title: prefix + "额度偏快",
                                     detail: "预计在重置前用完", sampledAt: snapshot.updatedAt,
                                     resetAt: reset, confirmed: valid, provider: snapshot.provider,
                                     facts: ReminderFacts(subject: subject, remainingPercent: window.remainingPercent,
                                                          secondsUntilExhaustion: pace.secondsUntilExhaustion)))
                    }
                }
            }
        }
        // 兼容只传百分比的旧纯逻辑调用；实际应用传入带身份的快照。
        if input.quotaSnapshots.isEmpty && input.quotaUsedPercent.contains(where: { $0.isFinite && 1 - $0 / 100 < config.quotaRemainingWarn }) {
            add(Reminder(kind: .quotaLow, object: "legacy", tab: .quota, title: "额度剩余不足"))
        }
        if let system = input.system {
            if let remaining = system.diskRemainingFraction, remaining.isFinite, (0...1).contains(remaining) {
                batch.confirmedKinds.insert(.disk)
                if remaining < config.diskRemainingWarn {
                    add(Reminder(kind: .disk, object: "system", tab: .system, title: "磁盘剩余不足",
                                 detail: "可用空间占 \(Int((remaining * 100).rounded()))%", sampledAt: system.timestamp,
                                 facts: ReminderFacts(diskRemainingFraction: remaining, diskAvailableBytes: system.diskAvailableBytes)))
                }
            }
            var thermalCooling = false
            if system.thermal != .unavailable {
                batch.confirmedKinds.insert(.thermal)
                batch.confirmedKeys.insert(ReminderKind.cooling.rawValue + ".system")
                if system.thermal == .serious || system.thermal == .critical {
                    let noProcess = input.energy?.runaway.isEmpty ?? true
                    add(Reminder(kind: .thermal, object: "system", tab: .system,
                                 title: noProcess ? "温度偏高，未发现异常进程，建议降温或用 AI 诊断" : "系统已降频，建议用 AI 诊断",
                                 detail: "热状态 \(system.thermal.rawValue)", sampledAt: system.timestamp,
                                 facts: ReminderFacts(thermalState: system.thermal.rawValue)))
                }
                thermalCooling = system.thermal == .fair && input.fairSince.map({ input.now.timeIntervalSince($0) >= config.fairThermalSeconds }) == true
            }
            if thermalCooling {
                add(Reminder(kind: .cooling, object: "system", tab: .system, level: .normal,
                             title: "建议降温", detail: "热状态 fair 持续偏高", sampledAt: system.timestamp))
            }
            // v0.3：风扇超过最大转速的阈值并持续，同样算“建议降温”（D14）。按来源分别确认：
            // 读不到风扇时不判定，也不当作恢复；与热状态同时满足时只保留热状态那一条。
            let fanHigh = system.sensors?.fanHigh(threshold: config.fanHighFraction)
            if fanHigh != nil || system.sensors?.fans == [] { batch.confirmedKeys.insert(ReminderKind.cooling.rawValue + ".fan") }
            let fanCooling = fanHigh == true && input.fanHighSince.map({ input.now.timeIntervalSince($0) >= config.fanHighSeconds }) == true
            if fanCooling && !thermalCooling {
                add(Reminder(kind: .cooling, object: "fan", tab: .system, level: .normal, title: "建议降温",
                             detail: "风扇转速持续超过最大值的 \(Int((config.fanHighFraction * 100).rounded()))%", sampledAt: system.timestamp))
            }
        }
        if let energy = input.energy {
            let valid = input.failedSources["energy", default: 0] == 0
            if valid { batch.confirmedKinds.insert(.process) }
            for process in energy.runaway {
                add(Reminder(kind: .process, object: String(process.pid), tab: .system,
                             title: process.name + " · 进程 CPU 持续偏高",
                             detail: String(format: "CPU %.0f%% · 已持续 ", process.cpuPercent)
                                + MetricFormat.duration(energy.runawayDurations[process.pid] ?? config.runawaySeconds),
                             sampledAt: input.energyUpdatedAt, confirmed: valid,
                             facts: ReminderFacts(subject: process.name, cpuPercent: process.cpuPercent,
                                                  duration: energy.runawayDurations[process.pid] ?? config.runawaySeconds)))
            }

        }
        for evaluation in input.ruleEvaluations where evaluation.rule.id == BuiltinAlertRule.memory.id {
            batch.confirmedKinds.insert(.memory)
            if evaluation.triggered {
                let pressure = evaluation.reading.value, threshold = evaluation.rule.threshold
                add(Reminder(kind: .memory, object: "system", tab: .system, title: "内存压力持续偏高",
                    detail: "压力 \(Int(pressure.rounded()))%，超过 \(Int(threshold.rounded()))% · 已持续 " + MetricFormat.duration(evaluation.duration),
                    sampledAt: evaluation.reading.sampledAt,
                    facts: ReminderFacts(duration: evaluation.duration, pressurePercent: pressure, pressureThreshold: threshold)))
            }
        }
        for (source, failures) in input.failedSources.sorted(by: { $0.key < $1.key }) {
            let object = sourceObject(source)
            let key = ReminderKind.source.rawValue + "." + object
            if failures == 0 { batch.confirmedKeys.insert(key) }
            if failures >= config.sourceFailureCount {
                let provider = source == "quota.codex-resets" ? .codex : source.hasPrefix("quota.") ? QuotaProvider(rawValue: String(source.dropFirst(6))) : nil
                let names = ["energy": "能耗", "system": "系统", "quota": "额度", "network": "网络", "quota.codex-resets": "Codex 重置监控"]
                let name = names[source] ?? provider?.displayName ?? source
                // 只有单个渠道能确定缓存时间；聚合来源不写，避免误导。
                let cachedAt = source.hasPrefix("quota.") ? input.quotaSnapshots.first { $0.provider == provider }?.updatedAt : nil
                add(Reminder(kind: .source, object: object,
                             tab: source.hasPrefix("network") ? .network : source.hasPrefix("quota") ? .quota : .system,
                             title: "数据源失效：" + name,
                             detail: "连续 \(failures) 次采集失败", provider: provider,
                             facts: ReminderFacts(subject: name, failures: failures, cachedAt: cachedAt)))
            }
        }
        for evaluation in input.ruleEvaluations where evaluation.rule.id.hasPrefix("u-") {
            let rule = evaluation.rule, reading = evaluation.reading
            guard let metric = AlertMetric(rawValue: rule.metric) else { continue }
            let object = rule.id + "." + reading.object
            batch.confirmedKeys.insert("custom." + object)
            if evaluation.triggered {
                let detail = customRuleDetail(rule: rule, reading: reading, duration: evaluation.duration)
                add(Reminder(kind: .custom, object: object, tab: metric.tab, level: rule.level.health,
                    title: rule.name, detail: detail, sampledAt: reading.sampledAt, resetAt: reading.resetAt,
                    provider: reading.provider))
            }
        }
        for rule in [BuiltinAlertRule.quotaLow, .pace, .balance] {
            batch.disabledQuotaProviders[rule.id] = Set(rules.quotaProviders.compactMap { provider, value in value.enabled(rule) == false ? provider : nil })
        }
        batch.reminders = batch.reminders.filter { !batch.forgets($0.id) }
        batch.activeCustomRuleIDs = Set(rules.custom.filter(\.enabled).map(\.id))
        batch.customRuleScopes = Dictionary(rules.custom.compactMap { rule in rule.scope.map { (rule.id, $0) } }, uniquingKeysWith: { first, _ in first })
        batch.disabledRuleIDs = Set(BuiltinAlertRule.allCases.filter { !rules.enabled($0, config: originalConfig) }.map(\.id))
        let kindRules: [ReminderKind: BuiltinAlertRule] = [.network: .network, .disk: .disk, .process: .process,
            .memory: .memory, .thermal: .thermal, .cooling: .cooling, .source: .source, .quotaPace: .pace]
        for (kind, rule) in kindRules where !rules.enabled(rule, config: originalConfig) {
            batch.reminders.removeAll { $0.kind == kind }
            batch.confirmedKinds.insert(kind)
        }
        for reminder in batch.reminders where reminder.kind == .quotaLow {
            let rule: BuiltinAlertRule = reminder.object.hasSuffix(".balance") ? .balance : .quotaLow
            if !rules.enabled(rule, config: originalConfig) { batch.confirmedKeys.insert(reminder.id) }
        }
        batch.reminders.removeAll { $0.kind == .quotaLow && !rules.enabled($0.object.hasSuffix(".balance") ? .balance : .quotaLow, config: originalConfig) }
        // 没有额度数据时也明确确认被停用的窗口或余额规则。
        batch.disabledQuotaRules = Set([BuiltinAlertRule.quotaLow, .balance].filter { !rules.enabled($0, config: originalConfig) }.map(\.id))
        return batch
    }
    private static func sourceObject(_ source: String) -> String {
        let known = ["CPU": "cpu", "内存压力": "memory", "磁盘": "disk", "电池": "battery"]
        if let value = known[source] { return value }
        let permitted = ["energy", "system", "quota", "network", "quota.codex-resets"] + QuotaProvider.defaults.map { "quota." + $0.rawValue }
        if source.hasPrefix("quota."), QuotaProvider(rawValue: String(source.dropFirst(6))) != nil { return source }
        return permitted.contains(source) ? source : "other"
    }
}

public enum SnoozeError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public struct SnoozeRecord: Codable, Equatable {
    public let key: String
    public let kind: ReminderKind
    public let acknowledgedAt: Date
    public let until: Date
    public let cycleResetAt: Date?
    public init(reminder: Reminder, acknowledgedAt: Date, until: Date) throws {
        guard reminder.canSnooze else { throw SnoozeError.invalid("这类问题需要持续提醒") }
        self.key = reminder.id; self.kind = reminder.kind; self.acknowledgedAt = acknowledgedAt
        self.until = until; self.cycleResetAt = reminder.isCycleReminder ? reminder.resetAt : nil
        try validate()
    }
    public static func validKey(_ key: String, kind: ReminderKind) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return kind.allowsSnooze && key.hasPrefix(kind.rawValue + ".") && key.count > kind.rawValue.count + 1 && key.utf8.count <= 160
            && key.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
    public func validate() throws {
        let duration = until.timeIntervalSince(acknowledgedAt)
        guard Self.validKey(key, kind: kind), acknowledgedAt.timeIntervalSince1970.isFinite,
              until.timeIntervalSince1970.isFinite, duration >= 60,
              cycleResetAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              cycleResetAt == nil || [.quotaLow, .quotaPace, .custom].contains(kind),
              duration <= 30 * 86400 || ([.quotaLow, .quotaPace, .custom].contains(kind) && cycleResetAt == until) else {
            throw SnoozeError.invalid("暂缓记录的类型、身份或时间无效")
        }
    }
}

public struct ReminderTracker {
    public private(set) var current: [String: Reminder] = [:]
    public var snoozes: [String: SnoozeRecord] = [:]
    public init() {}
    public var records: [SnoozeRecord] { snoozes.values.sorted { $0.key < $1.key } }
    public mutating func removeProviders(_ providers: [QuotaProvider]) {
        let removed = Set(providers)
        let keys = Set(current.values.filter { $0.provider.map(removed.contains) == true }.map(\.id))
        current = current.filter { !keys.contains($0.key) }
        snoozes = snoozes.filter { key, _ in
            !keys.contains(key) && !providers.contains { provider in
                (key.hasPrefix("custom.") && key.contains("." + provider.rawValue + ".")) || key.hasPrefix("quotaLow." + provider.rawValue + ".") || key.hasPrefix("quotaPace." + provider.rawValue + ".") || key == "source.quota." + provider.rawValue
            }
        }
    }

    public mutating func reconcile(_ batch: ReminderBatch, now: Date) {
        current = current.filter { !batch.forgets($0.key) }
        snoozes = snoozes.filter { !batch.forgets($0.key) }
        let incoming = Dictionary(batch.reminders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, old) in current where incoming[key] == nil {
            if batch.confirms(key, kind: old.kind) { current.removeValue(forKey: key); snoozes.removeValue(forKey: key) }
            else { var unknown = old; unknown.confirmed = false; current[key] = unknown }
        }
        for (key, fresh) in incoming {
            var value = fresh
            if !fresh.confirmed, let old = current[key] {
                // 不完整检测不能用较轻的局部结果覆盖已确认的严重问题。
                if fresh.level < old.level { value = old; value.confirmed = false }
                value.resetAt = old.resetAt
            }
            if let saved = snoozes[key], fresh.confirmed, let oldReset = saved.cycleResetAt, let newReset = fresh.resetAt,
               abs(oldReset.timeIntervalSince(newReset)) > QuotaHistorySeries.resetTolerance {
                snoozes.removeValue(forKey: key)
            }
            if fresh.level == .severe || !fresh.kind.allowsSnooze { snoozes.removeValue(forKey: key) }
            current[key] = value
        }
        for (key, saved) in snoozes {
            if saved.until <= now || (incoming[key] == nil && batch.confirms(key, kind: saved.kind)) {
                snoozes.removeValue(forKey: key)
            }
        }
    }
    public func isSnoozed(_ reminder: Reminder, now: Date) -> Bool {
        reminder.canSnooze && snoozes[reminder.id].map { $0.until > now } == true
    }
    public func sorted() -> [Reminder] {
        current.values.sorted {
            if $0.level != $1.level { return $0.level > $1.level }
            let tabs = PanelTab.allCases
            if $0.tab != $1.tab { return tabs.firstIndex(of: $0.tab)! < tabs.firstIndex(of: $1.tab)! }
            return $0.id < $1.id
        }
    }
    public func health(now: Date) -> HealthSummary {
        let all = sorted()
        let issues = all.filter { $0.level > .normal && !isSnoozed($0, now: now) }
            .map { HealthIssue(level: $0.level, tab: $0.tab, message: $0.title) }
        return HealthSummary(level: issues.first?.level ?? .normal, issues: issues, coolingHint: all.contains { $0.kind == .cooling })
    }
}

/// 界面摘要和系统通知共用同一条规则与读数。
public func customRuleDetail(rule: AlertRule, reading: MetricReading, duration: TimeInterval) -> String {
    guard let metric = AlertMetric(rawValue: rule.metric) else { return "指标不可用" }
    let subject = reading.subject.map { $0 + " · " } ?? ""
    return subject + metric.name + " " + alertNumber(reading.value) + metric.unit
        + (rule.comparison == .gte ? "，超过 " : "，低于 ") + alertNumber(rule.threshold) + metric.unit
        + " · 已持续 " + MetricFormat.duration(duration)
}
public func alertNumber(_ value: Double) -> String {
    value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
}
