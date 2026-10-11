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
            if let latest = display.latest {
                previewRow(latest, title: "最近确认：")
            }
            if let timing = display.timingSummary() {
                Text(timing).font(Design.tiny).foregroundStyle(.secondary)
                    .help(display.details(for: nil))
            }
            if let status = display.siteStatus, status != "站点采集正常" {
                Text(status).font(Design.tiny).foregroundStyle(Design.stateText(.warn))
                    .help(display.details(for: nil))
            }
        }.fixedSize(horizontal: false, vertical: true).monospacedDigit()
    }
    private var emptyText: String {
        if display.error != nil { return display.fetchedAt == nil ? "获取失败" : "获取失败 · 暂无预告（缓存）" }
        return display.fetchedAt == nil ? "等待采集" : "暂无"
    }
    private func previewRow(_ row: CodexResetRow?, title: String = "重置预告：") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.gap) {
            ViewThatFits(in: .horizontal) {
                if let row {
                    (Text(title).font(Design.title)
                     + Text((display.error != nil ? "缓存 · " : "") + row.preview).font(Design.caption))
                        .fixedSize()
                    VStack(alignment: .leading, spacing: Design.smallGap) {
                        (Text(title).font(Design.title)
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
            .help(display.details(for: row))
            Button { NSWorkspace.shared.open(CodexResetDisplay.sourceURL) } label: {
                Text("查看来源 ↗").font(Design.caption).foregroundStyle(Design.blue)
            }.buttonStyle(.plain).fixedSize()
        }
    }
}
