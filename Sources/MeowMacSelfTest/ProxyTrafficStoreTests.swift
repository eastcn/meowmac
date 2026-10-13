import Foundation
import MeowMacCore

@MainActor
enum ProxyTrafficStoreTests {
    private static let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    private static let manager = FileManager.default
    private static let firstHour = "2026-10-13T15:00:00+08:00"
    private static let now = ISO8601DateFormatter().date(from: "2026-10-13T18:00:00+08:00")!

    static var tests: [(String, @MainActor () -> Bool)] {
        [
            ("Core.ProxyTraffic.StoreLargeDayDedup", largeDayDedup),
            ("Core.ProxyTraffic.StorePartialAndInvalidRows", partialAndInvalidRows),
            ("Core.ProxyTraffic.StoreReadFailure", readFailure),
            ("Core.ProxyTraffic.StoreAtomicCheckpoint", atomicCheckpoint),
            ("Core.ProxyTraffic.StoreRetention", retention),
            ("Core.ProxyTraffic.StoreCrashRecovery", crashRecovery),
            ("Core.ProxyTraffic.StoreCorruptCheckpoint", corruptCheckpoint)
        ]
    }

    private static func temporary(_ body: (URL) throws -> Bool) -> Bool {
        let directory = URL(fileURLWithPath: "build/acceptance/proxy-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: directory) }
            return try body(directory)
        } catch { print("代理流量存储测试失败：\(error)"); return false }
    }

    private static func object(hour: String = firstHour, up: Int64 = 10,
                               source: String = "mac", collector: String = "meowmac/test") -> [String: Any] {
        let zero: [String: Int64] = ["up": 0, "down": 0]
        return ["schema": "mihomo-traffic/v1", "source": source, "collector": collector,
                "hour": hour, "coverage_seconds": 5, "core_restarts": 0,
                "proxy": ["up": up, "down": 0], "direct": zero,
                "match": ["up": up, "down": 0], "other": zero, "by_src": [],
                "by_process": [["process": "DemoBrowser", "up": up, "down": 0]],
                "items": [["process": "DemoBrowser", "src": NSNull(), "host": "example.com",
                           "rule": "Match", "rule_payload": "", "node": "DemoNode",
                           "group": "DemoGroup", "up": up, "down": 0]]]
    }

    private static func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func row(hour: String = firstHour, up: Int64 = 10) throws -> ProxyTrafficRow {
        try ProxyTrafficRow.decode(json(object(hour: hour, up: up)))
    }

    private static func up(_ row: ProxyTrafficRow) throws -> Int64 {
        let object = try JSONSerialization.jsonObject(with: row.encoded()) as! [String: Any]
        return (object["proxy"] as! [String: NSNumber])["up"]!.int64Value
    }

