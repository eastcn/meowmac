import Foundation
import MeowMacCore
import MeowMacUI

enum ReminderTests {
    static let now = Date(timeIntervalSince1970: 1_000_000)
    static func disk() -> Reminder { Reminder(kind: .disk, object: "system", tab: .system, title: "磁盘不足") }
    static var tests: [(String, () throws -> Bool)] { [
        ("Core.Reminders/独立身份与到期", {
            var tracker = ReminderTracker()
            let a = disk(), b = Reminder(kind: .quotaLow, object: "claude.primary", tab: .quota, title: "额度不足")
            let batch = ReminderBatch(reminders: [a, b, a])
            tracker.reconcile(batch, now: now)
            tracker.snoozes[a.id] = try SnoozeRecord(reminder: a, acknowledgedAt: now, until: now.addingTimeInterval(3600))
            tracker.reconcile(batch, now: now.addingTimeInterval(3599))
            guard tracker.current.count == 2, tracker.health(now: now).worst?.tab == .quota else { return false }
            tracker.reconcile(batch, now: now.addingTimeInterval(3600))
            return tracker.snoozes.isEmpty && tracker.health(now: now.addingTimeInterval(3600)).issues.count == 2
        }),
        ("Core.Reminders/未知与恢复后重现", {
            var tracker = ReminderTracker(); let issue = disk()
            tracker.reconcile(ReminderBatch(reminders: [issue]), now: now)
            tracker.snoozes[issue.id] = try SnoozeRecord(reminder: issue, acknowledgedAt: now, until: now.addingTimeInterval(86400))
            tracker.reconcile(ReminderBatch(reminders: []), now: now)
            guard tracker.current.count == 1, tracker.current[issue.id]?.confirmed == false, tracker.snoozes.count == 1 else { return false }
            tracker.reconcile(ReminderBatch(reminders: [], confirmedKinds: [.disk]), now: now)
            tracker.reconcile(ReminderBatch(reminders: [issue]), now: now)
            return tracker.current.count == 1 && tracker.snoozes.isEmpty && tracker.health(now: now).level == .warn
        }),
        ("Core.Reminders/周期抖动与新周期", {
            var tracker = ReminderTracker()
            var issue = Reminder(kind: .quotaLow, object: "claude.primary", tab: .quota, title: "额度不足", resetAt: now.addingTimeInterval(3600))
            tracker.reconcile(ReminderBatch(reminders: [issue]), now: now)
            tracker.snoozes[issue.id] = try SnoozeRecord(reminder: issue, acknowledgedAt: now, until: now.addingTimeInterval(3 * 86400))
            issue.resetAt = now.addingTimeInterval(3610)
            tracker.reconcile(ReminderBatch(reminders: [issue]), now: now)
            guard tracker.snoozes.count == 1 else { return false }
            issue.resetAt = now.addingTimeInterval(18000); issue.confirmed = false
            tracker.reconcile(ReminderBatch(reminders: [issue]), now: now)
            guard tracker.snoozes.count == 1 else { return false }
            issue.confirmed = true
            tracker.reconcile(ReminderBatch(reminders: [issue]), now: now)
            return tracker.snoozes.isEmpty
        }),
        ("Core.Reminders/严重与持续异常不可暂缓", {
            for kind in [ReminderKind.network, .process, .memory, .thermal, .cooling] {
                let issue = Reminder(kind: kind, object: "sample", tab: .system, title: "示例")
                do { _ = try SnoozeRecord(reminder: issue, acknowledgedAt: now, until: now.addingTimeInterval(3600)); return false } catch {}
            }
            let serious = Reminder(kind: .disk, object: "system", tab: .system, level: .severe, title: "严重")
            var tracker = ReminderTracker();let normal = disk()
            tracker.snoozes[normal.id] = try SnoozeRecord(reminder: normal, acknowledgedAt: now, until: now.addingTimeInterval(3600))
            tracker.reconcile(ReminderBatch(reminders: [serious]), now: now)
            return tracker.snoozes.isEmpty && tracker.health(now: now).level == .severe
        }),
        ("Core.Reminders/无效时间拒绝", {
            for seconds in [-1.0, 0, 59, 30 * 86400 + 1, .infinity, .nan] {
                do { _ = try SnoozeRecord(reminder: disk(), acknowledgedAt: now, until: now.addingTimeInterval(seconds)); return false } catch {}
            }
            return try SnoozeRecord(reminder: disk(), acknowledgedAt: now, until: now.addingTimeInterval(2 * 86400)).until == now.addingTimeInterval(2 * 86400)
        })
    ] }
    @MainActor static func storage() throws -> Bool {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance/reminder-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("state"), store = ReminderStore(rootURL: root)
        guard store.load().records.isEmpty, !FileManager.default.fileExists(atPath: root.path) else { return false }
        let record = try SnoozeRecord(reminder: disk(), acknowledgedAt: now, until: now.addingTimeInterval(172800))
        try store.save([record])
        guard ReminderStore(rootURL: root).load().records == [record] else { return false }
        let file = root.appendingPathComponent("reminder-snoozes.json"), bytes = try Data(contentsOf: file)
        let failing = ReminderStore(rootURL: root, beforePublish: { throw SnoozeError.invalid("合成失败") })
        do { try failing.save([]); return false } catch {}
        guard try Data(contentsOf: file) == bytes,
              !(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains(where: { $0.hasPrefix(".reminders-") }) else { return false }
        try Data("broken".utf8).write(to: file)
        guard store.load().records.isEmpty, store.load().recoveryReason != nil else { return false }
        do { try store.save([record]); return false } catch {}
        guard try Data(contentsOf: file) == Data("broken".utf8) else { return false }
        let sentinel = base.appendingPathComponent("sentinel"); try Data("preserve".utf8).write(to: sentinel)
        let linkedRoot = base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        do { try ReminderStore(rootURL: linkedRoot).save([record]); return false } catch {}
        let safe = base.appendingPathComponent("safe"); try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: safe.appendingPathComponent("reminder-snoozes.json"), withDestinationURL: sentinel)
        do { try ReminderStore(rootURL: safe).save([record]); return false } catch {}
        return try Data(contentsOf: sentinel) == Data("preserve".utf8)
    }
}
