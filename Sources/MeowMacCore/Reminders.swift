import Foundation

public enum ReminderKind: String, Codable, CaseIterable {
    case quotaLow, quotaPace, disk, source, process, memory, thermal, network, cooling
    public var allowsSnooze: Bool { [.quotaLow, .quotaPace, .disk, .source].contains(self) }
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
    public var id: String { kind.rawValue + "." + object }
    public var canSnooze: Bool { kind.allowsSnooze && level == .warn && SnoozeRecord.validKey(id, kind: kind) }
    public init(kind: ReminderKind, object: String, tab: PanelTab, level: HealthLevel = .warn,
                title: String, detail: String = "", sampledAt: Date? = nil, resetAt: Date? = nil,
                confirmed: Bool = true, provider: QuotaProvider? = nil) {
        self.kind = kind; self.object = object; self.tab = tab; self.level = level
        self.title = title; self.detail = detail; self.sampledAt = sampledAt; self.resetAt = resetAt
        self.confirmed = confirmed; self.provider = provider
    }
}

public struct NetworkReminderSignal {
    public let key: String, message: String
    public let level: HealthLevel
    public init(key: String, message: String, level: HealthLevel) {
        self.key = key; self.message = message; self.level = level
    }
}

public struct ReminderBatch {
    public var reminders: [Reminder]
    public var confirmedKinds: Set<ReminderKind>
    public var confirmedKeys: Set<String>
    public init(reminders: [Reminder], confirmedKinds: Set<ReminderKind> = [], confirmedKeys: Set<String> = []) {
        self.reminders = reminders; self.confirmedKinds = confirmedKinds; self.confirmedKeys = confirmedKeys
    }
    public func confirms(_ key: String, kind: ReminderKind) -> Bool {
        confirmedKinds.contains(kind) || confirmedKeys.contains(key)
    }
}