    private static func fails(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    private static func largeDayDedup() -> Bool {
        temporary { directory in
            let store = ProxyTrafficStore(directory: directory, timeZone: zone)
            let path = directory.appendingPathComponent("2026-10-13.jsonl")
            // 超大但有效的第一行位于文件开头，不能只读尾部或把大文件当作空数据。
            var original = try json(object(collector: "meowmac/" + String(repeating: "x", count: 270_000)))
            original.append(10)
            try original.write(to: path)
            guard original.count > 256 * 1024 else { return false }
            try store.append(row(up: 999))
            guard try Data(contentsOf: path) == original else { return false }
            try store.append(row(hour: "2026-10-13T16:00:00+08:00", up: 20))
            let rows = try store.loadRows(now: now)
            return try rows.count == 2 && up(rows[0]) == 10 && up(rows[1]) == 20 &&
                (try Data(contentsOf: path)).starts(with: original)
        }
    }

    private static func partialAndInvalidRows() -> Bool {
        temporary { directory in
            var reports: [String: Int] = [:]
            let store = ProxyTrafficStore(directory: directory, timeZone: zone) { reports[$0, default: 0] += $1 }
            let path = directory.appendingPathComponent("2026-10-13.jsonl")
            var bytes = Data("{partial\n\n".utf8)
            for value in [object(up: 11), object(up: 99), object(source: "home"),
                          object(hour: "2026-10-12T16:00:00+08:00")] {
                bytes.append(try json(value)); bytes.append(10)
            }
            // 末尾断行后继续追加时必须先隔开，避免破坏下一条有效行。
            bytes.append(Data("{unfinished".utf8))
            try bytes.write(to: path)
            try store.append(row(hour: "2026-10-13T16:00:00+08:00", up: 22))
            reports.removeAll()
            let rows = try store.loadRows(now: now)
            return try rows.count == 2 && up(rows[0]) == 11 && up(rows[1]) == 22 &&
                reports == ["invalid_history_rows": 5, "duplicate_history_rows": 1]
        }
    }

    private static func readFailure() -> Bool {
        temporary { directory in
            let path = directory.appendingPathComponent("not-a-directory")
            try Data("sentinel".utf8).write(to: path)
            let store = ProxyTrafficStore(directory: path, timeZone: zone)
            guard fails({ _ = try store.loadRows(now: now) }) else { return false }
            let checkpoint = directory.appendingPathComponent("checkpoint.json", isDirectory: true)
            try manager.createDirectory(at: checkpoint, withIntermediateDirectories: false)
            let regular = ProxyTrafficStore(directory: directory, timeZone: zone)
            return fails({ _ = try regular.loadCheckpoint() }) &&
                fails({ try regular.saveCheckpoint(Data("replacement".utf8)) }) &&
                manager.fileExists(atPath: checkpoint.path)
        }
    }

    private static func atomicCheckpoint() -> Bool {
        temporary { directory in
            let store = ProxyTrafficStore(directory: directory, timeZone: zone)
            guard try store.loadCheckpoint() == nil else { return false }
            for count in [1, 4096, 0, 131_072, 7] {
                let expected = Data(repeating: UInt8(count % 251), count: count)
                try store.saveCheckpoint(expected)
                guard try store.loadCheckpoint() == expected else { return false }
                let names = try manager.contentsOfDirectory(atPath: directory.path)
                guard names == ["checkpoint.json"] else { return false }
            }
            let target = directory.appendingPathComponent("checkpoint.json")
            let sentinel = directory.appendingPathComponent("sentinel")
            let original = Data("keep original bytes".utf8)
            try original.write(to: sentinel)
            try manager.removeItem(at: target)
            try manager.createSymbolicLink(at: target, withDestinationURL: sentinel)
            return try fails({ try store.saveCheckpoint(Data("replacement".utf8)) }) &&
                (try Data(contentsOf: sentinel)) == original &&
                !(try manager.contentsOfDirectory(atPath: directory.path)).contains { $0.hasPrefix("checkpoint-") }
        }
    }

    private static func retention() -> Bool {
        temporary { directory in
            let store = ProxyTrafficStore(directory: directory, timeZone: zone)
            let old = "2026-09-12.jsonl", boundary = "2026-09-13.jsonl", recent = "2026-10-13.jsonl"
            let preserved = [boundary, recent, "README.md", "2026-01-01.txt", "2026-02-30.jsonl"]
            for name in [old] + preserved { try Data("sentinel".utf8).write(to: directory.appendingPathComponent(name)) }
            let subdirectory = directory.appendingPathComponent("2026-01-02.jsonl", isDirectory: true)
            try manager.createDirectory(at: subdirectory, withIntermediateDirectories: false)
            let link = directory.appendingPathComponent("2026-01-03.jsonl")
            let target = directory.appendingPathComponent("README.md")
            try manager.createSymbolicLink(at: link, withDestinationURL: target)
            try store.trim(now: now)
            return try !manager.fileExists(atPath: directory.appendingPathComponent(old).path) &&
                preserved.allSatisfy { manager.fileExists(atPath: directory.appendingPathComponent($0).path) } &&
                manager.fileExists(atPath: subdirectory.path) && manager.fileExists(atPath: link.path) &&
                (try Data(contentsOf: target)) == Data("sentinel".utf8)
        }
    }

    private static func connection(_ id: String, up: Int64, process: String) -> [String: Any] {
        ["id": id, "upload": up, "download": 0, "rule": "Match", "rulePayload": "",
         "chains": ["DemoNode", "DemoGroup"],
         "metadata": ["process": process, "host": "example.com", "destinationIP": "198.51.100.1"]]
    }

    private static func snapshot(_ connections: [[String: Any]], total: Int64? = nil) throws -> ProxyTrafficSnapshot {
        let sum = connections.reduce(Int64(0)) { $0 + ($1["upload"] as! Int64) }
        return try ProxyTrafficSnapshot.parse(json(["connections": connections, "uploadTotal": total ?? sum, "downloadTotal": 0]))
    }

    private static func settle(_ accumulator: inout ProxyTrafficAccumulator, store: ProxyTrafficStore, at date: Date) throws {
        let ended = try accumulator.rows().filter { $0.date! < ProxyTrafficTime.start(date, timeZone: zone) }
        if ended.isEmpty { return }
        // 与正式协调器相同：保留待写行的检查点先落盘，成功后才能删内存桶。
        try store.saveCheckpoint(accumulator.checkpoint())
        for row in ended { try store.append(row); accumulator.remove(hour: row.hour) }
    }

    private static func crashRecovery() -> Bool {
        for appended in [false, true] {
            guard temporary({ directory in
                let store = ProxyTrafficStore(directory: directory, timeZone: zone)
                let start = ProxyTrafficTime.parse(firstHour)!
                var accumulator = ProxyTrafficAccumulator(timeZone: zone)
                @MainActor func input(_ live: Int64, _ closed: Int64?, _ new: Int64? = nil, total: Int64? = nil) throws -> ProxyTrafficSnapshot {
                    var connections = [connection("live", up: live, process: "DemoLive")]
                    if let closed { connections.append(connection("closed", up: closed, process: "DemoClosed")) }
                    if let new { connections.append(connection("new", up: new, process: "DemoNew")) }
                    return try snapshot(connections, total: total)
                }
                try accumulator.accept(input(10, 0), at: start)
                try accumulator.accept(input(20, 10), at: start.addingTimeInterval(5))
                try accumulator.accept(input(30, 20), at: start.addingTimeInterval(3600))
                try store.saveCheckpoint(accumulator.checkpoint())
                let originalCheckpoint = try store.loadCheckpoint()!
                let old = try accumulator.rows().first { $0.hour == firstHour }!
                guard old.proxy.up == 20 else { return false }
                if appended { try store.append(old) }
                // 这个样本只留内存，直接丢弃模拟断电，不能正常退出补写检查点。
                try accumulator.accept(input(40, 25, 7), at: start.addingTimeInterval(3605))
                accumulator = try ProxyTrafficAccumulator(checkpoint: originalCheckpoint, timeZone: zone)
                try settle(&accumulator, store: store, at: start.addingTimeInterval(3610))
                try accumulator.accept(input(50, nil, 9, total: 100), at: start.addingTimeInterval(3610))
                try accumulator.accept(input(55, nil, 12, total: 110), at: start.addingTimeInterval(3615))
                try accumulator.accept(input(55, nil, 12, total: 110), at: start.addingTimeInterval(7200))
                try settle(&accumulator, store: store, at: start.addingTimeInterval(7200))
                let rows = try store.loadRows(now: now)
                let recorded = rows.reduce(Int64(0)) { $0 + $1.proxy.up }
                var process: [String: Int64] = [:]
                for row in rows { for entry in row.byProcess { process[entry.process ?? "", default: 0] += entry.up } }
                let trueGrowth: Int64 = (55 - 10) + 25 + 12
                guard rows.count == 2, rows.first?.proxy.up == 20, recorded == 68,
                      trueGrowth - recorded == 14,
                      process == ["DemoLive": 45, "DemoClosed": 20, "DemoNew": 3] else { return false }
                // 恢复重复结算不能追加或改写任何已有行。
                let path = directory.appendingPathComponent("2026-10-13.jsonl")
                let bytes = try Data(contentsOf: path)
                var repeated = try ProxyTrafficAccumulator(checkpoint: originalCheckpoint, timeZone: zone)
                try settle(&repeated, store: store, at: start.addingTimeInterval(3610))
                return try Data(contentsOf: path) == bytes
            }) else { return false }
        }
        return true
    }

    private static func corruptCheckpoint() -> Bool {
        temporary { directory in
            let store = ProxyTrafficStore(directory: directory, timeZone: zone)
            let path = directory.appendingPathComponent("checkpoint.json")
            for content in ["broken", "[]", "null", #"{"version":1,"source":"mac"}"#] {
                let bytes = Data(content.utf8)
                try bytes.write(to: path)
                guard let loaded = try store.loadCheckpoint(), loaded == bytes,
                      fails({ _ = try ProxyTrafficAccumulator(checkpoint: loaded, timeZone: zone) }),
                      try Data(contentsOf: path) == bytes else { return false }
            }
            return true
        }
    }
}
