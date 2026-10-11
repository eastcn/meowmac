import Foundation
import SwiftUI
import MeowMacCore
import TunCanaryCore
import TunCanaryUI

public struct NetworkCheckDisplay: Codable {
    public let kind: String, name: String, detail: String, status: String
    public let tone: NetworkTone
    public var hint: String? = nil
    public var evidence: [String] = []
    /// 当前异常开始的时刻，来自故障事件日志；取不到时为空。
    public var since: Date? = nil
}
public struct NetworkGroupDisplay: Codable {
    public let name: String
    public let passed: Int, total: Int
    public let medianMilliseconds: Double?
}
public struct NetworkEgressSegment: Codable, Equatable {
    public let ip: String
    public let region: String?
    public let start: Date, end: Date
}
public struct NetworkEgressDisplay: Codable {
    public let target: String, ip: String?, region: String?, stability: String, failure: String?
    /// 最近 30 天每个 IP 的连续时段，旧 → 新。
    public var segments: [NetworkEgressSegment] = []
    public var changes: Int { max(0, segments.count - 1) }
}
/// 趋势图的一行：站点分组或下行、上行。
public struct NetworkTrendRow: Codable {
    public let name: String
    public let detail: String
    public let detailTone: NetworkTone?
    public let value: String, unit: String, valueDetail: String
    public let valueTone: NetworkTone?
    public let points: [NetworkTrendPointDisplay]
    public let missing: [ClosedRange<Double>]
    public let maxValue: Double
    public let probed: Bool
    public let help: String
}
public struct NetworkTrendPointDisplay: Codable {
    public let date: Date
    public let value: Double?
    public let low: Double?, high: Double?
    public let failed: Bool
}
public struct NetworkTrendsDisplay: Codable {
    public let range: NetworkTrendRange
    public let start: Date, end: Date
    public let sites: [NetworkTrendRow]
    public let traffic: [NetworkTrendRow]
    /// 连接检查下方一行：所选范围内已恢复的异常。
    public let recent: String
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
    public var trends: NetworkTrendsDisplay? = nil
    /// 每个目标最近一次结果。旧快照缺少此字段时仍可解码。
    public var siteResults: [NetworkSiteDisplay]? = nil
    public var quotaProtectionWarning: String? = nil
    public var passed: Int { checks.filter { $0.tone == .green }.count }
}

enum NetworkNames {
    static let checks = ["代理 TUN", "VPN", "主网络 DNS", "代理 DNS", "Tailnet"]
    /// 故障事件按键的前缀归到检查项；站点类事件由 MeowMac 自己的历史表达，这里不列。
    static func check(for key: FaultKey?) -> String? {
        guard let raw = key?.rawValue else { return nil }
        if raw.hasPrefix("tun.") { return checks[0] }
        if raw.hasPrefix("vpn.") { return checks[1] }
        if raw.hasPrefix("dns.") { return checks[2] }
        if raw.hasPrefix("mihomo.") || raw.hasPrefix("proxyDNS.") { return checks[3] }
        if raw.hasPrefix("tailnet.") { return checks[4] }
        return nil
    }
    static func status(_ tone: NetworkTone) -> String {
        switch tone { case .green: return "通过"; case .yellow: return "提醒"; case .red: return "失败"; case .gray: return "未确认" }
    }
}

