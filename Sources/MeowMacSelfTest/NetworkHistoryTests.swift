import Foundation
import MeowMacCore
import MeowMacUI
import TunCanaryCore

@MainActor
enum NetworkHistoryTests {
    static let tests: [(String, @MainActor () -> Bool)] = [
        ("Network.History/分组统计与全部失败", groups),
        ("Network.History/同批去重", dedupe),
        ("Network.History/速率 30 秒窗口与休眠断档", traffic),
        ("Network.History/坏行、超大文件与 24 小时裁剪", storage),
        ("Network.History/分桶边界与空档", buckets),
    ]

    private static let now = ISO8601DateFormatter().date(from: "2030-04-10T12:00:00Z")!

    private static func result(_ id: String, _ group: SiteGroup, ok: Bool, ms: Double, at date: Date) -> SiteResult {
        let site = Site(id: id, name: "示例", group: group, url: URL(string: "https://example.com")!, isKey: false, inLightProbe: true)
        return SiteResult(site: site, category: ok ? .reachable : .timeout, medianLatency: ok ? ms / 1000 : nil, attempts: [], checkedAt: date)
    }

    private static func groups() -> Bool {
        var history = SiteHistory()
        history.record([result("a", .mainland, ok: true, ms: 20, at: now), result("b", .mainland, ok: true, ms: 40, at: now),
                        result("c", .mainland, ok: false, ms: 0, at: now), result("d", .overseas, ok: false, ms: 0, at: now),
                        result("e", .intranet, ok: true, ms: 8, at: now), result("f", .tailnet, ok: true, ms: 12, at: now.addingTimeInterval(-30))])
        let rows = NetworkRoundBuilder.rows(from: history)
        guard rows.count == 3, rows.allSatisfy({ $0.sampledAt == now }) else { return false }
        let byGroup = Dictionary(uniqueKeysWithValues: rows.map { ($0.group, $0) })
        guard let mainland = byGroup[.mainland], let overseas = byGroup[.overseas], let subnet = byGroup[.subnet] else { return false }
        return mainland.passed == 2 && mainland.total == 3 && mainland.medianMilliseconds == 30 && mainland.failed && !mainland.allFailed
            && overseas.passed == 0 && overseas.total == 1 && overseas.medianMilliseconds == nil && overseas.allFailed
            && subnet.passed == 2 && subnet.total == 2 && subnet.medianMilliseconds == 10
            && NetworkRoundBuilder.rows(from: SiteHistory()).isEmpty
    }