public enum ReminderCollector {
    /// 统一检测入口。确认“恢复”必须有该来源的有效数据。
    public static func collect(_ input: HealthInputs, config: LocalConfig) -> ReminderBatch {
        var batch = ReminderBatch(reminders: [])
        func add(_ reminder: Reminder) { batch.reminders.append(reminder) }
        let networkValid = input.networkConfirmed && input.network != .gray
        if networkValid { batch.confirmedKinds.insert(.network) }
        if let signals = input.networkSignals, !signals.isEmpty {
            for signal in signals where signal.level > .normal {
                add(Reminder(kind: .network, object: signal.key, tab: .network, level: signal.level,
                             title: signal.message, sampledAt: input.networkCheckedAt, confirmed: networkValid))
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
            for window in snapshot.windows where window.usedPercent.isFinite {
                let object = snapshot.provider.rawValue + "." + window.identifier
                // 到期缓存不建立新周期，也不作为恢复证据。
                let valid = sourceValid && (window.resetsAt.map { $0 > input.now } ?? true)
                let prefix = snapshot.provider.displayName + " " + window.displayName.replacingOccurrences(of: "窗口", with: "")
                let reset = valid ? window.resetsAt : nil
                if valid { batch.confirmedKeys.insert(ReminderKind.quotaLow.rawValue + "." + object) }
                if window.remainingPercent / 100 < config.quotaRemainingWarn {
                    add(Reminder(kind: .quotaLow, object: object, tab: .quota, title: prefix + "额度剩余不足",
                                 detail: "剩余 \(Int(window.remainingPercent.rounded()))%", sampledAt: snapshot.updatedAt,
                                 resetAt: reset, confirmed: valid, provider: snapshot.provider))
                }
                if let pace = QuotaPace.calculate(window: window, now: input.now) {
                    if valid { batch.confirmedKeys.insert(ReminderKind.quotaPace.rawValue + "." + object) }
                    if pace.exhaustsBeforeReset {
                        add(Reminder(kind: .quotaPace, object: object, tab: .quota, title: prefix + "额度偏快",
                                     detail: "预计在重置前用完", sampledAt: snapshot.updatedAt,
                                     resetAt: reset, confirmed: valid, provider: snapshot.provider))
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
                                 detail: "可用空间占 \(Int((remaining * 100).rounded()))%", sampledAt: system.timestamp))
                }
            }
            if system.thermal != .unavailable {
                batch.confirmedKinds.formUnion([.thermal, .cooling])
                if system.thermal == .serious || system.thermal == .critical {
                    let noProcess = input.energy?.runaway.isEmpty ?? true
                    add(Reminder(kind: .thermal, object: "system", tab: .system,
                                 title: noProcess ? "温度偏高，未发现异常进程，建议降温或用 AI 诊断" : "系统已降频，建议用 AI 诊断",
                                 detail: "热状态 \(system.thermal.rawValue)", sampledAt: system.timestamp))
                }
                if system.thermal == .fair && input.fairSince.map({ input.now.timeIntervalSince($0) >= config.fairThermalSeconds }) == true {
                    add(Reminder(kind: .cooling, object: "system", tab: .system, level: .normal,
                                 title: "建议降温", detail: "热状态 fair 持续偏高", sampledAt: system.timestamp))
                }
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
                             sampledAt: input.energyUpdatedAt, confirmed: valid))
            }
            let memoryValid = valid && input.system?.memoryPressure != .unavailable && input.system != nil
            if memoryValid { batch.confirmedKinds.insert(.memory) }
            if energy.prolongedMemoryPressure {
                add(Reminder(kind: .memory, object: "system", tab: .system, title: "内存压力持续偏高",
                             detail: "已持续 " + MetricFormat.duration(energy.memoryPressureDuration ?? config.memoryPressureSeconds),
                             sampledAt: input.energyUpdatedAt, confirmed: memoryValid))
            }
        }
        for (source, failures) in input.failedSources.sorted(by: { $0.key < $1.key }) {
            let object = sourceObject(source)
            let key = ReminderKind.source.rawValue + "." + object
            if failures == 0 { batch.confirmedKeys.insert(key) }
            if failures >= config.sourceFailureCount {
                let provider = source == "quota.codex-resets" ? .codex : source.hasPrefix("quota.") ? QuotaProvider(rawValue: String(source.dropFirst(6))) : nil
                let names = ["energy": "能耗", "system": "系统", "quota": "额度", "network": "网络", "quota.codex-resets": "Codex 重置监控"]
                add(Reminder(kind: .source, object: object,
                             tab: source.hasPrefix("network") ? .network : source.hasPrefix("quota") ? .quota : .system,
                             title: "数据源失效：" + (names[source] ?? provider?.displayName ?? source),
                             detail: "连续 \(failures) 次采集失败", provider: provider))
            }
        }
        return batch
    }
    private static func sourceObject(_ source: String) -> String {
        let known = ["CPU": "cpu", "内存压力": "memory", "磁盘": "disk", "电池": "battery"]
        if let value = known[source] { return value }
        let permitted = ["energy", "system", "quota", "network", "quota.codex-resets"] + QuotaProvider.allCases.map { "quota." + $0.rawValue }
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
        self.until = until; self.cycleResetAt = [.quotaLow, .quotaPace].contains(reminder.kind) ? reminder.resetAt : nil
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
              cycleResetAt == nil || [.quotaLow, .quotaPace].contains(kind),
              duration <= 30 * 86400 || ([.quotaLow, .quotaPace].contains(kind) && cycleResetAt == until) else {
            throw SnoozeError.invalid("暂缓记录的类型、身份或时间无效")
        }
    }
}

public struct ReminderTracker {
    public private(set) var current: [String: Reminder] = [:]
    public var snoozes: [String: SnoozeRecord] = [:]
    public init() {}
    public var records: [SnoozeRecord] { snoozes.values.sorted { $0.key < $1.key } }
    public mutating func reconcile(_ batch: ReminderBatch, now: Date) {
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