public extension AppModel {
    var meowMacDisplay: NetworkDisplay {
        let checks = StatusCardKind.displayOrder.enumerated().map { index, kind in
            let card = cards.first { $0.kind == kind }
            let tone = card.map { NetworkToneMapper.map($0.severity) } ?? .gray
            var check = NetworkCheckDisplay(kind: kind.rawValue, name: NetworkNames.checks[index], detail: card?.conclusion ?? "未配置或尚未检测",
                status: NetworkNames.status(tone), tone: tone)
            check.hint = card?.hint
            check.evidence = card?.evidence ?? []
            if tone == .yellow || tone == .red { check.since = Self.faultStart(card?.faultKey, events: recentEvents) }
            return check
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
            var row = NetworkEgressDisplay(target: target.displayName, ip: result?.ip, region: region, stability: stability, failure: result?.failure?.displayName)
            row.segments = egressSegments(target)
            return row
        }
        let tone = NetworkToneMapper.map(overall.severity)
        // 结论写最严重的检查项和持续时长；只有站点问题时沿用 TunCanary 的原因。
        let worst = checks.filter { $0.tone == .red }.first ?? checks.filter { $0.tone == .yellow }.first
        let conclusion: String
        if tone == .green { conclusion = "网络正常" }
        else if let worst {
            conclusion = worst.name + " " + worst.status + (worst.since.map { " · " + MetricFormat.duration(max(60, now().timeIntervalSince($0))) } ?? "")
        } else { conclusion = tone == .red ? "网络异常" : tone == .yellow ? "网络提醒" : "网络待确认" }
        let counts: [(NetworkTone, String)] = [(.green, "通过"), (.yellow, "提醒"), (.red, "失败"), (.gray, "未确认")]
        let countText = counts.compactMap { tone, word in
            let count = checks.filter { $0.tone == tone }.count
            return count > 0 ? "\(count) 项\(word)" : nil
        }.joined(separator: " · ")
        let detail = tone != .green && worst == nil ? overall.primaryReason : countText
        var display = NetworkDisplay(tone: tone, conclusion: conclusion, detail: detail,
            checkedAt: lastCheckedAt, checks: checks, groups: groups, egress: egress,
            samplingInterval: settings.egressMonitoring.effectiveInterval, isChecking: checkProgress != nil)
        display.siteResults = siteHistory.results.values.compactMap(\.last).map(NetworkSiteDisplay.init).sorted {
            if $0.failed != $1.failed { return $0.failed }
            if $0.target != $1.target { return $0.target < $1.target }
            return $0.id < $1.id
        }
        return display
    }

    /// 某个故障键当前这次异常的开始时刻：从最新事件往回找，遇到“消失”就停。
    static func faultStart(_ key: FaultKey?, events: [FaultEvent]) -> Date? {
        guard let key else { return nil }
        var start: Date?
        for event in events.reversed() where event.key == key {
            if event.kind == .cleared { break }
            start = event.date
            if event.kind == .appeared { break }
        }
        return start
    }

    /// 最近 30 天里，每个目标成功采样的 IP 连续段。
    func egressSegments(_ target: EgressIPTarget) -> [NetworkEgressSegment] {
        let end = now(), start = end.addingTimeInterval(-30 * 86400)
        let rows = egressState.history.filter { $0.result.target == target && $0.result.isSuccess && $0.result.checkedAt >= start && $0.result.checkedAt <= end }
            .sorted { $0.result.checkedAt < $1.result.checkedAt }
        var segments: [(ip: String, region: String?, start: Date)] = []
        for row in rows {
            guard let ip = row.result.ip else { continue }
            if segments.last?.ip != ip { segments.append((ip, row.geo?.displayName ?? row.result.location, row.result.checkedAt)) }
        }
        return segments.enumerated().map { index, item in
            NetworkEgressSegment(ip: item.ip, region: item.region, start: item.start,
                                 end: index + 1 < segments.count ? segments[index + 1].start : end)
        }
    }
}

