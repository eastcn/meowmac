import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum NotificationTransactionTests {
    static let now = NotificationUITests.now
    static func fixture(_ suffix: String) throws -> (NotificationStore, NotificationCoordinator) {
        let root = URL(fileURLWithPath: "build/acceptance/self-performance/transaction-tests/" + UUID().uuidString + suffix)
        let store = NotificationStore(rootURL: root)
        return (store, NotificationCoordinator(store: store, startedAt: now.addingTimeInterval(-3600), send: { _ in }))
    }
    static func process(_ coordinator: NotificationCoordinator, at offset: Double) {
        coordinator.process(NotificationUITests.tracker([NotificationTests.disk()]), batch: nil, now: now.addingTimeInterval(offset))
    }
    static func semanticTrace() -> Bool {
        do {
            let (store, first) = try fixture("trace")
            let (referenceStore, baseline) = try fixture("trace-reference")
            var actualSent: [SystemNotice] = [], expectedSent: [SystemNotice] = []
            var actual = NotificationCoordinator(store: store, startedAt: now.addingTimeInterval(-3600)) { actualSent.append($0) }
            var reference = NotificationCoordinator(store: referenceStore, startedAt: now.addingTimeInterval(-3600)) { expectedSent.append($0) }
            _ = first; _ = baseline
            let disk = NotificationTests.disk(), warn = NotificationTests.network(level: .warn), severe = NotificationTests.network(level: .severe)
            let rounds: [(Double, [Reminder], Bool, Bool)] = [
                (0, [disk, warn], true, false), (1, [disk, warn], true, false),
                (2, [disk, severe], true, false), (3, [], false, false),
                (4, [], true, false), (500, [disk, warn], true, false),
                (700, [disk, severe], true, false), (800, [disk], true, true),
                (900, [disk], true, true), (4500, [disk], true, false),
                (4501, [disk], true, false), (4501 + 86399, [], false, false),
                (4501 + 86401, [], false, false), (4501 + 86402, [disk], true, false)
            ]
            for (index, round) in rounds.enumerated() {
                let (offset, reminders, confirmed, snoozed) = round
                let at = now.addingTimeInterval(offset)
                var tracker = ReminderTracker()
                tracker.reconcile(ReminderBatch(reminders: reminders), now: at)
                if snoozed { tracker.snoozes[disk.id] = try SnoozeRecord(reminder: disk, acknowledgedAt: at, until: at.addingTimeInterval(3600)) }
                let batch = ReminderBatch(reminders: reminders, confirmedKinds: confirmed ? [.disk, .network] : [])
                actual.withTransaction { actual.process(tracker, batch: batch, now: at); actual.process(tracker, batch: batch, now: at) }
                reference.process(tracker, batch: batch, now: at); reference.process(tracker, batch: batch, now: at)
                guard actual.records == reference.records, store.load().records == referenceStore.load().records,
                      actualSent == expectedSent else { return false }
                if index == 1 || index == 5 {
                    actual = NotificationCoordinator(store: store, startedAt: at) { actualSent.append($0) }
                    reference = NotificationCoordinator(store: referenceStore, startedAt: at) { expectedSent.append($0) }
                }
            }
            return true
        } catch { return false }
    }
    static var tests: [(String, @MainActor () async -> Bool)] { [
        ("UI.NotificationTransaction/重启冷却升级恢复静默暂缓与24小时等价", { semanticTrace() }),
        ("UI.NotificationTransaction/完整记录、即时语义与嵌套合并", {
            do {
                let (store, coordinator) = try fixture("merged")
                let (referenceStore, reference) = try fixture("reference")
                var saves = 0; store.observeSave = { saves += 1 }
                process(coordinator, at: 0); process(reference, at: 0)
                let initialSaves = saves
                coordinator.withTransaction {
                    process(coordinator, at: 1); process(reference, at: 1)
                    coordinator.withTransaction { process(coordinator, at: 2); process(reference, at: 2) }
                    process(coordinator, at: 3); process(reference, at: 3)
                    // 内存每次更新，事务内尚未写入纯时间变更。
                }
                guard saves - initialSaves == 1, coordinator.records == reference.records,
                      store.load().records == referenceStore.load().records,
                      coordinator.records["disk.system"]?.lastSeenAt == now.addingTimeInterval(3) else { return false }
                let before = saves
                var immediate = false
                coordinator.withTransaction {
                    coordinator.process(ReminderTracker(), batch: nil, now: now.addingTimeInterval(4))
                    immediate = saves == before + 1 && store.load().records == coordinator.records
                }
                guard immediate, saves == before + 1, store.load().records == coordinator.records else { return false }
                coordinator.withTransaction { }
                return saves == before + 1
            } catch { return false }
        }),
        ("UI.NotificationTransaction/异常退出flush和失败后无变化重试", {
            enum Probe: Error { case exit }
            do {
                let (store, coordinator) = try fixture("retry")
                process(coordinator, at: 0)
                do { try coordinator.withTransaction { process(coordinator, at: 5); throw Probe.exit } } catch Probe.exit { }
                guard store.load().records == coordinator.records else { return false }
                // 把目录原样移开，原位置用普通文件阻止真实原子写入。
                let aside = store.rootURL.appendingPathExtension("saved")
                try FileManager.default.moveItem(at: store.rootURL, to: aside)
                try Data("blocked".utf8).write(to: store.rootURL)
                process(coordinator, at: 6)
                try FileManager.default.removeItem(at: store.rootURL)
                try FileManager.default.moveItem(at: aside, to: store.rootURL)
                guard store.load().records != coordinator.records else { return false }
                process(coordinator, at: 6)
                return store.load().records == coordinator.records
            } catch { return false }
        }),
        ("UI.NotificationTransaction/首次保存、设置及渠道移除即时保存", {
            do {
                let (store, coordinator) = try fixture("settings")
                var immediate = false
                coordinator.withTransaction {
                    process(coordinator, at: 0)
                    immediate = store.load().records == coordinator.records
                    process(coordinator, at: 2)
                    var settings = coordinator.settings; settings.enabled = false
                    immediate = immediate && coordinator.update(settings) && store.load().settings == settings && store.load().records == coordinator.records
                    let quota = NotificationTests.quota(resetAt: nil)
                    coordinator.process(NotificationUITests.tracker([quota]), batch: nil, now: now.addingTimeInterval(3))
                    coordinator.removeProviders([.claude])
                    immediate = immediate && store.load().records == coordinator.records && !coordinator.records.keys.contains { $0.contains("claude") }
                }
                return immediate && store.load().records == coordinator.records
            } catch { return false }
        })
    ] }
}
