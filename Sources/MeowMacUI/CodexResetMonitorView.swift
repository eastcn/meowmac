import SwiftUI
import AppKit
import MeowMacCore

struct CodexResetMonitorView: View {
    let display: CodexResetDisplay
    var body: some View {
        VStack(alignment: .leading, spacing: Design.rowGap) {
            SectionHeading(title: "额外重置监控", detail: "每 10 分钟")
            Text(display.headline).font(Design.title)
                .foregroundStyle(display.error == nil ? Design.label : Design.stateText(.warn))
            ForEach(display.pending) { row in
                VStack(alignment: .leading, spacing: Design.gap) {
                    Text(row.label + " · " + row.status).font(Design.body)
                    Text(row.scope).font(Design.caption).foregroundStyle(Design.secondary)
                    if let text = row.announcement { Text(text).font(Design.caption).foregroundStyle(Design.secondary) }
                    if let text = row.estimate { Text(text).font(Design.caption).foregroundStyle(Design.secondary) }
                }.fixedSize(horizontal: false, vertical: true)
            }
            if let latest = display.latest {
                VStack(alignment: .leading, spacing: Design.gap) {
                    Text("最近确认：" + latest.label).font(Design.body)
                    if let text = latest.confirmation { Text(text).font(Design.caption).foregroundStyle(Design.secondary) }
                    Text(latest.scope).font(Design.caption).foregroundStyle(Design.secondary)
                }.fixedSize(horizontal: false, vertical: true)
            } else if display.fetchedAt != nil {
                Text("最近 7 天暂无确认记录").font(Design.caption).foregroundStyle(Design.secondary)
            }
            Text("公开消息不代表当前账号已到账。").font(Design.tiny).foregroundStyle(Design.secondary)
            VStack(alignment: .leading, spacing: Design.smallGap) {
                Text(display.fetchedAt.map { "获取：" + DisplayDate.format($0, pattern: "M/d HH:mm") } ?? "尚未成功获取")
                Text(display.verifiedAt.map { "站点核验：" + DisplayDate.format($0, pattern: "M/d HH:mm") } ?? "站点核验时间未知")
                if let status = display.siteStatus { Text(status) }
            }.font(Design.tiny).foregroundStyle(Design.secondary)
            if let error = display.error { Text(error).font(Design.caption).foregroundStyle(Design.stateText(.warn)) }
            if let error = display.cacheError { Text(error).font(Design.caption).foregroundStyle(Design.stateText(.warn)) }
            Button { NSWorkspace.shared.open(CodexResetDisplay.sourceURL) } label: {
                Text("AIHOT · 查看来源 ↗").font(Design.caption).foregroundStyle(Design.blue)
            }.buttonStyle(.plain)
        }.fixedSize(horizontal: false, vertical: true).monospacedDigit()
    }
}