public extension PanelState {
    /// 站点和速率的趋势，以及已恢复异常的一行说明。没有网络模型时为空。
    var networkTrends: NetworkTrendsDisplay? {
        guard let model = networkModel else { return nil }
        let range = networkRange, end = now(), start = end.addingTimeInterval(-range.seconds)
        let history = networkHistory
        let display = model.meowMacDisplay
        var sites: [NetworkTrendRow] = []
        for (index, group) in NetworkSiteGroup.allCases.enumerated() {
            let current = display.groups[index]
            let points = NetworkTrend.sites(history.sites, group: group, range: range, now: end)
            let records = history.sites.filter { $0.group == group }
            let failing = records.reversed().prefix { $0.allFailed }.count
            let probed = current.total > 0 || points.contains { $0.totalRounds > 0 && $0.value != nil }
            let maxValue = Self.niceLatency(points.compactMap { $0.high ?? $0.value }.max() ?? 0)
            let tone: NetworkTone = current.total == 0 ? .gray : current.passed == current.total ? .green : current.passed == 0 ? .red : .yellow
            let detail = current.total == 0 ? "0 / 0 · 不探测" : "\(current.passed) / \(current.total) 通过"
            let value: String, unit: String, valueDetail: String, valueTone: NetworkTone?
            if current.total == 0 { value = "—"; unit = ""; valueDetail = "不探测"; valueTone = .gray }
            else if current.passed == 0 { value = "失败"; unit = ""; valueDetail = failing > 0 ? "连续 \(failing) 轮" : "最近一轮"; valueTone = .red }
            else { value = current.medianMilliseconds.map { String(format: "%.0f", $0) } ?? "—"; unit = " ms"; valueDetail = "延迟中位数"; valueTone = nil }
            let failedRounds = points.reduce(0) { $0 + $1.failedRounds }, rounds = points.reduce(0) { $0 + $1.totalRounds }
            let help = "\(group.title) · 量程 0–\(Int(maxValue)) ms" + (rounds > 0 ? " · \(range.title)内 \(rounds) 轮，失败 \(failedRounds) 轮" : " · \(range.title)内没有记录")
            sites.append(NetworkTrendRow(name: group.title, detail: detail, detailTone: tone, value: value, unit: unit, valueDetail: valueDetail,
                valueTone: valueTone, points: points.map(Self.pointDisplay), missing: probed ? NetworkTrend.missingIntervals(points.map(\.date), range: range, now: end,
                threshold: NetworkTrend.gapThreshold(range: range, sites: true)) : [], maxValue: maxValue, probed: probed, help: help))
        }
        let traffic = [(true, "下行", snapshot?.networkReceivedBytesPerSecond), (false, "上行", snapshot?.networkSentBytesPerSecond)].map { received, name, current in
            let points = NetworkTrend.traffic(history.traffic, received: received, range: range, now: end)
            let maxValue = max(1024, (points.compactMap { range == .day ? $0.high : $0.value }.max() ?? 0) * 1.15)
            let formatted = current.map(Self.rate) ?? ("—", "")
            return NetworkTrendRow(name: name, detail: "", detailTone: nil, value: formatted.0, unit: formatted.1, valueDetail: "", valueTone: nil,
                points: points.map(Self.pointDisplay), missing: NetworkTrend.missingIntervals(points.map(\.date), range: range, now: end,
                threshold: NetworkTrend.gapThreshold(range: range, sites: false)), maxValue: maxValue, probed: true,
                help: name + " · 量程 0–" + Self.rate(maxValue).0 + Self.rate(maxValue).1 + (range == .day ? " · 5 分钟均值，浅色竖线为桶内峰值" : " · 30 秒均值"))
        }
        return NetworkTrendsDisplay(range: range, start: start, end: end, sites: sites, traffic: traffic,
                                    recent: Self.recentText(events: model.recentEvents, history: history, range: range, start: start, end: end))
    }

    private static func pointDisplay(_ point: NetworkTrendPoint) -> NetworkTrendPointDisplay {
        NetworkTrendPointDisplay(date: point.date, value: point.value, low: point.low, high: point.high, failed: point.hasFailure)
    }

    static func niceLatency(_ value: Double) -> Double {
        let padded = max(100, value * 1.1)
        let step: Double = padded <= 1000 ? 100 : 500
        return ceil(padded / step) * step
    }

    /// 每秒字节换成数值和单位，例如 (“2.4”, “ MB/s”)。
    static func rate(_ value: Double) -> (String, String) {
        if value >= 1024 * 1024 { return (String(format: "%.1f", value / 1024 / 1024), " MB/s") }
        if value >= 1024 { let kb = value / 1024; return (kb >= 100 ? String(format: "%.0f", kb) : String(format: "%.1f", kb), " KB/s") }
        return (String(format: "%.0f", value), " B/s")
    }

