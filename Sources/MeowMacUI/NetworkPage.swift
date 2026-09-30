import Foundation
import SwiftUI
import MeowMacCore
import TunCanaryCore
import TunCanaryUI

public struct NetworkCheckDisplay: Codable {
    public let kind: String, name: String, detail: String, status: String
    public let tone: NetworkTone
}
public struct NetworkGroupDisplay: Codable {
    public let name: String
    public let passed: Int, total: Int
    public let medianMilliseconds: Double?
}
public struct NetworkEgressDisplay: Codable {
    public let target: String, ip: String?, region: String?, stability: String, failure: String?
}
public struct NetworkDisplay: Codable {
    public var capture: NetworkCaptureInfo? = nil
    public let tone: NetworkTone
    public let conclusion: String, detail: String
    public let checkedAt: Date?
    public let checks: [NetworkCheckDisplay]
    public let groups: [NetworkGroupDisplay]
    public let egress: [NetworkEgressDisplay]
    public let samplingInterval: TimeInterval
    public let isChecking: Bool
    public var passed: Int { checks.filter { $0.tone == .green }.count }
}
public extension AppModel {
    var meowMacDisplay: NetworkDisplay {
        let names = ["代理 TUN", "VPN", "主网络 DNS", "代理 DNS", "Tailnet"]
        let checks = StatusCardKind.displayOrder.enumerated().map { index, kind in
            let card = cards.first { $0.kind == kind }
            let tone = card.map { NetworkToneMapper.map($0.severity) } ?? .gray
            return NetworkCheckDisplay(kind: kind.rawValue, name: names[index], detail: card?.conclusion ?? "未配置或尚未检测",
                status: tone == .green ? "通过" : tone == .yellow ? "提醒" : tone == .red ? "失败" : "未确认", tone: tone)
        }
        let grouping: [(String, [SiteGroup])] = [("国内", [.mainland]), ("海外", [.overseas]), ("子网目标", [.intranet, .tailnet])]
        let groups = grouping.map { name, included in
            let recent = siteHistory.results.values.filter { rows in rows.last.map { included.contains($0.site.group) } ?? false }
            let latest = recent.compactMap(\.last)
            let latency = SiteAggregator.median(recent.flatMap { $0.suffix(5).compactMap(\.medianLatency) }).map { $0 * 1000 }
            return NetworkGroupDisplay(name: name, passed: latest.filter { !$0.isFailure }.count, total: latest.count, medianMilliseconds: latency)
        }
        let egress = settings.effectiveEgressTargets.map { target in
            let summary = egressSummary(target)
            let result = egressResults.first { $0.target == target } ?? summary.latest?.result
            let region = summary.latest?.geo?.displayName ?? result?.location
            let stability = summary.observedSince.map { date -> String in
                let days = max(0, Int(now().timeIntervalSince(date) / 86400))
                return days > 0 ? "\(days) 天未变" : MetricFormat.duration(now().timeIntervalSince(date)) + "未变"
            } ?? "等待连续采样"
            return NetworkEgressDisplay(target: target.displayName, ip: result?.ip, region: region, stability: stability, failure: result?.failure?.displayName)
        }
        let tone = NetworkToneMapper.map(overall.severity)
        return NetworkDisplay(tone: tone, conclusion: tone == .green ? "网络正常" : tone == .red ? "网络异常" : tone == .yellow ? "网络提醒" : "网络待确认",
            detail: tone == .green ? "\(checks.filter { $0.tone == .green }.count) 项检查通过" : overall.primaryReason,
            checkedAt: lastCheckedAt, checks: checks, groups: groups, egress: egress,
            samplingInterval: settings.egressMonitoring.effectiveInterval, isChecking: checkProgress != nil)
    }
}
struct NetworkPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let value = model.meowMacDisplay
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            HStack(alignment: .top, spacing: Design.rowGap) {
                ZStack {
                    Circle().fill(Design.networkColor(value.tone))
                    Image(systemName: value.tone == .green ? "checkmark" : value.tone == .red ? "xmark" : "exclamationmark")
                        .font(.system(size: Design.networkIcon * 0.55, weight: .semibold)).foregroundStyle(Design.iconInk)
                }.frame(width: Design.networkIcon, height: Design.networkIcon)
                VStack(alignment: .leading, spacing: Design.smallGap) {
                    Text(value.conclusion).font(Design.status)
                    Text(value.detail).font(Design.caption).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text(DisplayDate.age(value.checkedAt, now: model.now()) + "检测").font(Design.caption).foregroundStyle(Design.secondary)
                Spacer(); CapsuleAction(title: value.isChecking ? "正在检测…" : "立即复测", action: model.recheck).disabled(value.isChecking)
            }
            SectionRule()
            VStack(alignment: .leading, spacing: Design.rowGap) {
                SectionHeading(title: "连接检查", detail: "\(value.passed) / 5 通过")
                ForEach(value.checks.indices, id: \.self) { index in
                    let check = value.checks[index]
                    HStack(alignment: .top, spacing: Design.rowGap) {
                        Circle().fill(Design.networkColor(check.tone)).frame(width: Design.checkDot, height: Design.checkDot).padding(.top, Design.gap)
                        VStack(alignment: .leading, spacing: Design.smallGap) {
                            Text(check.name).font(Design.title)
                            Text(check.detail).font(Design.caption).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Text(check.status).font(Design.caption).foregroundStyle(check.tone == .gray ? Design.secondary : Design.stateText(check.tone == .green ? .normal : check.tone == .red ? .severe : .warn)).fixedSize()
                    }
                }
            }
            SectionRule()
            VStack(alignment: .leading, spacing: Design.gap) {
                SectionHeading(title: "站点连通性", detail: "最近 5 轮")
                HStack { Text("目标分组"); Spacer(); Text("通过").frame(width: Design.siteCountColumn, alignment: .trailing); Text("延迟中位数").frame(width: Design.siteLatencyColumn, alignment: .trailing) }.font(Design.tiny).foregroundStyle(Design.secondary).frame(height: Design.tableHeader)
                ForEach(value.groups.indices, id: \.self) { index in
                    let row = value.groups[index]
                    HStack {
                        Text(row.name); Spacer()
                        Text("\(row.passed) / \(row.total)").foregroundStyle(row.total == 0 ? Design.secondary : Design.stateText(row.passed == row.total ? .normal : .warn)).frame(width: Design.siteCountColumn, alignment: .trailing)
                        HStack(spacing: Design.smallGap) { Text(row.medianMilliseconds.map { String(format: "%.0f", $0) } ?? "—"); Text("ms").foregroundStyle(Design.secondary) }.frame(width: Design.siteLatencyColumn, alignment: .trailing)
                    }.font(Design.body).frame(height: Design.tableRow)
                }
            }
            SectionRule()
            VStack(alignment: .leading, spacing: Design.rowGap) {
                SectionHeading(title: "出口 IP", detail: "每 \(Int(value.samplingInterval / 60)) 分钟采样")
                ForEach(value.egress.indices, id: \.self) { index in
                    let row = value.egress[index]
                    VStack(spacing: Design.smallGap) {
                        HStack { Text(row.target).font(Design.body); Spacer(); Text(row.ip ?? row.failure ?? "等待采样").font(Design.title).monospaced() }
                        HStack { if let region = row.region { Text(region) }; Spacer(); Text(row.stability) }.font(Design.caption).foregroundStyle(Design.secondary)
                    }
                }
            }
        }
    }
}
