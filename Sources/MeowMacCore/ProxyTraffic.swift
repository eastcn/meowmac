import Foundation
import CoreFoundation

public enum ProxyTrafficError: Error { case invalidJSON, invalidSnapshot, invalidRow, invalidCheckpoint, overflow }

public struct ProxyTrafficBytes: Codable, Equatable, Sendable {
    public var up: Int64
    public var down: Int64
    public init(up: Int64 = 0, down: Int64 = 0) { self.up = up; self.down = down }
    fileprivate var size: UInt64 { UInt64(up) + UInt64(down) }
    fileprivate mutating func add(_ bytes: Self) throws {
        up = try trafficSum(up, bytes.up); down = try trafficSum(down, bytes.down)
    }
}

public struct ProxyTrafficProcess: Codable, Equatable, Sendable {
    public let process: String?
    public let up: Int64
    public let down: Int64
    public init(process: String?, up: Int64, down: Int64) { self.process = process; self.up = up; self.down = down }
    enum CodingKeys: String, CodingKey { case process, up, down }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(process, forKey: .process); try c.encode(up, forKey: .up); try c.encode(down, forKey: .down)
    }
}

public struct ProxyTrafficItem: Codable, Equatable, Hashable, Sendable {
    public let process: String?
    public let src: String?
    public let host: String
    public let rule: String
    public let rulePayload: String
    public let node: String?
    public let group: String?
    public var up: Int64
    public var down: Int64
    public init(process: String?, host: String, rule: String, rulePayload: String = "", node: String?, group: String?, up: Int64 = 0, down: Int64 = 0) {
        self.process = process; src = nil; self.host = host; self.rule = rule; self.rulePayload = rulePayload
        self.node = node; self.group = group; self.up = up; self.down = down
    }
    enum CodingKeys: String, CodingKey { case process, src, host, rule, rulePayload = "rule_payload", node, group, up, down }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(process, forKey: .process); try c.encode(src, forKey: .src)
        try c.encode(host, forKey: .host); try c.encode(rule, forKey: .rule); try c.encode(rulePayload, forKey: .rulePayload)
        try c.encode(node, forKey: .node); try c.encode(group, forKey: .group)
        try c.encode(up, forKey: .up); try c.encode(down, forKey: .down)
    }
    fileprivate var identity: Self { var value = self; value.up = 0; value.down = 0; return value }
    fileprivate var bytes: ProxyTrafficBytes { ProxyTrafficBytes(up: up, down: down) }
}

public struct ProxyTrafficRow: Codable, Equatable, Sendable {
    public let schema: String
    public let source: String
    public let collector: String
    public let hour: String
    public let coverageSeconds: Int64
    public let coreRestarts: Int64
    public let proxy: ProxyTrafficBytes
    public let direct: ProxyTrafficBytes
    public let match: ProxyTrafficBytes
    public let byProcess: [ProxyTrafficProcess]
    public let bySrc: [ProxyTrafficProcess]
    public let items: [ProxyTrafficItem]
    public let other: ProxyTrafficBytes
    public var date: Date? { ProxyTrafficTime.parse(hour) }
    public init(hour: String, coverageSeconds: Int64 = 0, coreRestarts: Int64 = 0,
                proxy: ProxyTrafficBytes = .init(), direct: ProxyTrafficBytes = .init(), match: ProxyTrafficBytes = .init(),
                byProcess: [ProxyTrafficProcess] = [], items: [ProxyTrafficItem] = [], other: ProxyTrafficBytes = .init()) {
        schema = "mihomo-traffic/v1"; source = "mac"; collector = "meowmac/" + AppIdentity.version
        self.hour = hour; self.coverageSeconds = coverageSeconds; self.coreRestarts = coreRestarts
        self.proxy = proxy; self.direct = direct; self.match = match; self.byProcess = byProcess; bySrc = []
        self.items = items; self.other = other
    }
    enum CodingKeys: String, CodingKey {
        case schema, source, collector, hour, coverageSeconds = "coverage_seconds", coreRestarts = "core_restarts"
        case proxy, direct, match, byProcess = "by_process", bySrc = "by_src", items, other
    }
    public static func decode(_ data: Data) throws -> Self {
        try TrafficJSON.validateRow(TrafficJSON.object(data))
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func encoded() throws -> Data {
        let data = try trafficEncode(self)
        try TrafficJSON.validateRow(TrafficJSON.object(data))
        return data
    }
}

public enum ProxyTrafficTime {
    public static func start(_ date: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.dateInterval(of: .hour, for: date)!.start
    }
    public static func hour(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = timeZone
        return formatter.string(from: start(date, timeZone: timeZone))
    }
    public static func parse(_ value: String) -> Date? {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return nil }
        let offset = value.hasSuffix("Z") ? 0 : (Int(value.suffix(5).prefix(2))! * 3600 + Int(value.suffix(2))! * 60) * (value.suffix(6).first == "-" ? -1 : 1)
        guard abs(offset) < 86400, let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        formatter.timeZone = zone
        let normalized = formatter.string(from: date)
        return normalized.prefix(19) == value.prefix(19) ? date : nil
    }
    public static func day(_ hour: String) -> String? { parse(hour) == nil ? nil : String(hour.prefix(10)) }
}

