import Foundation

public enum ProxyTrafficRange: String, CaseIterable, Sendable { case today, week }

/// 展示使用 Double，跨小时求和不受 Int64 加法溢出影响；原始行仍按 SCHEMA 保留整数。
public struct ProxyTrafficAmount: Equatable, Sendable {
    public var up: Double = 0
    public var down: Double = 0
    public var total: Double { up + down }
    mutating func add(up: Int64, down: Int64) { self.up += Double(up); self.down += Double(down) }
}

public struct ProxyTrafficNamedAmount: Sendable {
    public let name: String
    public let bytes: Double
}

public struct ProxyTrafficProcessSummary: Sendable, Identifiable {
    public let process: String?
    public let amount: ProxyTrafficAmount
    public let fraction: Double
    public let domains: [ProxyTrafficNamedAmount]
    public let rule: String?
    public let node: String?
    public var id: String { process.map { "process:" + $0 } ?? "unknown" }
    public var name: String { process ?? "未知进程" }
    public var hasDetails: Bool { !domains.isEmpty }
}

public struct ProxyTrafficBar: Sendable, Identifiable {
    public let date: Date
    public let end: Date
    public let amount: ProxyTrafficAmount
    public let recorded: Bool
    public let ongoing: Bool
    public let largestProcess: String?
    public var id: Date { date }
}

public struct ProxyTrafficSummary: Sendable {
    public let proxy: ProxyTrafficAmount
    public let direct: ProxyTrafficAmount
    public let match: ProxyTrafficAmount
    public let other: ProxyTrafficAmount
    public let bars: [ProxyTrafficBar]
    public let processes: [ProxyTrafficProcessSummary]
    public var proxyFraction: Double { fraction(proxy.total, of: proxy.total + direct.total) }
    public var matchFraction: Double { fraction(match.total, of: proxy.total) }
    public var matchWarning: Bool { matchFraction >= 0.3 }
    public var chartMaximum: Double { max(1, (bars.map { $0.amount.total }.max() ?? 0) * 1.15) }

    public init(rows: [ProxyTrafficRow], range: ProxyTrafficRange, now: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let start = range == .today ? today : calendar.date(byAdding: .day, value: -6, to: today)!
        var seen = Set<Date>()
        let selected = rows.filter {
            guard let date = $0.date, date >= start, date <= now else { return false }
            return seen.insert(date).inserted
        }
        var proxy = ProxyTrafficAmount(), direct = ProxyTrafficAmount(), match = ProxyTrafficAmount(), other = ProxyTrafficAmount()
        var ranking: [String?: ProxyTrafficAmount] = [:]
        for row in selected {
            proxy.add(up: row.proxy.up, down: row.proxy.down)
            direct.add(up: row.direct.up, down: row.direct.down)
            match.add(up: row.match.up, down: row.match.down)
            other.add(up: row.other.up, down: row.other.down)
            for process in row.byProcess { ranking[process.process, default: .init()].add(up: process.up, down: process.down) }
        }
        self.proxy = proxy; self.direct = direct; self.match = match; self.other = other
        processes = Self.sorted(ranking).prefix(5).map { process, amount in
            var domains: [String: Double] = [:], rules: [String: Double] = [:], nodes: [String: Double] = [:]
            for row in selected {
                for item in row.items where item.process == process {
                    let bytes = Double(item.up) + Double(item.down)
                    guard bytes > 0 else { continue }
                    domains[item.host.isEmpty ? "未知域名" : item.host, default: 0] += bytes
                    let rule = (item.rule.isEmpty ? "未知规则" : item.rule)
                        + (item.rulePayload.isEmpty ? "" : " · " + item.rulePayload)
                        + (item.group.map { " → " + $0 } ?? "")
                    rules[rule, default: 0] += bytes
                    nodes[item.node ?? "未知节点", default: 0] += bytes
                }
            }
            return ProxyTrafficProcessSummary(process: process, amount: amount, fraction: fraction(amount.total, of: proxy.total),
                domains: Self.named(domains).prefix(5).map { $0 }, rule: Self.named(rules).first?.name, node: Self.named(nodes).first?.name)
        }
        let count = range == .today ? 24 : 7
        bars = (0..<count).map { index in
            let component: Calendar.Component = range == .today ? .hour : .day
            let date = calendar.date(byAdding: component, value: index, to: start)!
            let end = calendar.date(byAdding: component, value: 1, to: date)!
            let bucket = selected.filter { ($0.date ?? .distantPast) >= date && ($0.date ?? .distantFuture) < end }
            var amount = ProxyTrafficAmount(), processes: [String?: ProxyTrafficAmount] = [:]
            for row in bucket {
                amount.add(up: row.proxy.up, down: row.proxy.down)
                for process in row.byProcess { processes[process.process, default: .init()].add(up: process.up, down: process.down) }
            }
            let largest = Self.sorted(processes).first
            return ProxyTrafficBar(date: date, end: end, amount: amount, recorded: !bucket.isEmpty,
                ongoing: now >= date && now < end, largestProcess: largest.map { $0.0 ?? "未知进程" })
        }
    }
    private static func sorted(_ values: [String?: ProxyTrafficAmount]) -> [(String?, ProxyTrafficAmount)] {
        values.filter { $0.value.total > 0 }.sorted {
            $0.value.total == $1.value.total ? ($0.key ?? "") < ($1.key ?? "") : $0.value.total > $1.value.total
        }.map { ($0.key, $0.value) }
    }
    private static func named(_ values: [String: Double]) -> [ProxyTrafficNamedAmount] {
        values.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ProxyTrafficNamedAmount(name: $0.key, bytes: $0.value) }
    }
}

private func fraction(_ value: Double, of total: Double) -> Double { total > 0 ? min(1, value / total) : 0 }

public enum ProxyTrafficFormat {
    public static func parts(_ bytes: Double) -> (value: String, unit: String) {
        if bytes < 1_048_576 { return (String(format: "%.0f", bytes / 1024), "KB") }
        if bytes < 1_073_741_824 { return (String(format: "%.1f", bytes / 1_048_576), "MB") }
        return (String(format: "%.2f", bytes / 1_073_741_824), "GB")
    }
    public static func bytes(_ bytes: Double) -> String { let p = parts(bytes); return p.value + " " + p.unit }
    public static func percent(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }
}
