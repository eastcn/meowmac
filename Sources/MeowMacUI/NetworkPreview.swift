import Foundation
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
}