public struct ProxyTrafficSnapshot {
    fileprivate let connections: [String: TrafficConnection]
    fileprivate let totals: ProxyTrafficBytes
    public var connectionCount: Int { connections.count }
    public static func parse(_ data: Data) throws -> Self {
        let root = try TrafficJSON.object(data)
        guard let connections = root["connections"] as? [Any] else { throw ProxyTrafficError.invalidSnapshot }
        let totals = ProxyTrafficBytes(up: try TrafficJSON.integer(root["uploadTotal"]), down: try TrafficJSON.integer(root["downloadTotal"]))
        var current: [String: TrafficConnection] = [:]
        for raw in connections {
            guard let value = raw as? [String: Any], let id = value["id"] as? String, !id.isEmpty, current[id] == nil else { throw ProxyTrafficError.invalidSnapshot }
            let bytes = ProxyTrafficBytes(up: try TrafficJSON.integer(value["upload"]), down: try TrafficJSON.integer(value["download"]))
            let meta: [String: Any]
            if value["metadata"] == nil || value["metadata"] is NSNull { meta = [:] }
            else if let object = value["metadata"] as? [String: Any] { meta = object }
            else { throw ProxyTrafficError.invalidSnapshot }
            let chains: [Any]
            if value["chains"] == nil || value["chains"] is NSNull { chains = [] }
            else if let array = value["chains"] as? [Any] { chains = array }
            else { throw ProxyTrafficError.invalidSnapshot }
            guard chains.allSatisfy({ $0 is String }) else { throw ProxyTrafficError.invalidSnapshot }
            let process = try TrafficJSON.optionalString(meta["process"])
            let host = try TrafficJSON.optionalString(meta["host"]) ?? TrafficJSON.optionalString(meta["destinationIP"]) ?? ""
            let item = ProxyTrafficItem(process: process, host: host, rule: try TrafficJSON.optionalString(value["rule"]) ?? "",
                rulePayload: try TrafficJSON.optionalString(value["rulePayload"]) ?? "", node: chains.first as? String, group: chains.last as? String)
            current[id] = TrafficConnection(bytes: bytes, info: item)
        }
        return Self(connections: current, totals: totals)
    }
}

