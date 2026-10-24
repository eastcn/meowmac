import Foundation
import MeowMacCore
import MeowMacUI

/// 近 24 小时电量历史（D4、D10）。假时钟、临时目录、虚构读数。
@MainActor
enum BatteryHistoryTests {
    static let tests: [(String, @MainActor () -> Bool)] = [
        ("Battery.History/5 分钟节奏与供电变化立即补点", cadence),
        ("Battery.History/睡眠缺口不插值且唤醒立即记段起点", sleepGap),
        ("Battery.History/跨休眠或重启间隔不超过 330 秒也不连线", shortGapAcrossSegments),
        ("Battery.History/重启后接上历史", restart),
        ("Battery.History/24 小时裁剪、坏行、超大文件与未来时刻", storage),
        ("Battery.History/无电池不建目录不写盘", noBattery),
        ("Battery.History/摘要边界", summaryEdges),
    ]

    private static let t0 = ISO8601DateFormatter().date(from: "2030-04-10T12:00:00Z")!

    private static func status(_ state: BatteryPowerState, _ percent: Int, watts: Double? = 8) -> BatteryStatus {
        BatteryStatus(state: state, percent: percent, powerWatts: watts)
    }

    private static func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("meowmac-battery-\(UUID().uuidString)", isDirectory: true)
    }

    private static func check(_ name: String, _ ok: Bool) -> Bool {
        if !ok { print("电量历史用例不符：\(name)") }
        return ok
    }

    private static func rows(_ values: [(TimeInterval, Int, BatteryPowerState, Bool)], watts: Double? = 8) -> BatteryHistory {
        BatteryHistory(records: values.map { offset, percent, state, start in
            BatteryHistoryRecord(sampledAt: t0.addingTimeInterval(offset), percent: percent, state: state,
                                 dischargeWatts: state == .battery ? watts : nil, segmentStart: start)
        })
    }

    static func cadence() -> Bool {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BatteryHistoryStore(directory: directory)
        var published: BatteryHistory?
        let recorder = BatteryHistoryRecorder(store: store, now: t0) { published = $0 }
        // 每 10 秒采样一次，共 16 分钟，一直用电池。
        for step in 0...96 { recorder.record(status(.battery, 80 - step / 10), at: t0.addingTimeInterval(Double(step) * 10)) }
        let times = recorder.history.records.map { $0.sampledAt.timeIntervalSince(t0) }
        guard check("5 分钟一点", times == [0, 300, 600, 900]),
              check("只有首点是段起点", recorder.history.records.map(\.segmentStart) == [true, false, false, false]),
              check("放电功率只在用电池时记录", recorder.history.records.allSatisfy { $0.dischargeWatts == 8 }) else { return false }
        // 接上电源：下一次采样立即补点，不等满 300 秒。
        recorder.record(status(.charging, 71), at: t0.addingTimeInterval(970))
        recorder.record(status(.charging, 71), at: t0.addingTimeInterval(980))
        recorder.record(status(.acNotCharging, 72), at: t0.addingTimeInterval(1000))
        recorder.flush()
        let tail = recorder.history.records.suffix(2)
        let loaded = store.load(now: t0.addingTimeInterval(1000))
        return check("供电变化立即补点", tail.map { $0.sampledAt.timeIntervalSince(t0) } == [970, 1000] && tail.map(\.state) == [.charging, .acNotCharging])
            && check("接电源不记放电功率", tail.allSatisfy { $0.dischargeWatts == nil })
            && check("写盘与内存一致", loaded == recorder.history && published == recorder.history)
    }

    static func sleepGap() -> Bool {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = BatteryHistoryRecorder(store: BatteryHistoryStore(directory: directory), now: t0) { _ in }
        recorder.record(status(.battery, 80), at: t0)
        recorder.record(status(.battery, 79), at: t0.addingTimeInterval(300))
        recorder.sleep()
        // 睡眠期间即使有采样也不记录。
        recorder.record(status(.battery, 78), at: t0.addingTimeInterval(900))
        recorder.wake()
        recorder.record(status(.battery, 70), at: t0.addingTimeInterval(7500))
        recorder.record(status(.battery, 70), at: t0.addingTimeInterval(7510))
        recorder.flush()
        let history = recorder.history, now = t0.addingTimeInterval(7600)
        let segments = history.segments(now: now)
        let summary = history.summary(now: now)
        return check("睡眠期间无点", history.records.map { $0.sampledAt.timeIntervalSince(t0) } == [0, 300, 7500])
            && check("唤醒后首点是段起点", history.records.last?.segmentStart == true)
            && check("缺口两侧分段", segments.map(\.count) == [2, 1])
            && check("摘要不跨缺口", summary.batterySeconds == 300 && summary.drainedPercent == 1)
    }

    static func shortGapAcrossSegments() -> Bool {
        // 唤醒：200 秒后的段起点。
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BatteryHistoryStore(directory: directory)
        let recorder = BatteryHistoryRecorder(store: store, now: t0) { _ in }
        recorder.record(status(.battery, 80), at: t0)
        recorder.sleep(); recorder.wake()
        recorder.record(status(.battery, 79), at: t0.addingTimeInterval(200))
        recorder.flush()
        let wakeHistory = recorder.history
        // 重启：新记录器读入旧历史，100 秒后的第一个点是段起点。
        let restarted = BatteryHistoryRecorder(store: store, now: t0.addingTimeInterval(300)) { _ in }
        restarted.record(status(.battery, 78), at: t0.addingTimeInterval(300))
        restarted.flush()
        let now = t0.addingTimeInterval(400)
        let all = restarted.history
        return check("唤醒段起点", wakeHistory.records.map(\.segmentStart) == [true, true])
            && check("唤醒后不连线", wakeHistory.segments(now: now).map(\.count) == [1, 1])
            && check("唤醒后不计入摘要", wakeHistory.summary(now: now).batterySeconds == 0)
            && check("重启后不连线", all.records.count == 3 && all.segments(now: now).map(\.count) == [1, 1, 1])
            && check("重启后不计入摘要", all.summary(now: now).batterySeconds == 0 && all.summary(now: now).drainedPercent == 0)
    }

    static func restart() -> Bool {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BatteryHistoryStore(directory: directory)
        let first = BatteryHistoryRecorder(store: store, now: t0) { _ in }
        for step in 0...2 { first.record(status(.battery, 80 - step), at: t0.addingTimeInterval(Double(step) * 300)) }
        first.flush()
        var published: BatteryHistory?
        let second = BatteryHistoryRecorder(store: store, now: t0.addingTimeInterval(3600)) { published = $0 }
        guard check("启动时读入历史并发布", second.history.records.count == 3 && published?.records.count == 3) else { return false }
        second.record(status(.battery, 70), at: t0.addingTimeInterval(3600))
        second.record(status(.battery, 69), at: t0.addingTimeInterval(3900))
        second.flush()
        let loaded = store.load(now: t0.addingTimeInterval(3900))
        return check("接在旧历史之后", loaded.records.map { $0.sampledAt.timeIntervalSince(t0) } == [0, 300, 600, 3600, 3900])
            && check("新运行首点是段起点", loaded.records.map(\.segmentStart) == [true, false, false, true, false])
            && check("摘要按段累计", loaded.summary(now: t0.addingTimeInterval(3900)).batterySeconds == 900
                && loaded.summary(now: t0.addingTimeInterval(3900)).drainedPercent == 3)
    }

    static func storage() -> Bool {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BatteryHistoryStore(directory: directory)
        let now = t0.addingTimeInterval(86400 * 2)
        let formatter = ISO8601DateFormatter()
        func line(_ offset: TimeInterval, _ percent: Int = 50, state: String = "battery", extra: String = "") -> String {
            #"{"dischargeWatts":8,"percent":\#(percent),"sampledAt":"\#(formatter.string(from: now.addingTimeInterval(offset)))","state":"\#(state)"\#(extra)}"#
        }
        let text = [
            line(-86400 - 1),                 // 超过 24 小时
            line(-86400 + 60, extra: #","segmentStart":true"#),
            "{broken",
            line(-600, 150),                  // 电量越界
            line(-500, state: "noBattery"),   // 无电池不应有点
            line(-400, state: "unknown"),     // 未知状态
            #"{"percent":40}"#,
            line(-300),
            line(30),                         // 未来 30 秒以内，保留
            line(120),                        // 未来超过 60 秒，丢弃
        ].joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: store.file)
        } catch { print("夹具写入失败：\(error)"); return false }
        let loaded = store.load(now: now)
        guard check("坏行跳过、24 小时裁剪、拒绝未来超过 60 秒", loaded.records.map { $0.sampledAt.timeIntervalSince(now) } == [-86400 + 60, -300, 30]),
              check("段起点字段读回", loaded.records.map(\.segmentStart) == [true, false, false]) else { return false }
        // 记录器第一次写入时整体重写，过期和坏行随之清掉；之后追加时也按 24 小时裁剪内存。
        let recorder = BatteryHistoryRecorder(store: store, now: now) { _ in }
        recorder.record(status(.battery, 49), at: now.addingTimeInterval(40))
        recorder.record(status(.charging, 50), at: now.addingTimeInterval(200))
        recorder.flush()
        let lines = ((try? String(contentsOf: store.file, encoding: .utf8)) ?? "").split(separator: "\n")
        guard check("重写后文件只有有效行", lines.count == 5 && !lines.contains { $0.contains("broken") || $0.contains("noBattery") }),
              check("段起点只写为 true", lines.filter { $0.contains("segmentStart") }.allSatisfy { $0.contains(#""segmentStart":true"#) }) else { return false }
        var history = store.load(now: now.addingTimeInterval(200))
        history.append(BatteryHistoryRecord(sampledAt: now.addingTimeInterval(200 + 86400), percent: 50, state: .battery), now: now.addingTimeInterval(200 + 86400))
        guard check("追加时裁剪 24 小时", history.records.count == 2) else { return false }
        // 超大文件当作空历史。
        do {
            var big = Data(count: BatteryHistoryStore.maxFileBytes + 1)
            big.replaceSubrange(0..<1, with: [0x0A])
            try big.write(to: store.file)
        } catch { print("夹具写入失败：\(error)"); return false }
        return check("超大文件当作空", store.load(now: now).records.isEmpty)
    }

    static func noBattery() -> Bool {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = BatteryHistoryRecorder(store: BatteryHistoryStore(directory: directory), now: t0) { _ in }
        for step in 0...40 {
            recorder.record(step % 2 == 0 ? nil : .noBattery, at: t0.addingTimeInterval(Double(step) * 30))
        }
        recorder.wake()
        recorder.record(.noBattery, at: t0.addingTimeInterval(2000))
        // 有电池但读不到电量时也不记。
        recorder.record(BatteryStatus(state: .battery), at: t0.addingTimeInterval(2100))
        recorder.flush()
        return check("无电池不写盘", recorder.history.records.isEmpty && !FileManager.default.fileExists(atPath: directory.path))
    }

    static func summaryEdges() -> Bool {
        let day: TimeInterval = 86400
        // 跨缺口：两点都用电池但相隔 400 秒。
        let gap = rows([(0, 80, .battery, true), (400, 78, .battery, false)])
        // 只有接电源。
        let acOnly = rows([(0, 80, .acNotCharging, true), (300, 80, .acNotCharging, false), (600, 80, .charged, false)])
        // 只有 1 个点。
        let single = rows([(0, 58, .battery, true)])
        // 间隔 331 秒和 330 秒。
        let edge = rows([(0, 80, .battery, true), (331, 79, .battery, false), (661, 77, .battery, false)])
        // 一侧接电源的区间不计；电量回升不算耗电；功率均值按区间端点去重。
        let mixed = BatteryHistory(records: [
            BatteryHistoryRecord(sampledAt: t0, percent: 80, state: .battery, dischargeWatts: 6, segmentStart: true),
            BatteryHistoryRecord(sampledAt: t0.addingTimeInterval(300), percent: 78, state: .battery, dischargeWatts: 9),
            BatteryHistoryRecord(sampledAt: t0.addingTimeInterval(600), percent: 79, state: .battery, dischargeWatts: 12),
            BatteryHistoryRecord(sampledAt: t0.addingTimeInterval(700), percent: 79, state: .charging),
            BatteryHistoryRecord(sampledAt: t0.addingTimeInterval(1000), percent: 82, state: .battery, dischargeWatts: 100),
        ])
        // 记录覆盖整个 24 小时但从未用电池。
        let fullAC = BatteryHistory(records: stride(from: 0.0, through: day, by: 300).enumerated().map { index, offset in
            BatteryHistoryRecord(sampledAt: t0.addingTimeInterval(offset), percent: 80, state: .acNotCharging, segmentStart: index == 0)
        })
        let now = t0.addingTimeInterval(1000)
        let g = gap.summary(now: now), a = acOnly.summary(now: now), s = single.summary(now: t0.addingTimeInterval(120))
        let e = edge.summary(now: now), m = mixed.summary(now: now), f = fullAC.summary(now: t0.addingTimeInterval(day))
        return check("跨缺口不计", !g.hasBatteryUse && g.drainedPercent == 0 && g.averageWatts == nil && gap.segments(now: now).count == 2)
            && check("只有接电源", !a.hasBatteryUse && a.recordedSeconds == 1000 && !a.coversWindow)
            && check("只有 1 个点", !s.hasBatteryUse && s.recordedSeconds == 120 && s.averageWatts == nil)
            && check("331 秒不计、330 秒计入", e.batterySeconds == 330 && e.drainedPercent == 2 && edge.segments(now: now).map(\.count) == [1, 2])
            && check("混合区间", m.batterySeconds == 600 && m.drainedPercent == 2 && m.averageWatts == 9)
            && check("覆盖 24 小时未用电池", !f.hasBatteryUse && f.coversWindow)
            && check("窗口外的点不计", rows([(-day - 10, 90, .battery, true), (-day + 280, 89, .battery, false)]).summary(now: t0).batterySeconds == 0)
    }
}
