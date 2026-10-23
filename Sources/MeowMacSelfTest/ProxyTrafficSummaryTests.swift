import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum ProxyTrafficSummaryTests {
    static let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    static let now = ProxyTrafficTime.parse("2026-10-13T17:30:00+08:00")!
    static let tests: [(String, @MainActor () -> Bool)] = [
        ("ProxyTraffic.Card/跨小时合计、占比与完整进程排名反例", ranking),
        ("ProxyTraffic.Card/明细跨小时合并、Top5、规则节点与遗漏", details),
        ("ProxyTraffic.Card/今天24小时、七天7桶、当前与无记录", bars),
        ("ProxyTraffic.Card/单位边界与MATCH颜色阈值", units),
        ("ProxyTraffic.Card/代理块独立于网络模型且可隐藏", availability),
        ("ProxyTraffic.Card/汇总缓存随数据、范围和小时失效", cache),
        ("ProxyTraffic.Layout/只缺代理块与重复未知缺项负控", migration),
    ]

    static func row(hour: String, processes: [(String?, Int64, Int64)], items: [ProxyTrafficItem] = [],
                    direct: ProxyTrafficBytes = .init(), match: ProxyTrafficBytes = .init()) -> ProxyTrafficRow {
        let up = processes.reduce(Int64(0)) { $0 + $1.1 }, down = processes.reduce(Int64(0)) { $0 + $1.2 }
        return ProxyTrafficRow(hour: hour, coverageSeconds: 3000, proxy: .init(up: up, down: down), direct: direct, match: match,
            byProcess: processes.sorted { $0.1 + $0.2 > $1.1 + $1.2 }.map { .init(process: $0.0, up: $0.1, down: $0.2) }, items: items,
            other: .init(up: up - items.reduce(0) { $0 + $1.up }, down: down - items.reduce(0) { $0 + $1.down }))
    }
    static func ranking() -> Bool {
        let item = ProxyTrafficItem(process: "DemoA", host: "a.example.com", rule: "Match", node: "DemoNode", group: "DemoGroup", up: 10100)
        let first = row(hour: "2026-10-13T15:00:00+08:00", processes: [("DemoB", 10200, 0), ("DemoA", 10100, 0)], items: [item],
            direct: .init(up: 1000, down: 300), match: .init(up: 20300))
        let second = row(hour: "2026-10-13T16:00:00+08:00", processes: [("DemoA", 200, 300), (nil, 0, 100)], direct: .init(down: 100))
        guard (try? first.encoded()) != nil, (try? second.encoded()) != nil else { return false }
        let s = ProxyTrafficSummary(rows: [first, second, first], range: .today, now: now, timeZone: zone)
        guard s.proxy.up == 20500, s.proxy.down == 400, s.direct.total == 1400,
              abs(s.proxyFraction - 20900.0 / 22300) < 1e-9,
              s.processes.map(\.name) == ["DemoA", "DemoB", "未知进程"],
              s.processes[0].amount.total == 10600, s.processes[1].hasDetails == false else { return false }
        // 单小时里完整排名是 B > A，但保留明细只能看到 A。
        let counterexample = ProxyTrafficSummary(rows: [first], range: .today, now: now, timeZone: zone)
        return counterexample.processes.first?.name == "DemoB" && counterexample.other.total == 10200
            && counterexample.processes.first?.hasDetails == false
    }
    static func details() -> Bool {
        var items: [ProxyTrafficItem] = []
        for i in 0..<7 {
            let rule = i == 0 ? "Match" : "DomainSuffix"
            let payload = i == 0 ? "" : "example.com"
            let node = i == 0 ? "DemoOther" : "DemoNode"
            items.append(ProxyTrafficItem(process: "DemoBrowser", host: "\(i).example.com", rule: rule,
                rulePayload: payload, node: node, group: "DemoGroup", down: Int64(70 - i * 10)))
        }
        let a = row(hour: "2026-10-13T15:00:00+08:00", processes: [("DemoBrowser", 0, 300)], items: items)
        let b = row(hour: "2026-10-13T16:00:00+08:00", processes: [("DemoBrowser", 0, 120)], items: [items[0]])
        let s = ProxyTrafficSummary(rows: [a, b], range: .today, now: now, timeZone: zone), p = s.processes[0]
        return p.domains.count == 5 && p.domains[0].name == "0.example.com" && p.domains[0].bytes == 140
            && p.domains[4].name == "4.example.com" && p.rule == "DomainSuffix · example.com → DemoGroup"
            && p.node == "DemoNode" && s.other.total == 70
    }
    static func bars() -> Bool {
        let old = row(hour: "2026-10-07T15:00:00+08:00", processes: [("DemoOld", 0, 100)])
        let a = row(hour: "2026-10-13T16:00:00+08:00", processes: [("DemoA", 20, 80)])
        let current = row(hour: "2026-10-13T17:00:00+08:00", processes: [("DemoCurrent", 0, 300)])
        let future = row(hour: "2026-10-13T18:00:00+08:00", processes: [("DemoFuture", 0, 900)])
        let outside = row(hour: "2026-10-06T23:00:00+08:00", processes: [("DemoOutside", 0, 900)])
        let today = ProxyTrafficSummary(rows: [old, a, current, future, outside], range: .today, now: now, timeZone: zone)
        let week = ProxyTrafficSummary(rows: [old, a, current, future, outside], range: .week, now: now, timeZone: zone)
        return today.bars.count == 24 && today.proxy.total == 400 && !today.bars[15].recorded
            && today.bars[16].recorded && today.bars[17].ongoing && !today.bars[18].recorded
            && today.bars[17].largestProcess == "DemoCurrent" && today.chartMaximum == 345
            && week.bars.count == 7 && week.bars[0].amount.total == 100 && !week.bars[1].recorded
            && week.bars[6].ongoing && week.bars[6].largestProcess == "DemoCurrent" && week.proxy.total == 500
    }
    static func units() -> Bool {
        func s(_ value: Int64) -> ProxyTrafficSummary {
            ProxyTrafficSummary(rows: [row(hour: "2026-10-13T15:00:00+08:00", processes: [("Demo", 0, 100)], match: .init(down: value))],
                range: .today, now: now, timeZone: zone)
        }
        return ProxyTrafficFormat.bytes(1023 * 1024) == "1023 KB" && ProxyTrafficFormat.bytes(1048576) == "1.0 MB"
            && ProxyTrafficFormat.bytes(1073741824) == "1.00 GB" && ProxyTrafficFormat.bytes(0) == "0 KB"
            && !s(29).matchWarning && s(30).matchWarning && s(31).matchWarning
    }
    static func availability() -> Bool {
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        guard state.networkModel == nil, state.renderedCardIDs(for: .network) == ["network.proxy"] else { return false }
        state.proxyTraffic = ProxyTrafficViewData(enabled: false)
        guard state.renderedCardIDs(for: .network) == ["network.proxy"] else { return false }
        let root = URL(fileURLWithPath: "build/acceptance/proxy-traffic/layout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        CatRuntime.initialize(state: state, store: CatStore(rootURL: root))
        var layout = state.panelLayout
        layout.cards["network"] = layout.placements(for: .network).map { .init(id: $0.id, visible: $0.id != "network.proxy") }
        do { try state.saveLayout(layout, for: "builtin.slim") } catch { print("布局保存失败：\(error)"); return false }
        return state.renderedCardIDs(for: .network).isEmpty
    }
    static func cache() -> Bool {
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        var clock = ProxyTrafficTime.start(Date()).addingTimeInterval(1800)
        state.now = { clock }
        func current(_ down: Int64) -> ProxyTrafficRow { row(hour: ProxyTrafficTime.hour(clock), processes: [("Demo", 0, down)]) }
        guard let decoded = try? ProxyTrafficRow.decode(current(100).encoded()),
              decoded.date == ProxyTrafficTime.start(clock), decoded == current(100) else { return false }
        state.proxyTraffic = ProxyTrafficViewData(rows: [current(100)], available: true)
        guard state.proxyTrafficSummary().proxy.total == 100 else { return false }
        state.proxyTraffic = ProxyTrafficViewData(rows: [current(300)], available: true)
        let before = state.proxyTrafficSummary()
        guard before.proxy.total == 300, before.bars.count == 24 else { return false }
        state.proxyTrafficRange = .week
        guard state.proxyTrafficSummary().bars.count == 7 else { return false }
        state.proxyTrafficRange = .today
        let ongoing = before.bars.firstIndex(where: \.ongoing)
        clock = clock.addingTimeInterval(3600)
        let after = state.proxyTrafficSummary().bars.firstIndex(where: \.ongoing)
        return ongoing != nil && after != nil && ongoing != after
    }
    static func migration() -> Bool {
        var old = PanelLayout.default
        old.cards["network"] = [.init(id: "network.egress"), .init(id: "network.traffic", visible: false), .init(id: "network.checks"), .init(id: "network.sites", visible: false)]
        guard let loaded = try? PanelLayout.parse(JSONEncoder().encode(old)),
              loaded.placements(for: .network).map(\.id) == ["network.egress", "network.traffic", "network.proxy", "network.checks", "network.sites"],
              loaded.placements(for: .network).map(\.visible) == [true, false, true, true, false] else { return false }
        for missing in ["network.checks", "network.sites", "network.egress"] {
            var invalid = old; invalid.cards["network"]?.removeAll { $0.id == missing }
            if (try? PanelLayout.parse(JSONEncoder().encode(invalid))) != nil { return false }
        }
        var duplicate = old; duplicate.cards["network"]?.append(.init(id: "network.traffic"))
        var unknown = old; unknown.cards["network"]?.append(.init(id: "network.unknown"))
        return (try? PanelLayout.parse(JSONEncoder().encode(duplicate))) == nil
            && (try? PanelLayout.parse(JSONEncoder().encode(unknown))) == nil
    }
}