private struct TrafficConnection: Codable { var bytes: ProxyTrafficBytes; var info: ProxyTrafficItem }
private struct TrafficBucket: Codable {
    var coverage = 0.0
    var coreRestarts: Int64 = 0
    var proxy = ProxyTrafficBytes()
    var direct = ProxyTrafficBytes()
    var match = ProxyTrafficBytes()
    var details: [ProxyTrafficItem] = []
    func row(hour: String) throws -> ProxyTrafficRow {
        let entries = details.sorted { a, b in
            a.bytes.size == b.bytes.size ? trafficItemKey(a) < trafficItemKey(b) : a.bytes.size > b.bytes.size
        }
        var processes: [String?: ProxyTrafficBytes] = [:]
        for item in entries { try processes[item.process, default: .init()].add(item.bytes) }
        let ranking = processes.map { ProxyTrafficProcess(process: $0.key, up: $0.value.up, down: $0.value.down) }.sorted {
            let a = ProxyTrafficBytes(up: $0.up, down: $0.down).size, b = ProxyTrafficBytes(up: $1.up, down: $1.down).size
            return a == b ? ($0.process ?? "") < ($1.process ?? "") : a > b
        }
        var other = ProxyTrafficBytes()
        for item in entries.dropFirst(100) { try other.add(item.bytes) }
        return ProxyTrafficRow(hour: hour, coverageSeconds: Int64(coverage), coreRestarts: coreRestarts,
            proxy: proxy, direct: direct, match: match, byProcess: ranking, items: Array(entries.prefix(100)), other: other)
    }
}
private struct TrafficCheckpoint: Codable {
    let version: Int
    let source: String
    let last: [String: TrafficConnection]
    let totals: ProxyTrafficBytes?
    let buckets: [String: TrafficBucket]
    enum CodingKeys: String, CodingKey { case version, source, last, totals, buckets }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(source, forKey: .source); try c.encode(last, forKey: .last)
        try c.encode(totals, forKey: .totals); try c.encode(buckets, forKey: .buckets)
    }
}

/// 只保留未结算的小时。调用方负责先保存检查点、写出成功后再 remove。
public struct ProxyTrafficAccumulator {
    private var last: [String: TrafficConnection] = [:]
    private var totals: ProxyTrafficBytes?
    private var buckets: [String: TrafficBucket] = [:]
    private var first = true
    private var previousSuccess: Date?
    private let timeZone: TimeZone
    public init(timeZone: TimeZone = .current) { self.timeZone = timeZone }
    public init(checkpoint: Data, timeZone: TimeZone = .current) throws {
        try TrafficJSON.validateCheckpoint(TrafficJSON.object(checkpoint))
        let state = try JSONDecoder().decode(TrafficCheckpoint.self, from: checkpoint)
        self.timeZone = timeZone; last = state.last; totals = state.totals; buckets = state.buckets
        // 恢复后的首个成功样本只接上已知连接，不覆盖停机期间。
        first = true; previousSuccess = nil
        for (hour, bucket) in buckets { _ = try bucket.row(hour: hour).encoded() }
    }
    public mutating func accept(_ snapshot: ProxyTrafficSnapshot, at date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw ProxyTrafficError.invalidSnapshot }
        var next = self
        try next.acceptValidated(snapshot, at: date)
        self = next
    }
    private mutating func acceptValidated(_ snapshot: ProxyTrafficSnapshot, at date: Date) throws {
        let hour = ProxyTrafficTime.hour(date, timeZone: timeZone)
        var bucket = buckets[hour] ?? TrafficBucket()
        let restarted = totals.map { snapshot.totals.up < $0.up || snapshot.totals.down < $0.down } ?? false
        if restarted { last = [:]; bucket.coreRestarts = try trafficSum(bucket.coreRestarts, 1) }
        for (id, value) in snapshot.connections {
            let old = last[id]
            if old == nil && first && !restarted { continue }
            let bytes = ProxyTrafficBytes(up: old.map { value.bytes.up >= $0.bytes.up ? value.bytes.up - $0.bytes.up : value.bytes.up } ?? value.bytes.up,
                down: old.map { value.bytes.down >= $0.bytes.down ? value.bytes.down - $0.bytes.down : value.bytes.down } ?? value.bytes.down)
            if value.info.node == "REJECT" { continue }
            if value.info.node == "DIRECT" { try bucket.direct.add(bytes); continue }
            try bucket.proxy.add(bytes)
            if value.info.rule == "Match" { try bucket.match.add(bytes) }
            if let index = bucket.details.firstIndex(where: { $0.identity == value.info.identity }) {
                bucket.details[index].up = try trafficSum(bucket.details[index].up, bytes.up)
                bucket.details[index].down = try trafficSum(bucket.details[index].down, bytes.down)
            } else {
                var item = value.info; item.up = bytes.up; item.down = bytes.down; bucket.details.append(item)
            }
        }
        buckets[hour] = bucket
        addCoverage(until: date)
        last = snapshot.connections; totals = snapshot.totals; first = false; previousSuccess = date
    }
    private mutating func addCoverage(until date: Date) {
        guard let previousSuccess, date > previousSuccess else { return }
        let elapsed = date.timeIntervalSince(previousSuccess), ratio = min(elapsed, 10) / elapsed
        var cursor = previousSuccess
        while cursor < date {
            let hour = ProxyTrafficTime.hour(cursor, timeZone: timeZone)
            let stop = min(date, ProxyTrafficTime.start(cursor, timeZone: timeZone).addingTimeInterval(3600))
            var bucket = buckets[hour] ?? TrafficBucket()
            bucket.coverage = min(3600, bucket.coverage + stop.timeIntervalSince(cursor) * ratio)
            buckets[hour] = bucket; cursor = stop
        }
    }
    public mutating func interruptCoverage() { previousSuccess = nil }
    public mutating func remove(hour: String) { buckets.removeValue(forKey: hour) }
    public func checkpoint() throws -> Data {
        let data = try trafficEncode(TrafficCheckpoint(version: 1, source: "mac", last: last, totals: totals, buckets: buckets))
        try TrafficJSON.validateCheckpoint(TrafficJSON.object(data))
        return data
    }
    public func rows() throws -> [ProxyTrafficRow] {
        try buckets.map { try $0.value.row(hour: $0.key) }.sorted { $0.date! < $1.date! }
    }
}