    /// 所选范围内已恢复的异常，新 → 旧，最多 3 条。
    static func recentText(events: [FaultEvent], history: NetworkHistory, range: NetworkTrendRange, start: Date, end: Date) -> String {
        var items: [(Date, String)] = []
        var open: [FaultKey: (Date, Severity?)] = [:]
        for event in events where event.date <= end {
            guard let key = event.key else { continue }
            switch event.kind {
            case .appeared: open[key] = (event.date, event.severity)
            case .changed: if open[key] == nil { open[key] = (event.date, event.severity) } else if event.severity == .critical { open[key]?.1 = .critical }
            case .cleared:
                if let (began, severity) = open.removeValue(forKey: key), event.date >= start, let name = NetworkNames.check(for: key) {
                    items.append((event.date, "\(name) \(clock(began, range: range))–\(clock(event.date, range: range)) \(severity == .critical ? "失败" : "提醒")"))
                }
            case .started: break
            }
        }
        for group in NetworkSiteGroup.allCases {
            let failed = history.sites.filter { $0.group == group && $0.failed && $0.sampledAt > start && $0.sampledAt <= end }
            // 最后一轮仍失败的属于当前问题，不算已恢复。
            guard let last = failed.last, history.sites.last(where: { $0.group == group })?.failed == false else { continue }
            items.append((last.sampledAt, "\(group.title) \(clock(last.sampledAt, range: range)) 失败 \(failed.count) 轮"))
        }
        let prefix = range == .hour ? "近 1 小时：" : "近 24 小时："
        if items.isEmpty {
            if let started = history.startedAt, started > start,
               (history.sites.first?.sampledAt ?? started) >= started.addingTimeInterval(-NetworkTrend.gapThreshold(range: range, sites: true)) {
                return DisplayDate.format(started, pattern: "HH:mm") + " 启动，较早时段暂无记录"
            }
            return prefix + "没有已恢复的异常"
        }
        let sorted = items.sorted { $0.0 > $1.0 }.map(\.1)
        return prefix + sorted.prefix(3).joined(separator: "；") + (sorted.count > 3 ? " 等 \(sorted.count) 项" : "")
    }

    private static func clock(_ date: Date, range: NetworkTrendRange) -> String {
        DisplayDate.format(date, pattern: "HH:mm")
    }
}

struct NetworkPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState
    var body: some View {
        let value = model.meowMacDisplay
        let protection = state.quotaProxyWarning
        let tone = protection == nil ? value.tone : NetworkTone.red
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            HStack(alignment: .center, spacing: Design.footerInset) {
                ZStack {
                    Circle().fill(Design.networkColor(tone))
                    Image(systemName: tone == .green ? "checkmark" : tone == .red ? "xmark" : tone == .yellow ? "exclamationmark" : "questionmark")
                        .font(.system(size: Design.verdictIcon * 0.5, weight: .bold)).foregroundStyle(Design.iconInk)
                }.frame(width: Design.verdictIcon, height: Design.verdictIcon)
                VStack(alignment: .leading, spacing: Design.tightGap) {
                    Text(protection == nil ? value.conclusion : "额度查询保护 · 严重警告").font(Design.status)
                        .foregroundStyle(protection == nil ? Design.label : Design.stateText(.severe)).fixedSize(horizontal: false, vertical: true)
                    Text(protection ?? value.detail).font(Design.caption).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Design.gap)
                VStack(alignment: .trailing, spacing: Design.smallGap) {
                    Text(DisplayDate.age(value.checkedAt, now: model.now()) + "检测").font(Design.tiny).foregroundStyle(Design.secondary).fixedSize()
                    CapsuleAction(title: value.isChecking ? "正在检测…" : "复测", action: model.recheck).disabled(value.isChecking)
                }
            }.accessibilityIdentifier(protection == nil ? "network.verdict" : "network.quota-protection")
            NetworkProbeResultsView(rows: value.siteResults ?? [], isChecking: value.isChecking)
            ForEach(state.renderedCardIDs(for: .network), id: \.self) { id in
                SectionRule()
                PanelCardRegistry.cards[id]?.makeView(state: state).measureCardBottom(id)
            }
        }
    }
}

