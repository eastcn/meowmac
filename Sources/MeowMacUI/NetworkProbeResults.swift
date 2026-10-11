import SwiftUI
import MeowMacCore
import TunCanaryCore

/// 保留探测目标和结果类别，不暴露 URL 中的凭据、路径或查询参数。
public struct NetworkSiteDisplay: Codable, Identifiable {
    public let id: String
    public let name: String
    public let group: String
    public let target: String
    public let summary: String
    public let checkedAt: Date
    public let failed: Bool
    public let tone: NetworkTone

    init(_ result: SiteResult) {
        id = result.site.id; name = result.site.name; group = result.site.group.displayName
        let host = result.site.url.host ?? "目标地址不可用"
        target = host + (result.site.url.port.map { ":\($0)" } ?? "")
        summary = result.summaryText; checkedAt = result.checkedAt; failed = result.isFailure
        tone = failed ? .red : result.category == .localNetworkDenied ? .gray : .green
    }
}

/// 入口位于固定结论区，隐藏站点趋势卡片也能查看复测结果。
struct NetworkProbeResultsView: View {
    let rows: [NetworkSiteDisplay]
    let isChecking: Bool
    @State private var expanded: Bool

    init(rows: [NetworkSiteDisplay], isChecking: Bool, expanded: Bool = false) {
        self.rows = rows; self.isChecking = isChecking
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        let failures = rows.filter(\.failed).count
        VStack(alignment: .leading, spacing: Design.gap) {
            Button { expanded.toggle() } label: {
                HStack(spacing: Design.smallGap) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("探测结果")
                    Text(rows.isEmpty ? "暂无结果" : failures > 0 ? "\(failures) 项失败" : "\(rows.count) 个目标")
                        .foregroundStyle(failures > 0 ? Design.stateText(.severe) : Design.secondary)
                    Spacer(minLength: 0)
                }.font(Design.caption).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityIdentifier("network.probeResults")
                .accessibilityValue(expanded ? "已展开" : "已收起")
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PanelInteractionFrameKey.self,
                        value: ["network.probeResults": proxy.frame(in: .named(PanelInteractionFrameKey.space))])
                })
            if expanded {
                Text(isChecking ? "正在检测，以下保留上次结果。" : "每个目标最近一次结果；后台探测或复测后更新。")
                    .font(Design.tiny).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
                if rows.isEmpty {
                    Text("尚无站点探测结果，可点击“复测”。")
                        .font(Design.caption).foregroundStyle(Design.secondary)
                }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: Design.tightGap) {
                        HStack(alignment: .firstTextBaseline, spacing: Design.gap) {
                            Text(row.name).font(Design.checkName).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Text(row.summary).font(Design.caption).foregroundStyle(NetworkTrendLine.text(row.tone))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(row.target).font(Design.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(row.group + " · " + DisplayDate.format(row.checkedAt, pattern: "M/d HH:mm:ss"))
                            .font(Design.tiny).foregroundStyle(Design.secondary)
                    }.padding(Design.gap).frame(maxWidth: .infinity, alignment: .leading)
                        .background(row.failed ? Design.red.opacity(Design.mutedFill) : Design.track,
                                    in: RoundedRectangle(cornerRadius: Design.groupRadius))
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: PanelInteractionFrameKey.self,
                                value: ["network.result." + row.id: proxy.frame(in: .named(PanelInteractionFrameKey.space))])
                        })
                }
            }
        }
    }
}

public extension PanelPreviewRenderer {
    /// 只渲染合成探测结果，不开启前台窗口。
    static func networkProbeResultsPNG(_ rows: [NetworkSiteDisplay], dark: Bool) -> Data? {
        let view = NetworkProbeResultsView(rows: rows, isChecking: false, expanded: true)
            .padding(Design.inset).frame(width: Design.panelWidth)
        let measure = NSHostingView(rootView: view)
        return renderPNG(view, width: Design.panelWidth, height: ceil(measure.fittingSize.height), dark: dark)
    }
}
