import Foundation
import MeowMacCore
import TunCanaryCore
import TunCanaryUI

private struct PreviewEgressChecker: EgressIPChecking {
    let now: Date
    func check(targets: [EgressIPTarget]) async -> [EgressIPResult] {
        targets.enumerated().map { index, target in
            EgressIPResult(target: target, checkedAt: now, ip: "203.0.113.\(10 + index)", ipVersion: .ipv4, location: "示例地区", failure: nil)
        }
    }
}
public extension PanelPreviewRenderer {
    static func networkModel(failure: Bool, now: Date) -> AppModel {
        let names = ["代理 TUN", "VPN", "主网络 DNS", "代理 DNS", "Tailnet"]
        let details = ["隧道运行中", "未连接，DNS 已恢复", "DNS 走代理", "解析正常", "子网目标可达"]
        let cards = StatusCardKind.displayOrder.enumerated().map { index, kind in
            StatusCard(kind: kind, title: names[index], severity: failure && kind == .primaryDNS ? .critical : .ok,
                conclusion: failure && kind == .primaryDNS ? "DNS 与预期不一致" : details[index])
        }
        let local = LocalAssessment(severity: failure ? .critical : .ok, cards: cards, faults: [], primaryReason: "示例",
            tunState: .running(interface: "示例隧道"), vpnState: .disconnected, isInGracePeriod: false, intranetProbeEnabled: true,
            primaryServiceName: "Wi-Fi", mihomoDNSPort: nil, diagnosticNotes: [], evaluatedAt: now)
        let model = AppModel(local: local, lastCheckedAt: now.addingTimeInterval(-60), now: { now }, egressChecker: PreviewEgressChecker(now: now))
        model.overall = OverallAssessment(local: local, connectivityFaults: [])
        model.settings.egressTargets = [.cloudflare, .chatgpt, .claude]
        for (index, group) in [SiteGroup.mainland, .overseas, .tailnet].enumerated() {
            for target in 0..<(index == 2 ? 2 : 3) {
                let site = Site(id: "example-\(index)-\(target)", name: "示例目标", group: group, url: URL(string: "https://example.com")!, isKey: false, inLightProbe: true)
                for round in 0..<5 {
                    let category: ProbeCategory = failure && index == 1 && target == 0 ? .timeout : .reachable
                    model.siteHistory.record(SiteResult(site: site, category: category, medianLatency: category == .reachable ? [0.025, 0.184, 0.035][index] : nil, attempts: [], checkedAt: now.addingTimeInterval(Double(round - 4) * 60)))
                }
            }
        }
        return model
    }

    /// 网络页的五种合成状态，对照 mockups/network-redesign.html。
    enum NetworkPreview: String, CaseIterable {
        case normal, warn, severe, day, fresh
    }

    /// 只替换网络模型和网络历史，其余沿用正常合成状态。数据全部虚构，IP 只用文档保留段。
    static func networkState(_ variant: NetworkPreview) -> PanelState {
        let state = syntheticState()
        let now = state.now()
        var seed: UInt64 = 11
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }

        // 连接检查。
        let base: [(StatusCardKind, String, Severity, String, String?, FaultKey?)] = [
            (.proxyTun, "代理 TUN", .ok, "配置开启，utun 接口存在", nil, nil),
            (.vpn, "VPN", .ok, "已断开，符合预期", nil, nil),
            (.primaryDNS, "主网络 DNS", .ok, "DNS 为 192.0.2.53，符合预期", nil, nil),
            (.proxyDNS, "代理 DNS", .ok, "7874 端口响应 8 ms", nil, nil),
            (.tailnet, "Tailnet", .unknown, "与子网网段相同，不探测", nil, nil),
        ]
        var rows = base
        var events: [FaultEvent] = [FaultEvent(date: now.addingTimeInterval(-86400 * 2), kind: .started)]
        switch variant {
        case .warn:
            rows[3] = (.proxyDNS, "代理 DNS", .warning, "7874 端口响应超过 1.5 秒", "代理负载过高或上游 DNS 变慢；持续 15 分钟会转为失败", .mihomoNoResponse)
            events.append(FaultEvent(date: now.addingTimeInterval(-480), kind: .appeared, key: .mihomoNoResponse, severity: .warning, message: "代理 DNS 响应慢"))
        case .severe:
            rows[0] = (.proxyTun, "代理 TUN", .critical, "配置开启，但 utun 接口不存在", "在代理客户端里关闭再开启 TUN 模式", .tunInactive)
            rows[3] = (.proxyDNS, "代理 DNS", .unknown, "TUN 失效，无法确认", nil, nil)
            events.append(FaultEvent(date: now.addingTimeInterval(-720), kind: .appeared, key: .tunInactive, severity: .critical, message: "TUN 失效"))
        case .day:
            events += [
                FaultEvent(date: now.addingTimeInterval(-62000), kind: .appeared, key: .tunInactive, severity: .critical, message: "TUN 失效"),
                FaultEvent(date: now.addingTimeInterval(-61820), kind: .cleared, key: .tunInactive, severity: .critical, message: "TUN 失效"),
                FaultEvent(date: now.addingTimeInterval(-28000), kind: .appeared, key: .mihomoNoResponse, severity: .warning, message: "代理 DNS 响应慢"),
                FaultEvent(date: now.addingTimeInterval(-27280), kind: .cleared, key: .mihomoNoResponse, severity: .warning, message: "代理 DNS 响应慢"),
            ]
        default: break
        }
        let cards = rows.map { kind, title, severity, conclusion, hint, key in
            StatusCard(kind: kind, title: title, severity: severity, conclusion: conclusion, hint: hint,
                       evidence: ["示例证据：最近一次检查 " + DisplayDate.format(now.addingTimeInterval(-20), pattern: "HH:mm:ss")], faultKey: key)
        }
        let severity: Severity = variant == .severe ? .critical : variant == .warn ? .warning : .ok
        let local = LocalAssessment(severity: severity, cards: cards, faults: [], primaryReason: rows.first { $0.2 == severity }?.3 ?? "示例",
            tunState: .running(interface: "示例隧道"), vpnState: .disconnected, isInGracePeriod: false, intranetProbeEnabled: true,
            primaryServiceName: "Wi-Fi", mihomoDNSPort: nil, diagnosticNotes: [], evaluatedAt: now)