/// TunCanary 的红绿灯行：正常时名称和结论一行；非正常时整行着色，另起一行写结论和提示。点击展开证据。
struct NetworkChecks: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState
    @State private var expanded: Set<String> = []
    var body: some View {
        let value = model.meowMacDisplay
        VStack(alignment: .leading, spacing: Design.gap) {
            SectionHeading(title: "连接检查", detail: "\(value.passed) / 5 通过")
            VStack(spacing: 0) {
                ForEach(value.checks.indices, id: \.self) { index in
                    if index > 0 { Rectangle().fill(Design.separator).frame(height: Design.rule) }
                    row(value.checks[index])
                }
            }.background(Design.track, in: RoundedRectangle(cornerRadius: Design.groupRadius))
                .clipShape(RoundedRectangle(cornerRadius: Design.groupRadius))
            if let recent = state.networkTrends?.recent {
                Text(recent).font(Design.tiny).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func level(_ tone: NetworkTone) -> HealthLevel? {
        switch tone { case .yellow: return .warn; case .red: return .severe; default: return nil }
    }

    @ViewBuilder private func row(_ check: NetworkCheckDisplay) -> some View {
        let abnormal = level(check.tone)
        let open = expanded.contains(check.kind)
        VStack(alignment: .leading, spacing: Design.smallGap) {
            Button {
                if open { expanded.remove(check.kind) } else { expanded.insert(check.kind) }
            } label: {
                HStack(spacing: Design.rowGap) {
                    NetworkBadge(tone: check.tone)
                    Text(check.name).font(Design.checkName).lineLimit(1).layoutPriority(2)
                    Spacer(minLength: Design.gap)
                    if let abnormal {
                        if let since = check.since {
                            Text("已持续 " + MetricFormat.duration(max(60, model.now().timeIntervalSince(since)))).font(Design.caption)
                                .foregroundStyle(Design.stateText(abnormal)).monospacedDigit().fixedSize()
                        }
                    } else {
                        Text(check.detail).font(Design.caption).foregroundStyle(Design.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    if !check.evidence.isEmpty {
                        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Design.secondary)
                            .rotationEffect(.degrees(open ? 180 : 0)).frame(width: Design.footerInset)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(check.evidence.isEmpty).help(check.name + "：" + check.detail)
            if abnormal != nil || open {
                VStack(alignment: .leading, spacing: Design.tightGap) {
                    if let abnormal { Text(check.detail).foregroundStyle(Design.stateText(abnormal)) }
                    if abnormal != nil, let hint = check.hint { Text("提示：" + hint).foregroundStyle(Design.label.opacity(0.85)) }
                    if open { ForEach(check.evidence.indices, id: \.self) { Text("· " + check.evidence[$0]).foregroundStyle(Design.secondary) } }
                }.font(Design.caption).fixedSize(horizontal: false, vertical: true).padding(.leading, Design.badge + Design.rowGap)
            }
        }
        .padding(.horizontal, Design.footerInset).padding(.vertical, Design.checkRowInset)
        .background(abnormal.map { Design.state($0).opacity(Design.mutedFill) } ?? .clear)
    }
}

struct NetworkBadge: View {
    let tone: NetworkTone
    var body: some View {
        ZStack {
            Circle().fill(Design.networkColor(tone))
            Image(systemName: tone == .green ? "checkmark" : tone == .red ? "xmark" : tone == .yellow ? "exclamationmark" : "questionmark")
                .font(.system(size: 8, weight: .heavy)).foregroundStyle(Design.iconInk)
        }.frame(width: Design.badge, height: Design.badge)
    }
}

/// 站点和速率共用的一行：名称、迷你图、当前值。
struct NetworkTrendLine: View {
    let row: NetworkTrendRow
    let trends: NetworkTrendsDisplay
    let color: Color
    var dashed = false
    var height = Design.siteRowHeight
    var body: some View {
        HStack(spacing: Design.rowGap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Design.smallGap) {
                    if row.detail.isEmpty { Circle().fill(color).frame(width: Design.legendDot - 3, height: Design.legendDot - 3) }
                    Text(row.name).font(Design.body).lineLimit(1)
                }
                if !row.detail.isEmpty {
                    Text(row.detail).font(Design.tiny).lineLimit(1)
                        .foregroundStyle(row.detailTone.map(Self.text) ?? Design.secondary)
                }
            }.frame(width: Design.networkLabelWidth, alignment: .leading)
            NetworkSparkline(row: row, domain: trends.start...trends.end, color: color, dashed: dashed, band: trends.range == .day)
            VStack(alignment: .trailing, spacing: 0) {
                (Text(row.value).font(Design.title).foregroundColor(row.valueTone.map(Self.text) ?? Design.label)
                    + Text(row.unit).font(Design.tiny).foregroundColor(Design.secondary)).monospacedDigit().lineLimit(1)
                if !row.valueDetail.isEmpty { Text(row.valueDetail).font(Design.tiny).foregroundStyle(Design.secondary).lineLimit(1) }
            }.frame(width: Design.networkValueWidth, alignment: .trailing)
        }.frame(height: height).contentShape(Rectangle()).help(row.help)
    }

    static func text(_ tone: NetworkTone) -> Color {
        switch tone { case .green: return Design.stateText(.normal); case .yellow: return Design.stateText(.warn); case .red: return Design.stateText(.severe); case .gray: return Design.secondary }
    }
}

struct NetworkSparkline: View {
    let row: NetworkTrendRow
    let domain: ClosedRange<Date>
    let color: Color
    var dashed = false
    var band = false
    var body: some View {
        Canvas { context, size in
            let duration = max(1, domain.upperBound.timeIntervalSince(domain.lowerBound))
            func x(_ date: Date) -> CGFloat { size.width * min(1, max(0, date.timeIntervalSince(domain.lowerBound) / duration)) }
            func y(_ value: Double) -> CGFloat { (size.height - 2) - (size.height - 4) * min(1, max(0, value / max(1, row.maxValue))) }
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: size.height - 0.5)); grid.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            for fraction in [0.0, 0.5, 1.0] {
                let gx = min(size.width - 0.5, max(0.5, size.width * fraction))
                grid.move(to: CGPoint(x: gx, y: 0)); grid.addLine(to: CGPoint(x: gx, y: size.height))
            }
            context.stroke(grid, with: .color(Design.separator), lineWidth: 0.6)
            // 没有记录的时段画斜纹。
            for interval in row.missing {
                let rect = CGRect(x: size.width * interval.lowerBound, y: 0, width: size.width * (interval.upperBound - interval.lowerBound), height: size.height)
                var hatch = Path()
                var start = rect.minX - size.height
                while start < rect.maxX {
                    hatch.move(to: CGPoint(x: start, y: size.height)); hatch.addLine(to: CGPoint(x: start + size.height, y: 0))
                    start += 5
                }
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.stroke(hatch, with: .color(Design.gray.opacity(0.45)), lineWidth: 0.65)
                }
            }
            guard row.probed else { return }
            if band {
                for point in row.points where point.value != nil {
                    guard let low = point.low, let high = point.high else { continue }
                    var line = Path(); line.move(to: CGPoint(x: x(point.date), y: y(high))); line.addLine(to: CGPoint(x: x(point.date), y: y(low)))
                    context.stroke(line, with: .color(color.opacity(0.18)), lineWidth: 1)
                }
            }
            var path = Path(), pen = false
            for point in row.points {
                guard let value = point.value else { pen = false; continue }
                let p = CGPoint(x: x(point.date), y: y(value))
                if pen { path.addLine(to: p) } else { path.move(to: p); pen = true }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: Design.networkStroke, lineCap: .round, lineJoin: .round, dash: dashed ? [3, 2] : []))
            for point in row.points where point.failed {
                // × 宽 4pt，收进图框，最后一轮失败时不伸进数值列。
                let fx = min(size.width - 2, max(2, x(point.date)))
                context.fill(Path(CGRect(x: min(size.width - 3, max(0, fx - 1.5)), y: 0, width: 3, height: size.height)), with: .color(Design.red.opacity(0.14)))
                var cross = Path()
                cross.move(to: CGPoint(x: fx - 2, y: size.height - 6)); cross.addLine(to: CGPoint(x: fx + 2, y: size.height - 2))
                cross.move(to: CGPoint(x: fx + 2, y: size.height - 6)); cross.addLine(to: CGPoint(x: fx - 2, y: size.height - 2))
                context.stroke(cross, with: .color(Design.red), lineWidth: 1.1)
            }
            if let last = row.points.last, let value = last.value {
                let r: CGFloat = 1.7
                context.fill(Path(ellipseIn: CGRect(x: x(last.date) - r, y: y(value) - r, width: r * 2, height: r * 2)), with: .color(color))
            }
        }.frame(height: Design.networkChartHeight)
    }
}

