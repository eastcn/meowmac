import Foundation
import MeowMacCore

@MainActor
enum ProxyTrafficCoreTests {
    static func tests() -> [(String, @MainActor () async -> Bool)] {
        [
            ("ProxyTraffic.Core/基线增量和单计数回退", { run(baseline) }),
            ("ProxyTraffic.Core/消失连接删除基线", { run(disappearance) }),
            ("ProxyTraffic.Core/恢复已知连接并重置覆盖", { run(restore) }),
            ("ProxyTraffic.Core/恢复首读检测内核重启", { run(restart) }),
            ("ProxyTraffic.Core/DIRECT REJECT MATCH 和空链分类", { run(classification) }),
            ("ProxyTraffic.Core/跨整点按比例精确覆盖", { run(boundary) }),
            ("ProxyTraffic.Core/失败断档与覆盖上限", { run(coverage) }),
            ("ProxyTraffic.Core/截断前完整排名和三处合计", { run(ranking) }),
            ("ProxyTraffic.Core/检查点恢复已知丢失边界", { run(crash) }),
            ("ProxyTraffic.Core/SCHEMA 示例键和显式 null", { run(schema) }),
            ("ProxyTraffic.Core/非法快照与溢出原子拒绝", { run(invalid) }),
            ("ProxyTraffic.Core/损坏检查点严格拒绝", { run(corruptCheckpoint) }),
            ("ProxyTraffic.Core/小时偏移与时钟回退", { run(time) }),
        ]
    }
    private static let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    private static let start = ProxyTrafficTime.parse("2026-10-13T15:00:00+08:00")!
    private static func run(_ body: () throws -> Bool) -> Bool {
        do { return try body() } catch { print("代理流量纯逻辑失败：\(type(of: error))"); return false }
    }
    private static func connection(_ id: String = "one", up: Int64 = 0, down: Int64 = 0, process: String = "DemoBrowser", host: String = "example.com", node: String = "DemoNode", rule: String = "Match") -> [String: Any] {
        ["id": id, "upload": up, "download": down, "rule": rule, "rulePayload": "", "chains": [node, "DemoGroup"],
         "metadata": ["process": process, "host": host, "sourceIP": "192.0.2.1", "destinationIP": "198.51.100.1"]]
    }
    private static func data(_ connections: [[String: Any]] = [], up: Int64? = nil, down: Int64? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["connections": connections,
            "uploadTotal": up ?? connections.reduce(Int64(0)) { $0 + ($1["upload"] as! Int64) },
            "downloadTotal": down ?? connections.reduce(Int64(0)) { $0 + ($1["download"] as! Int64) }])
    }
    private static func accept(_ accumulator: inout ProxyTrafficAccumulator, _ second: Double, _ connections: [[String: Any]] = [], up: Int64? = nil, down: Int64? = nil) throws {
        try accumulator.accept(ProxyTrafficSnapshot.parse(data(connections, up: up, down: down)), at: start.addingTimeInterval(second))
    }
    private static func row(_ accumulator: ProxyTrafficAccumulator, _ index: Int = 0) throws -> ProxyTrafficRow { try accumulator.rows()[index] }
    private static func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    private static func baseline() throws -> Bool {
        var a = ProxyTrafficAccumulator(timeZone: zone)
        try accept(&a, 0, [connection(up: 10, down: 20)])
        guard try row(a).proxy == .init() else { return false }
        try accept(&a, 5, [connection(up: 30, down: 50)])
        try accept(&a, 10, [connection(up: 3, down: 4)], up: 40, down: 70)
        return try row(a).proxy == .init(up: 23, down: 34) && row(a).coverageSeconds == 10
    }
    private static func disappearance() throws -> Bool {
        var a = ProxyTrafficAccumulator(timeZone: zone)
        try accept(&a, 0, [connection(up: 100)])
        try accept(&a, 5, up: 100, down: 0)
        try accept(&a, 10, [connection(up: 3)], up: 103, down: 0)
        return try row(a).proxy.up == 3
    }
    private static func restore() throws -> Bool {
        var a = ProxyTrafficAccumulator(timeZone: zone)
        try accept(&a, 0, [connection(up: 10)])
        try accept(&a, 5, [connection(up: 20)])
        a = try ProxyTrafficAccumulator(checkpoint: a.checkpoint(), timeZone: zone)
        try accept(&a, 15, [connection(up: 40), connection("new", up: 7)])
        guard try row(a).proxy.up == 30 && row(a).coverageSeconds == 5 else { return false }
        try accept(&a, 20, [connection(up: 50), connection("new", up: 9)])
        return try row(a).proxy.up == 42 && row(a).coverageSeconds == 10
    }
    private static func restart() throws -> Bool {
        var a = ProxyTrafficAccumulator(timeZone: zone)
        try accept(&a, 0, [connection(up: 100, down: 200)])
        a = try ProxyTrafficAccumulator(checkpoint: a.checkpoint(), timeZone: zone)
        try accept(&a, 5, [connection(up: 3, down: 4), connection("new", up: 7)])
        let result = try row(a)
        guard result.proxy == .init(up: 10, down: 4), result.coreRestarts == 1, result.coverageSeconds == 0 else { return false }
        // 只有一个全量方向回退也应视为重启。
        try accept(&a, 10, [connection(up: 5, down: 8)], up: 20, down: 3)
        return try row(a).coreRestarts == 2 && row(a).proxy == .init(up: 15, down: 12)
    }
    private static func classification() throws -> Bool {
        var a = ProxyTrafficAccumulator(timeZone: zone)
        try accept(&a, 0)
        var blank = connection("blank", up: 2, down: 3, process: "", host: "", rule: "DomainSuffix")
        blank["chains"] = []
        var missing: [String: Any] = ["id": "missing", "upload": Int64(0), "download": Int64(0)]
        missing["unknown"] = "ignored"
        try accept(&a, 5, [connection("direct", up: 10, down: 20, node: "DIRECT"), connection("reject", up: 30, down: 40, node: "REJECT"), connection("proxy", up: 50, down: 60), blank, missing])
        let r = try row(a)
        guard r.direct == .init(up: 10, down: 20), r.proxy == .init(up: 52, down: 63), r.match == .init(up: 50, down: 60), r.bySrc.isEmpty,
              let detail = r.items.first(where: { $0.host == "198.51.100.1" }) else { return false }
        return detail.process == nil && detail.node == nil && detail.group == nil && r.items.allSatisfy { $0.src == nil }
    }
    private static func boundary() throws -> Bool {
        var a = ProxyTrafficAccumulator(timeZone: zone)
        try accept(&a, 3598, [connection()]); try accept(&a, 3603, [connection(up: 10, down: 20)])
        let rows = try a.rows()
        guard rows.count == 2, rows[0].proxy == .init(), rows[0].coverageSeconds == 2, rows[1].proxy == .init(up: 10, down: 20), rows[1].coverageSeconds == 3 else { return false }
        var b = ProxyTrafficAccumulator(timeZone: zone)
        try accept(&b, 3590); try accept(&b, 3610)
        return try b.rows().map(\.coverageSeconds) == [5, 5]
    }
    private static func coverage() throws -> Bool {
        var a = ProxyTrafficAccumulator(timeZone: zone)
        try accept(&a, 0); a.interruptCoverage(); try accept(&a, 10); try accept(&a, 15)
        guard try row(a).coverageSeconds == 5 else { return false }
        try accept(&a, 40)
        guard try row(a).coverageSeconds == 15 else { return false }
        var b = ProxyTrafficAccumulator(timeZone: zone)
        for second in stride(from: 0, through: 3599, by: 5) { try accept(&b, Double(second)) }
        try accept(&b, 3599)
        return try row(b).coverageSeconds == 3599
    }
    private static func ranking() throws -> Bool {
        var a = ProxyTrafficAccumulator(timeZone: zone)
        try accept(&a, 0)
        var entries = (0..<100).map { connection("a\($0)", up: 101, process: "DemoA", host: "a\($0).example.com") }
        entries += (0..<102).map { connection("b\($0)", up: 100, process: "DemoB", host: "b\($0).example.net") }
        try accept(&a, 5, entries)
        let r = try row(a)
        guard r.items.count == 100, r.other.up == 10200, r.match.up == 20300,
              r.byProcess == [.init(process: "DemoB", up: 10200, down: 0), .init(process: "DemoA", up: 10100, down: 0)] else { return false }
        _ = try ProxyTrafficRow.decode(r.encoded())
        // 负向对照：用截断明细代替完整进程排名，合计必须被拒绝。
        let broken = ProxyTrafficRow(hour: r.hour, proxy: r.proxy, match: r.match,
            byProcess: [.init(process: "DemoA", up: 10100, down: 0)], items: r.items, other: r.other)
        return rejects { _ = try broken.encoded() }
    }
    private static func crash() throws -> Bool {
        // 同一检查点两次恢复，输出必须相同；检查点之后关闭和新出现连接的损失按 SCHEMA 保留。
        var original = ProxyTrafficAccumulator(timeZone: zone)
        try accept(&original, 0, [connection("live", up: 10, process: "DemoLive")])
        try accept(&original, 5, [connection("live", up: 20, process: "DemoLive"), connection("closed", up: 20, process: "DemoClosed")])
        let checkpoint = try original.checkpoint()
        var expected: [ProxyTrafficRow]?
        for _ in 0..<2 {
            var a = try ProxyTrafficAccumulator(checkpoint: checkpoint, timeZone: zone)
            try accept(&a, 3610, [connection("live", up: 50, process: "DemoLive"), connection("new", up: 9, process: "DemoNew")], up: 100, down: 0)
            try accept(&a, 3615, [connection("live", up: 55, process: "DemoLive"), connection("new", up: 12, process: "DemoNew")], up: 110, down: 0)
            let rows = try a.rows()
            guard rows.count == 2, rows[0].proxy.up == 30, rows.reduce(Int64(0), { $0 + $1.proxy.up }) == 68, rows[1].coverageSeconds == 5 else { return false }
            if let expected, expected != rows { return false }; expected = rows
            let before = try a.checkpoint(); let restored = try ProxyTrafficAccumulator(checkpoint: before, timeZone: zone)
            guard try restored.rows() == rows else { return false }
            a.remove(hour: rows[0].hour)
            guard try a.rows().count == 1 else { return false }
        }
        return true
    }
    private static let example = #"{"schema":"mihomo-traffic/v1","source":"mac","collector":"meowkit-mihomo-traffic/1","hour":"2026-10-13T15:00:00+08:00","coverage_seconds":3590,"core_restarts":0,"proxy":{"up":100,"down":900},"direct":{"up":20,"down":80},"match":{"up":100,"down":900},"by_process":[{"process":"DemoBrowser","up":100,"down":900}],"by_src":[],"items":[{"process":"DemoBrowser","src":null,"host":"example.com","rule":"Match","rule_payload":"","node":"DemoNode","group":"DemoGroup","up":100,"down":900}],"other":{"up":0,"down":0}}"#
    private static func schema() throws -> Bool {
        let bytes = Data(example.utf8), decoded = try ProxyTrafficRow.decode(bytes), encoded = try decoded.encoded()
        let a = try JSONSerialization.jsonObject(with: bytes) as! [String: Any], b = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        guard Set(a.keys) == Set(b.keys), try ProxyTrafficRow.decode(encoded) == decoded else { return false }
        let item = ProxyTrafficItem(process: nil, host: "", rule: "", node: nil, group: nil)
        let nullRow = ProxyTrafficRow(hour: decoded.hour, byProcess: [.init(process: nil, up: 0, down: 0)], items: [item])
        let root = try JSONSerialization.jsonObject(with: nullRow.encoded()) as! [String: Any]
        let fields = (root["items"] as! [[String: Any]])[0]
        return ["src", "process", "node", "group"].allSatisfy { fields[$0] is NSNull } && (root["by_process"] as! [[String: Any]])[0]["process"] is NSNull
    }
    private static func invalid() throws -> Bool {
        let negatives = [#"{"connections":[],"uploadTotal":true,"downloadTotal":0}"#,
            #"{"connections":[],"uploadTotal":1.5,"downloadTotal":0}"#,
            #"{"connections":[],"uploadTotal":1.0,"downloadTotal":0}"#,
            #"{"connections":[],"uploadTotal":9223372036854775808,"downloadTotal":0}"#,
            #"{"connections":[{"id":"a","upload":-1,"download":0}],"uploadTotal":0,"downloadTotal":0}"#,
            #"{"connections":[{"id":"a","upload":0,"download":0},{"id":"a","upload":0,"download":0}],"uploadTotal":0,"downloadTotal":0}"#]
        guard negatives.allSatisfy({ text in rejects { _ = try ProxyTrafficSnapshot.parse(Data(text.utf8)) } }) else { return false }
        var a = ProxyTrafficAccumulator(timeZone: zone); try accept(&a, 0)
        try accept(&a, 5, [connection(up: Int64.max)], up: Int64.max, down: 0)
        let before = try a.checkpoint()
        guard rejects({ try accept(&a, 10, [connection(up: Int64.max), connection("overflow", up: 1)], up: Int64.max, down: 0) }), try a.checkpoint() == before else { return false }
        let badRowChanges: [(String, Any)] = [("source", "home"), ("coverage_seconds", true), ("core_restarts", -1), ("hour", "2026-10-13T15:00:00"), ("extra", 1), ("proxy", ["up": 99, "down": 900])]
        for (key, value) in badRowChanges {
            var raw = try JSONSerialization.jsonObject(with: Data(example.utf8)) as! [String: Any]; raw[key] = value
            guard rejects({ _ = try ProxyTrafficRow.decode(JSONSerialization.data(withJSONObject: raw)) }) else { return false }
        }
        // 类型、键、排序和唯一性分别植入错误，确保读取时拒绝。
        for modification in 0..<8 {
            var raw = try JSONSerialization.jsonObject(with: Data(example.utf8)) as! [String: Any]
            var items = raw["items"] as! [[String: Any]]
            switch modification {
            case 0: items[0].removeValue(forKey: "src")
            case 1: items[0]["src"] = "192.0.2.1"
            case 2: items[0]["up"] = true
            case 3: items[0]["host"] = NSNull()
            case 4: items.append(items[0])
            case 5: raw["by_process"] = (raw["by_process"] as! [Any]) + (raw["by_process"] as! [Any])
            case 6: raw["match"] = ["up": 101, "down": 900]
            default:
                let smaller = ["process": "DemoSmall", "src": NSNull(), "host": "small.example.com", "rule": "Match", "rule_payload": "", "node": "DemoNode", "group": "DemoGroup", "up": 0, "down": 0] as [String: Any]
                items.insert(smaller, at: 0)
            }
            raw["items"] = items
            guard rejects({ _ = try ProxyTrafficRow.decode(JSONSerialization.data(withJSONObject: raw)) }) else { return false }
        }
        return true
    }
    private static func corruptCheckpoint() throws -> Bool {
        var a = ProxyTrafficAccumulator(timeZone: zone); try accept(&a, 0); try accept(&a, 5, [connection(up: 3)])
        let checkpoint = try a.checkpoint()
        guard ["broken", "[]", "null"].allSatisfy({ text in rejects { _ = try ProxyTrafficAccumulator(checkpoint: Data(text.utf8), timeZone: zone) } }) else { return false }
        let root = try JSONSerialization.jsonObject(with: checkpoint) as! [String: Any]
        let hour = ProxyTrafficTime.hour(start, timeZone: zone)
        for modification in 0..<8 {
            var raw = root
            switch modification {
            case 0: raw["version"] = true
            case 1: raw["source"] = "home"
            case 2: raw["totals"] = NSNull()
            case 3: raw["secret"] = "fictional-secret"
            default:
                var buckets = raw["buckets"] as! [String: Any], bucket = buckets[hour] as! [String: Any]
                if modification == 4 { bucket["coverage"] = -1 }
                if modification == 5 { bucket["coverage"] = true }
                if modification == 6 { bucket["proxy"] = ["up": 4, "down": 0] }
                if modification == 7 { bucket["details"] = (bucket["details"] as! [Any]) + (bucket["details"] as! [Any]) }
                buckets[hour] = bucket; raw["buckets"] = buckets
            }
            guard rejects({ _ = try ProxyTrafficAccumulator(checkpoint: JSONSerialization.data(withJSONObject: raw), timeZone: zone) }) else { return false }
        }
        return try a.checkpoint() == checkpoint && !String(data: checkpoint, encoding: .utf8)!.contains("192.0.2.1")
    }
    private static func time() throws -> Bool {
        guard ProxyTrafficTime.hour(start.addingTimeInterval(599.25), timeZone: zone) == "2026-10-13T15:00:00+08:00",
              ProxyTrafficTime.day("2026-10-13T15:00:00+08:00") == "2026-10-13",
              ProxyTrafficTime.parse("2026-02-30T15:00:00+08:00") == nil,
              ProxyTrafficTime.parse("2026-10-13T15:00:00.1+08:00") == nil else { return false }
        var a = ProxyTrafficAccumulator(timeZone: zone); try accept(&a, 10); try accept(&a, 5)
        return try row(a).coverageSeconds == 0
    }
}