        // 出口历史：两个目标，30 天里各变过几次。
        var egress = EgressMonitorState()
        let targets: [(EgressIPTarget, [(String, String, String, Double)])] = [
            (.cloudflare, [("2001:db8:aa00:1::27", "JP", "Tokyo", 30), ("198.51.100.17", "SG", "Singapore", 17.4), ("2001:db8:d002:0:188:253:121:92", "SG", "Central Singapore", 3)]),
            (.claude, variant == .warn
                ? [("203.0.113.14", "JP", "Tokyo", 30), ("198.51.100.27", "JP", "Osaka", 20.0 / 1440)]
                : [("192.0.2.86", "US", "Los Angeles", 30), ("203.0.113.14", "JP", "Tokyo", 12)]),
        ]
        for (target, spans) in targets {
            for (index, span) in spans.enumerated() {
                let begin = now.addingTimeInterval(-span.3 * 86400 + 60)
                let finish = index + 1 < spans.count ? now.addingTimeInterval(-spans[index + 1].3 * 86400) : now
                var time = begin
                while time < finish {
                    let result = EgressIPResult(target: target, checkedAt: time, ip: span.0, ipVersion: span.0.contains(":") ? .ipv6 : .ipv4, location: span.1, failure: nil)
                    egress.history.append(EgressObservation(result: result, geo: EgressGeo(ip: span.0, countryCode: span.1, city: span.2, checkedAt: time)))
                    time = time.addingTimeInterval(300)
                }
            }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("meowmac-preview-\(UUID().uuidString).json")
        let store = EgressHistoryStore(fileURL: file)
        _ = store.save(egress)
        let model = AppModel(local: local, lastCheckedAt: now.addingTimeInterval(-20), now: { now }, egressChecker: PreviewEgressChecker(now: now), egressHistoryStore: store)
        try? FileManager.default.removeItem(at: file)
        model.overall = OverallAssessment(local: local, connectivityFaults: [])
        model.settings.egressTargets = [.cloudflare, .claude]
        model.recentEvents = events

        // 站点：最新一轮写进 TunCanary 的站点历史，过往轮次写进 MeowMac 的网络历史。
        let rounds = variant == .day ? 720 : variant == .fresh ? 4 : 30
        let gap = variant == .day ? 345..<375 : 0..<0
        var history = NetworkHistory(startedAt: variant == .fresh ? now.addingTimeInterval(-420) : now.addingTimeInterval(-86400 * 2))
        let siteGroups: [(SiteGroup, NetworkSiteGroup, Int, Double)] = [(.mainland, .mainland, 3, 88), (.overseas, .overseas, 4, 320)]
        for round in 0..<rounds where !gap.contains(round) {
            let time = now.addingTimeInterval(Double(round - rounds + 1) * 120)
            var records: [SiteRoundRecord] = []
            for (_, group, count, latency) in siteGroups {
                var passed = count
                var value = latency * (1 + 0.3 * noise())
                if group == .overseas {
                    if variant == .normal && round == 17 || variant == .day && round == 500 { passed = count - 1 }
                    if variant == .severe && round >= rounds - 6 { passed = 0 }
                    if variant == .warn && round >= rounds - 4 { value = 900 * (1 + 0.1 * noise()) }
                    if variant == .day && (200..<215).contains(round) { value += 450 }
                }
                records.append(SiteRoundRecord(sampledAt: time, group: group, passed: passed, total: count, medianMilliseconds: passed == 0 ? nil : value))
            }
            records.append(SiteRoundRecord(sampledAt: time, group: .subnet, passed: 0, total: 0, medianMilliseconds: nil))
            history.append(sites: records, now: now)
        }
        for (siteGroup, group, count, _) in siteGroups {
            let latest = history.sites.last { $0.group == group }!
            for index in 0..<count {
                let site = Site(id: "example-\(group.rawValue)-\(index)", name: "示例目标", group: siteGroup, url: URL(string: "https://example.com")!, isKey: false, inLightProbe: true)
                let ok = index < latest.passed
                model.siteHistory.record(SiteResult(site: site, category: ok ? .reachable : .timeout,
                    medianLatency: ok ? (latest.medianMilliseconds ?? 0) / 1000 : nil, attempts: [], checkedAt: latest.sampledAt))
            }
        }

        // 速率：30 秒一条；24 小时视图与站点同一段空档。
        let samples = variant == .day ? 2880 : variant == .fresh ? 14 : 120
        for index in 0..<samples where !(variant == .day && (1380..<1500).contains(index)) {
            let time = now.addingTimeInterval(Double(index - samples + 1) * 30)
            let burst = [24, 84, 1100, 2300].contains { abs(index - $0) < 3 } ? 4.0 * 1024 * 1024 : 0
            let received = 300 * 1024 * (1 + 0.8 * noise()) + burst
            let sent = 60 * 1024 * (1 + 0.8 * noise()) + burst / 6
            history.append(traffic: TrafficRecord(sampledAt: time, receivedAverage: received, sentAverage: sent,
                                                  receivedPeak: received * 1.6, sentPeak: sent * 1.6), now: now)
        }
        state.networkModel = model
        state.networkHistory = history
        state.networkRange = variant == .day ? .day : .hour
        state.networkTone = variant == .severe ? .red : variant == .warn ? .yellow : .green
        state.selectedTab = .network
        return state
    }

    /// 展开的网络页整页，用于逐张对照 network-redesign.html；材质沿用预览退路。
    static func networkPagePNG(state: PanelState, dark: Bool) -> Data? {
        state.selectedTab = .network
        return png(state: state, dark: dark)
    }
}