struct NetworkSites: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: PanelState
    var body: some View {
        if let trends = state.networkTrends {
            VStack(alignment: .leading, spacing: Design.tightGap) {
                HStack {
                    Text("站点延迟").font(Design.title); Spacer()
                    CapsuleSelector(titles: NetworkTrendRange.allCases.map(\.title), selected: state.networkRange == .hour ? 0 : 1, compact: true) {
                        state.networkRange = $0 == 0 ? .hour : .day
                    }
                }
                Text(trends.range == .day ? "10 分钟汇总 · 浅色竖线为范围" : "约 2 分钟一轮").font(Design.tiny).foregroundStyle(Design.secondary)
                ForEach(trends.sites.indices, id: \.self) { index in
                    NetworkTrendLine(row: trends.sites[index], trends: trends, color: Design.blue)
                }
                HStack(spacing: Design.smallGap) {
                    Text("×").font(Design.tiny.weight(.bold)).foregroundStyle(Design.stateText(.severe))
                    Text("失败轮次，全部失败处断线")
                }.font(Design.tiny).foregroundStyle(Design.secondary)
                if state.networkAxisOwner == "network.sites" { NetworkTimeAxis(trends: trends) }
            }
        }
    }
}

struct NetworkTraffic: View {
    @ObservedObject var state: PanelState
    var body: some View {
        if let trends = state.networkTrends {
            VStack(alignment: .leading, spacing: Design.tightGap) {
                SectionHeading(title: "上下行速率", detail: "整机 · " + (trends.range == .day ? "5 分钟均值" : "30 秒均值"))
                ForEach(trends.traffic.indices, id: \.self) { index in
                    NetworkTrendLine(row: trends.traffic[index], trends: trends, color: index == 0 ? Design.teal : Design.purple,
                                     dashed: index == 1, height: Design.trafficRowHeight)
                }
                if state.networkAxisOwner == "network.traffic" { NetworkTimeAxis(trends: trends) }
            }
        }
    }
}

