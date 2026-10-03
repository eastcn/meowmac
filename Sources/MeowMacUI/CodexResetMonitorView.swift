import SwiftUI
import AppKit
import MeowMacCore

struct CodexResetMonitorView: View {
    let display: CodexResetDisplay
    var body: some View {
        VStack(alignment: .leading, spacing: Design.smallGap) {
            if display.pending.isEmpty {
                previewRow(nil)
            } else {
                ForEach(display.pending) { row in
                    previewRow(row)
                }
            }
        }.fixedSize(horizontal: false, vertical: true).monospacedDigit()
    }
    private var emptyText: String {
        if display.error != nil { return display.fetchedAt == nil ? "获取失败" : "获取失败 · 暂无预告（缓存）" }
        return display.fetchedAt == nil ? "等待采集" : "暂无"
    }
    private func previewRow(_ row: CodexResetRow?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.gap) {
            ViewThatFits(in: .horizontal) {
                if let row {
                    (Text("重置预告：").font(Design.title)
                     + Text((display.error != nil ? "缓存 · " : "") + row.preview).font(Design.caption))
                        .fixedSize()
                    VStack(alignment: .leading, spacing: Design.smallGap) {
                        (Text("重置预告：").font(Design.title)
                         + Text((display.error != nil ? "缓存 · " : "") + row.previewTime).font(Design.caption))
                            .lineLimit(1)
                        Text(row.label).font(Design.caption).lineLimit(1)
                    }
                } else {
                    (Text("重置预告：").font(Design.title) + Text(emptyText).font(Design.caption))
                        .lineLimit(2)
                }
            }
            .foregroundStyle(display.error == nil && display.cacheError == nil ? Design.label : Design.stateText(.warn))
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(details(row))
            Button { NSWorkspace.shared.open(CodexResetDisplay.sourceURL) } label: {
                Text("查看来源 ↗").font(Design.caption).foregroundStyle(Design.blue)
            }.buttonStyle(.plain).fixedSize()
        }
    }
    private func details(_ row: CodexResetRow?) -> String {
        (["AIHOT 估算，非官方承诺。公开消息不代表当前账号已到账。", row?.preview, row?.status, row?.scope,
          row?.announcement, row?.estimate, display.siteStatus, display.error, display.cacheError]
            + [display.fetchedAt.map { "获取：" + DisplayDate.format($0, pattern: "M/d HH:mm") },
               display.verifiedAt.map { "站点核验：" + DisplayDate.format($0, pattern: "M/d HH:mm") }])
            .compactMap { $0 }.joined(separator: "\n")
    }
}
