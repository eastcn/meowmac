import SwiftUI
import MeowMacCore

struct ProxyTrafficCard: View {
    @ObservedObject var state: PanelState
    var body: some View {
        let data = state.proxyTraffic
        let summary = ProxyTrafficSummary(rows: data.rows, range: state.proxyTrafficRange, now: state.now())
        VStack(alignment: .leading, spacing: Design.gap) {
            HStack {
                SectionHeading(title: "代理流量")
                CapsuleSelector(titles: ["今天", "近 7 天"], selected: state.proxyTrafficRange == .today ? 0 : 1, compact: true) {
                    state.proxyTrafficRange = $0 == 0 ? .today : .week
                }.fixedSize()
            }
            if !data.enabled { empty("代理流量统计已关闭", detail: "可在本机配置中开启统计。") }
            else if !data.available && state.proxyTrafficRange == .today {
                empty("读不到代理的控制接口", detail: "代理应用没有运行，或找不到控制 socket。\n恢复后自动继续采集；历史仍可在“近 7 天”查看。")
            } else {
                totals(summary)
                ProxyTrafficChart(summary: summary, range: state.proxyTrafficRange)
                if summary.processes.isEmpty {
                    empty("暂无经代理的流量", detail: "没有记录的时段不补数据。")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(summary.processes.enumerated()), id: \.element.id) { index, process in
                            if index > 0 { SectionRule() }
                            processRow(process, other: summary.other.total)
                        }
                    }.background(Design.track, in: RoundedRectangle(cornerRadius: Design.groupRadius))
                }
                (Text("未匹配任何规则（走 MATCH）的流量占 ")
                    + Text(ProxyTrafficFormat.percent(summary.matchFraction))
                        .foregroundColor(summary.matchWarning ? Design.stateText(.warn) : Design.secondary))
                    .font(Design.tiny).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: Design.tightGap) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Design.label)
            Text(detail).font(Design.caption).foregroundStyle(Design.secondary)
        }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity).padding(.vertical, 14).padding(.horizontal, Design.footerInset)
            .background(Design.track, in: RoundedRectangle(cornerRadius: Design.groupRadius))
    }
    private func totals(_ summary: ProxyTrafficSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.metricGap) {
            amount(summary.proxy.down, title: "下行", color: Design.teal)
            amount(summary.proxy.up, title: "上行", color: Design.purple)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: Design.tightGap) {
                Text(ProxyTrafficFormat.percent(summary.proxyFraction)).font(Design.title).monospacedDigit()
                Text("经代理占全部").font(Design.tiny).foregroundStyle(Design.secondary)
            }.fixedSize()
        }.padding(.vertical, Design.smallGap)
    }
    private func amount(_ bytes: Double, title: String, color: Color) -> some View {
        let parts = ProxyTrafficFormat.parts(bytes)
        return VStack(alignment: .leading, spacing: Design.tightGap) {
            HStack(alignment: .firstTextBaseline, spacing: Design.smallGap) {
                Text(parts.value).font(Design.amount).monospacedDigit()
                Text(parts.unit).font(Design.caption).foregroundStyle(Design.secondary)
            }.lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: Design.smallGap) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(title).font(Design.tiny).foregroundStyle(Design.secondary)
            }
        }
    }
    private func processRow(_ process: ProxyTrafficProcessSummary, other: Double) -> some View {
        let expanded = state.expandedProxyProcesses.contains(process.id)
        return VStack(alignment: .leading, spacing: Design.smallGap) {
            Button {
                if expanded { state.expandedProxyProcesses.remove(process.id) }
                else { state.expandedProxyProcesses.insert(process.id) }
            } label: {
                HStack(spacing: Design.gap) {
                    Text(process.name).font(Design.checkName).lineLimit(1).truncationMode(.tail).help(process.name)
                    Spacer(minLength: 0)
                    Text(ProxyTrafficFormat.bytes(process.amount.total)).font(Design.button).monospacedDigit().fixedSize()
                    Text(ProxyTrafficFormat.percent(process.fraction)).font(Design.caption).foregroundStyle(Design.secondary).fixedSize()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(Design.tiny).foregroundStyle(Design.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("proxy.process." + process.id)
            GeometryReader { geometry in
                Capsule().fill(Design.teal).frame(width: geometry.size.width * process.fraction)
            }.frame(height: Design.miniBar).background(Design.separator.opacity(0.25), in: Capsule())
            if expanded {
                if process.hasDetails {
                    ForEach(process.domains, id: \.name) { domain in
                        HStack(spacing: Design.gap) {
                            Text(domain.name).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).help(domain.name)
                            Spacer(minLength: 0)
                            Text(ProxyTrafficFormat.bytes(domain.bytes)).font(Design.caption).foregroundStyle(Design.secondary).fixedSize()
                        }
                    }
                    Text("规则 \(process.rule ?? "未知规则") · 节点 \(process.node ?? "未知节点")")
                        .font(Design.tiny).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("基于保留明细 · 未保留明细 " + ProxyTrafficFormat.bytes(other))
                        .font(Design.tiny).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("明细未保留").font(Design.tiny).foregroundStyle(Design.secondary)
                }
            }
        }.padding(Design.checkRowInset)
    }
}

private struct ProxyTrafficChart: View {
    let summary: ProxyTrafficSummary
    let range: ProxyTrafficRange
    var body: some View {
        VStack(spacing: Design.smallGap) {
            HStack(alignment: .bottom, spacing: Design.tightGap) {
                ForEach(summary.bars) { bar in
                    ProxyTrafficColumn(bar: bar, maximum: summary.chartMaximum)
                        .help(tip(bar)).accessibilityLabel(tip(bar))
                }
            }.frame(height: 44)
            HStack {
                ForEach([0, range == .today ? 8 : 2, range == .today ? 16 : 4], id: \.self) { index in
                    Text(label(summary.bars[index].date)); Spacer(minLength: 0)
                }
                Text(range == .today ? "现在" : "今天")
            }.font(Design.tiny).foregroundStyle(Design.secondary)
            HStack {
                Text("斜纹 无记录"); Spacer(); Text("竖纹 进行中")
            }.font(Design.tiny).foregroundStyle(Design.secondary)
        }
    }
    private func label(_ date: Date) -> String { DisplayDate.format(date, pattern: range == .today ? "H:mm" : "M/d") }
    private func tip(_ bar: ProxyTrafficBar) -> String {
        let period = range == .today ? label(bar.date) + "～" + label(bar.end) : label(bar.date)
        guard bar.recorded else { return period + " · 无记录" }
        return period + (bar.ongoing ? " · 进行中" : "") + "\n下行 " + ProxyTrafficFormat.bytes(bar.amount.down)
            + " · 上行 " + ProxyTrafficFormat.bytes(bar.amount.up) + "\n最大：" + (bar.largestProcess ?? "无经代理流量")
    }
}

private struct ProxyTrafficColumn: View {
    let bar: ProxyTrafficBar
    let maximum: Double
    var body: some View {
        Canvas { context, size in
            if !bar.recorded {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Design.gray.opacity(0.08)))
                var stripes = Path()
                for x in stride(from: -size.height, through: size.width, by: 5) {
                    stripes.move(to: CGPoint(x: x, y: size.height)); stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                }
                context.stroke(stripes, with: .color(Design.gray.opacity(0.28)), lineWidth: 1)
            } else {
                let height = max(1, size.height * bar.amount.total / maximum)
                let up = height * (bar.amount.total > 0 ? bar.amount.up / bar.amount.total : 0)
                let rect = CGRect(x: 0, y: size.height - height, width: size.width, height: height)
                context.fill(Path(rect), with: .color(Design.teal))
                context.fill(Path(CGRect(x: 0, y: rect.minY, width: size.width, height: up)), with: .color(Design.purple.opacity(0.75)))
                if bar.ongoing {
                    var stripes = Path()
                    for x in stride(from: CGFloat(2), through: size.width, by: 4) {
                        stripes.move(to: CGPoint(x: x, y: rect.minY)); stripes.addLine(to: CGPoint(x: x, y: rect.maxY))
                    }
                    context.stroke(stripes, with: .color(Design.label.opacity(0.3)), lineWidth: 1)
                }
            }
        }.frame(maxWidth: .infinity).clipped().contentShape(Rectangle())
    }
}