/// 站点和速率共用的时间轴，只画在两者中靠后显示的那一块下面。
struct NetworkTimeAxis: View {
    let trends: NetworkTrendsDisplay
    var body: some View {
        let mid = trends.start.addingTimeInterval(trends.end.timeIntervalSince(trends.start) / 2)
        HStack(spacing: Design.rowGap) {
            HStack(spacing: Design.smallGap) { Hatch().frame(width: 12, height: 7); Text("无记录") }.frame(width: Design.networkLabelWidth, alignment: .leading)
            HStack {
                Text(DisplayDate.format(trends.start, pattern: "HH:mm")); Spacer()
                Text(DisplayDate.format(mid, pattern: "HH:mm")); Spacer()
                Text(DisplayDate.format(trends.end, pattern: "HH:mm"))
            }
            Text(trends.range == .day ? DisplayDate.format(trends.start, pattern: "M/d") + " → " + DisplayDate.format(trends.end, pattern: "M/d") : "现在")
                .frame(width: Design.networkValueWidth, alignment: .trailing)
        }.font(Design.tiny).foregroundStyle(Design.secondary).monospacedDigit().lineLimit(1)
    }
}

struct Hatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path(), start = -size.height
            while start < size.width { path.move(to: CGPoint(x: start, y: size.height)); path.addLine(to: CGPoint(x: start + size.height, y: 0)); start += 3 }
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            context.stroke(path, with: .color(Design.gray.opacity(0.6)), lineWidth: 0.8)
        }
    }
}