private func trafficSum(_ a: Int64, _ b: Int64) throws -> Int64 {
    guard a >= 0, b >= 0 else { throw ProxyTrafficError.invalidRow }
    let value = a.addingReportingOverflow(b)
    guard !value.overflow else { throw ProxyTrafficError.overflow }
    return value.partialValue
}
private func trafficEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
private func trafficItemKey(_ value: ProxyTrafficItem) -> String { String(data: try! trafficEncode(value.identity), encoding: .utf8)! }

private enum TrafficJSON {
    static let rowKeys: Set<String> = ["schema", "source", "collector", "hour", "coverage_seconds", "core_restarts", "proxy", "direct", "match", "by_process", "by_src", "items", "other"]
    static let detailKeys: Set<String> = ["process", "src", "host", "rule", "rule_payload", "node", "group", "up", "down"]
    static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ProxyTrafficError.invalidJSON }
        return root
    }
    static func integer(_ value: Any?) throws -> Int64 {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              let result = Int64(number.stringValue), result >= 0 else { throw ProxyTrafficError.invalidRow }
        return result
    }
    static func optionalString(_ value: Any?) throws -> String? {
        if value == nil || value is NSNull { return nil }
        guard let text = value as? String else { throw ProxyTrafficError.invalidSnapshot }
        return text.isEmpty ? nil : text
    }
    static func keys(_ value: [String: Any], _ expected: Set<String>) throws {
        guard Set(value.keys) == expected else { throw ProxyTrafficError.invalidRow }
    }
    static func pair(_ raw: Any?) throws -> ProxyTrafficBytes {
        guard let value = raw as? [String: Any] else { throw ProxyTrafficError.invalidRow }
        try keys(value, ["up", "down"])
        return ProxyTrafficBytes(up: try integer(value["up"]), down: try integer(value["down"]))
    }
    static func detail(_ raw: Any?) throws -> ProxyTrafficItem {
        guard let value = raw as? [String: Any] else { throw ProxyTrafficError.invalidRow }
        try keys(value, detailKeys)
        for key in ["process", "src", "node", "group"] {
            guard value[key] is String || value[key] is NSNull else { throw ProxyTrafficError.invalidRow }
        }
        guard value["src"] is NSNull, let host = value["host"] as? String, let rule = value["rule"] as? String,
              let payload = value["rule_payload"] as? String else { throw ProxyTrafficError.invalidRow }
        return ProxyTrafficItem(process: value["process"] as? String, host: host, rule: rule, rulePayload: payload,
            node: value["node"] as? String, group: value["group"] as? String, up: try integer(value["up"]), down: try integer(value["down"]))
    }
    static func validateRow(_ row: [String: Any]) throws {
        try keys(row, rowKeys)
        guard row["schema"] as? String == "mihomo-traffic/v1", row["source"] as? String == "mac",
              let collector = row["collector"] as? String, !collector.isEmpty,
              let hour = row["hour"] as? String, ProxyTrafficTime.parse(hour) != nil,
              try integer(row["coverage_seconds"]) <= 3600,
              let rawItems = row["items"] as? [Any], rawItems.count <= 100,
              let processes = row["by_process"] as? [[String: Any]], let src = row["by_src"] as? [Any], src.isEmpty else { throw ProxyTrafficError.invalidRow }
        _ = try integer(row["core_restarts"])
        let proxy = try pair(row["proxy"]), match = try pair(row["match"]), other = try pair(row["other"])
        _ = try pair(row["direct"])
        var itemsTotal = ProxyTrafficBytes(), processTotal = ProxyTrafficBytes()
        var identities: Set<ProxyTrafficItem> = [], prior = UInt64.max
        for raw in rawItems {
            let item = try detail(raw)
            guard identities.insert(item.identity).inserted, item.bytes.size <= prior else { throw ProxyTrafficError.invalidRow }
            prior = item.bytes.size; try itemsTotal.add(item.bytes)
        }
        try itemsTotal.add(other)
        var processIDs: Set<String?> = []; prior = UInt64.max
        for value in processes {
            try keys(value, ["process", "up", "down"])
            guard value["process"] is String || value["process"] is NSNull else { throw ProxyTrafficError.invalidRow }
            let bytes = ProxyTrafficBytes(up: try integer(value["up"]), down: try integer(value["down"]))
            guard processIDs.insert(value["process"] as? String).inserted, bytes.size <= prior else { throw ProxyTrafficError.invalidRow }
            prior = bytes.size; try processTotal.add(bytes)
        }
        guard proxy == itemsTotal, proxy == processTotal, match.up <= proxy.up, match.down <= proxy.down else { throw ProxyTrafficError.invalidRow }
    }
    static func validateCheckpoint(_ state: [String: Any]) throws {
        try keys(state, ["version", "source", "last", "totals", "buckets"])
        guard try integer(state["version"]) == 1, state["source"] as? String == "mac",
              let last = state["last"] as? [String: Any], let buckets = state["buckets"] as? [String: Any] else { throw ProxyTrafficError.invalidCheckpoint }
        if !(state["totals"] is NSNull) { _ = try pair(state["totals"]) }
        if !last.isEmpty && state["totals"] is NSNull { throw ProxyTrafficError.invalidCheckpoint }
        for (id, raw) in last {
            guard !id.isEmpty, let value = raw as? [String: Any] else { throw ProxyTrafficError.invalidCheckpoint }
            try keys(value, ["bytes", "info"]); _ = try pair(value["bytes"])
            let info = try detail(value["info"])
            guard info.up == 0, info.down == 0 else { throw ProxyTrafficError.invalidCheckpoint }
        }
        for (hour, raw) in buckets {
            guard ProxyTrafficTime.parse(hour) != nil, let value = raw as? [String: Any] else { throw ProxyTrafficError.invalidCheckpoint }
            try keys(value, ["coverage", "coreRestarts", "proxy", "direct", "match", "details"])
            guard let coverage = value["coverage"] as? NSNumber, CFGetTypeID(coverage) != CFBooleanGetTypeID(),
                  coverage.doubleValue.isFinite, (0...3600).contains(coverage.doubleValue), let rawDetails = value["details"] as? [Any] else { throw ProxyTrafficError.invalidCheckpoint }
            var details: [ProxyTrafficItem] = [], identities: Set<ProxyTrafficItem> = [], total = ProxyTrafficBytes()
            for raw in rawDetails {
                let item = try detail(raw)
                guard identities.insert(item.identity).inserted else { throw ProxyTrafficError.invalidCheckpoint }
                details.append(item); try total.add(item.bytes)
            }
            let proxy = try pair(value["proxy"]), match = try pair(value["match"])
            _ = try pair(value["direct"]); _ = try integer(value["coreRestarts"])
            guard total == proxy, match.up <= proxy.up, match.down <= proxy.down else { throw ProxyTrafficError.invalidCheckpoint }
            let matchTotal = try details.filter { $0.rule == "Match" }.reduce(into: ProxyTrafficBytes()) { try $0.add($1.bytes) }
            guard matchTotal == match, details.allSatisfy({ $0.node != "DIRECT" && $0.node != "REJECT" }) else { throw ProxyTrafficError.invalidCheckpoint }
        }
    }
}
