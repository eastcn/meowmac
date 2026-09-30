import SwiftUI
import Charts
import MeowMacCore

struct SystemChartCard: View {
    @ObservedObject var state: PanelState

    private var points: [ChartPoint] {
        let cutoff = (state.snapshot?.timestamp ?? Date()).addingTimeInterval(Double(-state.chartMinutes * 60))
        return state.chartHistory.all.filter { $0.timestamp >= cutoff }
    }

    private var domain: ClosedRange<Date> {
        let end = state.snapshot?.timestamp ?? Date()
        return end.addingTimeInterval(Double(-state.chartMinutes * 60))...end
    }

    private func shade(_ thermal: ThermalLevel) -> Color {
        switch thermal {
        case .nominal: return .clear
        case .fair: return .yellow.opacity(0.12)
        case .serious: return .orange.opacity(0.16)
        case .critical: return .red.opacity(0.2)
        case .unavailable: return .gray.opacity(0.08)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("时间范围", selection: $state.chartMinutes) {
                Text("15 分钟").tag(15)
                Text("1 小时").tag(60)
            }.pickerStyle(.segmented)
            Text("CPU 负载").font(.caption)
            Chart(points) { point in
                RectangleMark(xStart: .value("开始", point.timestamp),
                              xEnd: .value("结束", point.timestamp.addingTimeInterval(60)),
                              yStart: .value("底", 0), yEnd: .value("顶", 1))
                    .foregroundStyle(shade(point.thermal))
                if let value = point.cpuUsage {
                    LineMark(x: .value("时间", point.timestamp), y: .value("负载", value))
                        .foregroundStyle(.blue)
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...1)
            .frame(height: 65)
            Text("整机功耗（W）").font(.caption)
            Chart(points) { point in
                RectangleMark(xStart: .value("开始", point.timestamp),
                              xEnd: .value("结束", point.timestamp.addingTimeInterval(60)),
                              yStart: .value("底", 0), yEnd: .value("顶", 40))
                    .foregroundStyle(shade(point.thermal))
                if let value = point.systemPowerWatts {
                    LineMark(x: .value("时间", point.timestamp), y: .value("功耗", value))
                        .foregroundStyle(.orange)
                }
            }
            .chartXScale(domain: domain)
            .frame(height: 65)
            Text("电池温度（°C）").font(.caption)
            Chart(points) { point in
                RectangleMark(xStart: .value("开始", point.timestamp),
                              xEnd: .value("结束", point.timestamp.addingTimeInterval(60)),
                              yStart: .value("底", 0), yEnd: .value("顶", 60))
                    .foregroundStyle(shade(point.thermal))
                if let value = point.batteryTemperatureCelsius {
                    LineMark(x: .value("时间", point.timestamp), y: .value("温度", value))
                        .foregroundStyle(.red)
                }
            }
            .chartXScale(domain: domain)
            .frame(height: 65)
            Text("热状态：\(state.snapshot?.thermal.rawValue ?? "未知")").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct EnergyCard: View {
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let energy = state.energy {
                ForEach(energy.topFive, id: \.pid) { process in
                    HStack {
                        Text(process.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "CPU %.1f%% · 影响分 %.1f", process.cpuPercent, process.impact))
                            .foregroundStyle(.secondary)
                    }.font(.caption)
                }
                if energy.topFive.isEmpty { Text("暂无进程采样").foregroundStyle(.secondary) }
                ForEach(energy.runaway, id: \.pid) { process in
                    Text("\(process.name) 持续占用 CPU \(Int((energy.runawayDurations[process.pid] ?? 0) / 60)) 分钟")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(energy.longAssertions.indices, id: \.self) { index in
                    let assertion = energy.longAssertions[index]
                    Text("进程 \(assertion.pid) 阻止休眠 \(Int(Date().timeIntervalSince(assertion.startedAt) / 60)) 分钟")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let duration = energy.memoryPressureDuration, energy.prolongedMemoryPressure {
                    Text("内存压力持续 \(Int(duration / 60)) 分钟").font(.caption).foregroundStyle(.orange)
                }
                ForEach(state.health.issues.filter { $0.tab == .system }, id: \.message) { issue in
                    Text(issue.message).font(.caption).foregroundStyle(.orange)
                }
            } else { Text("能耗诊断等待采样").foregroundStyle(.secondary) }
        }
    }
}

struct DiskCard: View {
    @ObservedObject var state: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let available = state.snapshot?.diskAvailableBytes, let total = state.snapshot?.diskTotalBytes {
                Text("剩余 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                Text("剩余 \(Int(Double(available) / Double(max(total, 1)) * 100))%")
            } else { Text("磁盘容量不可用") }
            if let record = state.lastCleaning {
                Text("上次清理：\(record.startedAt, style: .date)，释放 \(record.sizeDescription)")
            } else { Text("暂无清理记录") }
            Button("清理") { state.onClean() }
        }.font(.caption)
    }
}