struct NetworkEgress: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let value = model.meowMacDisplay
        VStack(alignment: .leading, spacing: Design.rowGap) {
            SectionHeading(title: "出口 IP", detail: "30 天 · 每 \(Int(value.samplingInterval / 60)) 分钟采样")
            ForEach(value.egress.indices, id: \.self) { index in
                let row = value.egress[index]
                VStack(alignment: .leading, spacing: Design.tightGap) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.target).font(Design.button)
                        if let region = row.region { Text("· " + region).font(Design.caption).foregroundStyle(Design.secondary).lineLimit(1) }
                        Spacer(minLength: Design.gap)
                        Text(row.stability).font(Design.caption).foregroundStyle(Design.secondary).fixedSize()
                    }
                    Text(row.ip ?? row.failure ?? "等待采样").font(Design.ip).monospaced().lineLimit(1).minimumScaleFactor(0.8).textSelection(.enabled)
                    if !row.segments.isEmpty {
                        HStack(spacing: Design.rowGap) {
                            EgressStrip(segments: row.segments, now: model.now())
                            Text("变过 \(row.changes) 次").font(Design.tiny).foregroundStyle(Design.secondary).fixedSize()
                        }
                    }
                }
            }
        }
    }
}

/// 30 天出口变化条：每段一个 IP，相邻段深浅交替，变化点画竖线；悬停看这段和上一段。
struct EgressStrip: View {
    let segments: [NetworkEgressSegment]
    let now: Date
    var body: some View {
        GeometryReader { proxy in
            let start = now.addingTimeInterval(-30 * 86400), total = 30 * 86400.0
            let fraction: (Date) -> CGFloat = { CGFloat(min(1, max(0, $0.timeIntervalSince(start) / total))) }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Design.tightGap).fill(Design.track)
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    let x = fraction(segment.start) * proxy.size.width
                    let width = max(2, (fraction(segment.end) - fraction(segment.start)) * proxy.size.width)
                    Rectangle().fill(Design.label.opacity(index % 2 == 0 ? 0.16 : 0.30))
                        .frame(width: width, height: Design.egressStrip)
                        .overlay(alignment: .leading) {
                            if index > 0 { Rectangle().fill(Design.label).frame(width: Design.tickWidth, height: Design.egressStrip + 2) }
                        }
                        .offset(x: x).help(help(index))
                }
            }.clipShape(RoundedRectangle(cornerRadius: Design.tightGap))
        }.frame(height: Design.egressStrip)
    }

    private func help(_ index: Int) -> String {
        let segment = segments[index]
        let pattern = "M/d HH:mm"
        var text = DisplayDate.format(segment.start, pattern: pattern) + (index == segments.count - 1 ? " 起至今" : " – " + DisplayDate.format(segment.end, pattern: pattern)) + (segment.region.map { " · " + $0 } ?? "") + "\n" + segment.ip
        if index > 0 {
            let previous = segments[index - 1]
            text += "\n上一个：" + DisplayDate.format(previous.start, pattern: pattern) + " – " + DisplayDate.format(previous.end, pattern: pattern)
                + (previous.region.map { " · " + $0 } ?? "") + "\n" + previous.ip
        }
        return text
    }
}
