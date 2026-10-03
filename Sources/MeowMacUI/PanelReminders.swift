import Foundation
import MeowMacCore
import TunCanaryCore
import os

@MainActor
public extension PanelState {
    var reminderBatch: ReminderBatch {
        let signals = networkModel?.overall.faults.map {
            NetworkReminderSignal(key: $0.key.rawValue, message: $0.message,
                                  level: $0.severity == .critical ? .severe : .warn)
        }
        let completed = networkModel.map { $0.checkProgress == nil && $0.lastCheckedAt != nil && !$0.overall.isSwitching } ?? true
        return ReminderCollector.collect(HealthInputs(system: snapshot, energy: energy,
            quotaUsedPercent: quotas.values.flatMap { $0.windows.map(\.usedPercent) }, network: networkTone,
            failedSources: failures, fairSince: fairSince, now: now(), quotaSnapshots: Array(quotas.values),
            networkSignals: signals, networkConfirmed: completed, networkCheckedAt: networkModel?.lastCheckedAt,
            energyUpdatedAt: energyUpdatedAt), config: configResult.config)
    }
    var projectedReminders: ReminderTracker {
        var value = reminderTracker; value.reconcile(reminderBatch, now: now()); return value
    }
    var allReminders: [Reminder] { projectedReminders.sorted() }
    var snoozedReminders: [Reminder] { allReminders.filter { projectedReminders.isSnoozed($0, now: now()) } }
    var pendingReminders: [Reminder] { allReminders.filter { $0.level > .normal && !projectedReminders.isSnoozed($0, now: now()) } }
    func reminderDataTime(_ reminder: Reminder) -> String {
        guard reminder.confirmed else { return "待确认 · 保留上次问题" }
        guard let date = reminder.sampledAt else { return "待确认 · 没有有效数据时间" }
        return "数据：" + DisplayDate.age(date, now: now())
    }
    func snoozeDeadline(_ reminder: Reminder) -> Date? {
        let tracker = projectedReminders
        return tracker.isSnoozed(reminder, now: now()) ? tracker.snoozes[reminder.id]?.until : nil
    }
    func initializeReminders(store: ReminderStore) {
        reminderStore = store
        let loaded = store.load()
        var value = ReminderTracker()
        value.snoozes = Dictionary(uniqueKeysWithValues: loaded.records.map { ($0.key, $0) })
        // 重启尚未采集时，用安全的类型与对象身份保留“待确认”，不虚报恢复。
        let titles: [ReminderKind: String] = [.quotaLow: "额度剩余不足", .quotaPace: "额度偏快", .disk: "磁盘剩余不足", .source: "数据源失效"]
        let placeholders = loaded.records.map { record -> Reminder in
            let object = String(record.key.dropFirst(record.kind.rawValue.count + 1))
            let providerObject = object.hasPrefix("quota.") ? String(object.dropFirst(6)) : object
            let provider = object == "quota.codex-resets" ? .codex : providerObject.split(separator: ".").first.flatMap { QuotaProvider(rawValue: String($0)) }
            let tab: PanelTab = record.kind == .quotaLow || record.kind == .quotaPace || object.hasPrefix("quota") ? .quota : object == "network" ? .network : .system
            return Reminder(kind: record.kind, object: object, tab: tab,
                            title: (provider.map { $0.displayName + " · " } ?? "") + (titles[record.kind] ?? "待确认问题"),
                            detail: "等待新的检测结果", resetAt: record.cycleResetAt, confirmed: false, provider: provider)
        }
        value.reconcile(ReminderBatch(reminders: placeholders), now: now())
        reminderTracker = value
        reminderError = loaded.recoveryReason.map { "暂缓记录未恢复：" + $0 }
        reminderPersistenceDirty = value.records != loaded.records
        reminderSaveAttempt = nil
        refreshReminders()
    }
    func refreshReminders() {
        let before = reminderTracker.records
        var value = reminderTracker; value.reconcile(reminderBatch, now: now())
        reminderTracker = value
        if let id = activeSnoozeID, value.current[id]?.canSnooze != true || value.current[id].map({ value.isSnoozed($0, now: now()) }) == true {
            activeSnoozeID = nil
        }
        if before != value.records { reminderPersistenceDirty = true }
        guard reminderPersistenceDirty, let store = reminderStore,
              reminderSaveAttempt.map({ now().timeIntervalSince($0) >= 60 }) ?? true else { return }
        reminderSaveAttempt = now()
        do {
            try store.save(value.records)
            reminderPersistenceDirty = false
            if reminderError?.hasPrefix("暂缓记录未同步：") == true { reminderError = nil }
        } catch {
            let message = "暂缓记录未同步：" + error.localizedDescription
            if reminderError != message {
                Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "reminders").error("\(message, privacy: .private)")
                reminderError = message
            }
        }
    }
    func showReminders() { refreshReminders(); reminderFilter = nil; showingReminders = true }
    func showReminderDetail(_ reminder: Reminder) {
        if let provider = reminder.provider { selectedProvider = provider }
        select(reminder.tab); activeSnoozeID = nil; showingReminders = false
    }
    func snooze(_ id: String, seconds: TimeInterval? = nil, untilReset: Bool = false) throws {
        refreshReminders()
        guard let reminder = reminderTracker.current[id], reminder.canSnooze else { throw SnoozeError.invalid("当前提醒已改变，不能暂缓") }
        let end: Date
        if untilReset {
            guard [.quotaLow, .quotaPace].contains(reminder.kind), reminder.confirmed, let reset = reminder.resetAt, reset.timeIntervalSince(now()) >= 60 else { throw SnoozeError.invalid("没有可靠的未来重置时间") }
            end = reset
        } else {
            guard let seconds, seconds.isFinite, seconds >= 60, seconds <= 30 * 86400 else { throw SnoozeError.invalid("时长须为 1 分钟至 30 天") }
            end = now().addingTimeInterval(seconds)
        }
        var value = reminderTracker
        value.snoozes[id] = try SnoozeRecord(reminder: reminder, acknowledgedAt: now(), until: end)
        guard let store = reminderStore else { throw SnoozeError.invalid("提醒存储尚未初始化") }
        try store.save(value.records)
        reminderTracker = value; reminderPersistenceDirty = false; reminderError = nil; activeSnoozeID = nil
    }
    func restoreReminder(_ id: String) throws {
        refreshReminders()
        var value = reminderTracker; value.snoozes.removeValue(forKey: id)
        guard let store = reminderStore else { throw SnoozeError.invalid("提醒存储尚未初始化") }
        try store.save(value.records)
        reminderTracker = value; reminderPersistenceDirty = false; reminderError = nil
    }
}