    private static func dedupe() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var published = NetworkHistory()
        let recorder = NetworkHistoryRecorder(store: NetworkHistoryStore(directory: directory), now: now) { published = $0 }
        var history = SiteHistory()
        history.record(result("a", .mainland, ok: true, ms: 20, at: now))
        recorder.record(siteHistory: history, now: now)
        recorder.record(siteHistory: history, now: now.addingTimeInterval(5))
        history.record(result("b", .overseas, ok: true, ms: 200, at: now.addingTimeInterval(-10)))
        recorder.record(siteHistory: history, now: now.addingTimeInterval(10))
        guard published.sites.count == 3 else { return false }
        history.record(result("a", .mainland, ok: true, ms: 25, at: now.addingTimeInterval(120)))
        recorder.record(siteHistory: history, now: now.addingTimeInterval(121))
        return published.sites.count == 6 && published.sites.last?.sampledAt == now.addingTimeInterval(120)
    }

    private static func traffic() -> Bool {
        var accumulator = TrafficAccumulator()
        var records: [TrafficRecord] = []
        for second in stride(from: 0, through: 30, by: 2) {
            if let row = accumulator.add(received: Double(second), sent: 1, at: now.addingTimeInterval(Double(second))) { records.append(row) }
        }
        guard records.count == 1, records[0].receivedAverage == 15, records[0].receivedPeak == 30, records[0].sentAverage == 1 else { return false }
        // 休眠：间隔 11 秒，未满的窗口丢弃，从新样本重新计时。
        _ = accumulator.add(received: 100, sent: 0, at: now.addingTimeInterval(32))
        _ = accumulator.add(received: 100, sent: 0, at: now.addingTimeInterval(43))
        var late: TrafficRecord?
        for second in stride(from: 45, through: 71, by: 2) { late = accumulator.add(received: 4, sent: 0, at: now.addingTimeInterval(Double(second))) ?? late }
        guard late == nil, let resumed = accumulator.add(received: 4, sent: 0, at: now.addingTimeInterval(73)) else { return false }
        return resumed.receivedPeak == 100 && accumulator.add(received: nil, sent: 1, at: now.addingTimeInterval(75)) == nil
            && accumulator.add(received: -1, sent: 1, at: now.addingTimeInterval(77)) == nil
    }

    private static func storage() -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NetworkHistoryStore(directory: directory)
        do {
            try store.append(sites: [SiteRoundRecord(sampledAt: now.addingTimeInterval(-90000), group: .mainland, passed: 1, total: 1, medianMilliseconds: 9),
                                     SiteRoundRecord(sampledAt: now.addingTimeInterval(-60), group: .overseas, passed: 0, total: 1, medianMilliseconds: nil)])
            let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("sites.jsonl"))
            try handle.seekToEnd(); try handle.write(contentsOf: Data("{坏行\n\n".utf8)); try handle.close()
            try store.append(sites: [SiteRoundRecord(sampledAt: now, group: .mainland, passed: 1, total: 1, medianMilliseconds: 30)])
            try store.append(traffic: TrafficRecord(sampledAt: now, receivedAverage: 1, sentAverage: 2, receivedPeak: 3, sentPeak: 4))
        } catch { print("写入失败：\(error)"); return false }
        let loaded = store.load(now: now)
        guard loaded.sites.map(\.medianMilliseconds) == [nil, 30], loaded.traffic.count == 1 else { return false }
        do { try store.rewrite(loaded) } catch { return false }
        let lines = (try? String(contentsOf: directory.appendingPathComponent("sites.jsonl"), encoding: .utf8))?.split(separator: "\n").count
        guard lines == 2 else { return false }
        // 超大文件当作空历史，不读进内存。
        let big = directory.appendingPathComponent("traffic.jsonl")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: big) else { return false }
        try? handle.truncate(atOffset: UInt64(NetworkHistoryStore.maxFileBytes + 1)); try? handle.close()
        let missing = NetworkHistoryStore(directory: directory.appendingPathComponent("absent")).load(now: now)
        return store.load(now: now).traffic.isEmpty && store.load(now: now).sites.count == 2 && missing.sites.isEmpty
    }

    private static func buckets() -> Bool {
        let start = now.addingTimeInterval(-86400)
        var rows: [SiteRoundRecord] = []
        // 前 10 分钟桶：两轮，一轮失败；第二个桶：一轮全部失败。
        rows.append(SiteRoundRecord(sampledAt: start.addingTimeInterval(1), group: .overseas, passed: 2, total: 2, medianMilliseconds: 300))
        rows.append(SiteRoundRecord(sampledAt: start.addingTimeInterval(599), group: .overseas, passed: 1, total: 2, medianMilliseconds: 500))
        rows.append(SiteRoundRecord(sampledAt: start.addingTimeInterval(600), group: .overseas, passed: 0, total: 2, medianMilliseconds: nil))
        rows.append(SiteRoundRecord(sampledAt: start, group: .overseas, passed: 1, total: 1, medianMilliseconds: 1))
        rows.append(SiteRoundRecord(sampledAt: now, group: .mainland, passed: 1, total: 1, medianMilliseconds: 10))
        let day = NetworkTrend.sites(rows, group: .overseas, range: .day, now: now)
        guard day.count == 2, day[0].value == 400, day[0].low == 300, day[0].high == 500, day[0].failedRounds == 1, day[0].totalRounds == 2,
              day[1].value == nil, day[1].failedRounds == 1, day[0].date == start.addingTimeInterval(300) else { return false }
        let hour = NetworkTrend.sites(rows, group: .mainland, range: .hour, now: now)
        guard hour.count == 1, hour[0].value == 10, hour[0].failedRounds == 0 else { return false }
        let traffic = (0..<11).map { TrafficRecord(sampledAt: start.addingTimeInterval(Double($0) * 30 + 1), receivedAverage: Double($0), sentAverage: 0, receivedPeak: Double($0) * 2, sentPeak: 0) }
        let tday = NetworkTrend.traffic(traffic, received: true, range: .day, now: now)
        guard tday.count == 2, tday[0].value == 4.5, tday[0].high == 18, tday[1].value == 10 else { return false }
        // 空档：开头没有记录、中间断了 20 分钟、末尾正常。
        let dates = [now.addingTimeInterval(-3000), now.addingTimeInterval(-2880), now.addingTimeInterval(-1680), now.addingTimeInterval(-60)]
        let gaps = NetworkTrend.missingIntervals(dates, range: .hour, now: now, threshold: NetworkTrend.gapThreshold(range: .hour, sites: true))
        let empty = NetworkTrend.missingIntervals([], range: .hour, now: now, threshold: 330)
        return gaps.count == 3 && gaps[0] == 0...(600.0 / 3600) && abs(gaps[1].lowerBound - 720.0 / 3600) < 1e-9
            && abs(gaps[2].upperBound - 3540.0 / 3600) < 1e-9 && empty == [0...1]
    }
}
