import SwiftUI
import Charts
import MeowMacCore

struct QuotaProvidersCard: View {
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(QuotaProvider.allCases, id: \.rawValue) { provider in
                VStack(alignment: .leading, spacing: 5) {
                    Text(provider.rawValue.capitalized).fontWeight(.semibold)
                    if let snapshot = state.quotas[provider] {
                        ForEach(snapshot.windows.indices, id: \.self) { index in
                            let window = snapshot.windows[index]
                            ProgressView(value: max(0, min(1, 1 - window.usedPercent / 100))) {
                                Text("剩余 \(Int(100 - window.usedPercent))% · \(window.windowMinutes.map { "\($0) 分钟" } ?? "窗口")")
                            }
                            if let reset = window.resetsAt { Text("重置：\(reset, style: .relative)").font(.caption2) }
                        }
                        if let pace = snapshot.paceSummary { Text(pace).font(.caption2) }
                        if let credits = snapshot.credits { Text(String(format: "Credits %.2f", credits)).font(.caption2) }
                        Text("更新：\(snapshot.updatedAt, style: .time)").font(.caption2).foregroundStyle(.secondary)
                        let history = (state.quotaHistory[provider] ?? []).filter { $0.sampledAt >= Date().addingTimeInterval(-7 * 86400) }
                        if !history.isEmpty {
                            Chart(history.indices, id: \.self) { index in
                                let point = history[index]
                                LineMark(x: .value("时间", point.sampledAt), y: .value("已用", point.usedPercent))
                                    .foregroundStyle(by: .value("窗口", point.windowMinutes.map(String.init) ?? "未知"))
                            }
                            .chartYScale(domain: 0...100)
                            .frame(height: 80)
                        }
                    } else if let error = state.quotaErrors[provider] {
                        Text("采集失败：\(error)").foregroundStyle(.orange)
                    } else { Text("等待采集").foregroundStyle(.secondary) }
                }
                Divider()
            }
        }.font(.caption)
    }
}

struct CostCard: View {
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([QuotaProvider.claude, .codex], id: \.rawValue) { provider in
                Text(provider.rawValue.capitalized).font(.caption).fontWeight(.semibold)
                let days = state.costs[provider] ?? []
                if days.isEmpty { Text("暂无花费数据").font(.caption).foregroundStyle(.secondary) }
                else {
                    Chart(days, id: \.date) { day in
                        BarMark(x: .value("日期", day.date), y: .value("花费", day.totalCost))
                    }
                    .frame(height: 90)
                    Text(String(format: "30 天合计 %.2f", days.reduce(0) { $0 + $1.totalCost }))
                        .font(.caption2)
                }
            }
        }
    }
}
