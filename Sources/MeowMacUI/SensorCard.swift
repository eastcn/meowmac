import SwiftUI
import MeowMacCore

public struct SensorColumnDisplay: Codable, Equatable {
    public enum Tone: String, Codable { case normal, warn, unavailable }
    public let name: String
    public let value: String
    public let unit: String?
    public let detail: String
    public let tone: Tone
}

public struct SensorCardDisplay: Codable, Equatable {
    public let columns: [SensorColumnDisplay]
    public let footer: String
}

public extension PanelState {
    /// 风扇持续高转速、已达到“建议降温”条件的分钟数；未达到时为 nil。
    var fanCoolingMinutes: Int? {
        guard let since = fanHighSince, fanJudgeable else { return nil }
        let seconds = now().timeIntervalSince(since)
        guard seconds >= configResult.config.fanHighSeconds else { return nil }
        return max(1, Int(seconds / 60))
    }

    /// 当前读数能否判定风扇是否超过阈值。
    var fanJudgeable: Bool { snapshot?.sensors?.fanHigh(threshold: configResult.config.fanHighFraction) != nil }

    /// 风扇触发的降温提醒还在，但当前读不到风扇，不能把读不到的时段算作持续超阈值（D40）。
    var fanCoolingPending: Bool {
        guard health.coolingHint, !fanJudgeable, let since = fanHighSince else { return false }
        return now().timeIntervalSince(since) >= configResult.config.fanHighSeconds
    }

    var coolingLegend: String {
        if health.coolingHint, let fairSince, now().timeIntervalSince(fairSince) >= configResult.config.fairThermalSeconds {
            return "热状态 fair 已持续 \(Int(now().timeIntervalSince(fairSince) / 60)) 分钟，达到‘建议降温’条件"
        }
        if health.coolingHint, let minutes = fanCoolingMinutes {
            return "风扇超过最大值 \(Self.percent(configResult.config.fanHighFraction)) 已持续 \(minutes) 分钟，达到‘建议降温’条件"
        }
        if fanCoolingPending { return "风扇读数暂不可用，‘建议降温’待确认" }
        if health.coolingHint {
            return "热状态 fair 已持续 \(Int(now().timeIntervalSince(fairSince ?? now()) / 60)) 分钟，达到‘建议降温’条件"
        }
        return "热状态 fair 及以上的时段"
    }

    var sensorDisplay: SensorCardDisplay {
        let source = "来源：SMC，非公开接口，新芯片上可能读不到"
        guard let snapshot else {
            return SensorCardDisplay(columns: ["CPU", "GPU", "风扇"].map { SensorColumnDisplay(name: $0, value: "—", unit: nil, detail: "", tone: .unavailable) },
                                     footer: "等待采集")
        }
        let sensors = snapshot.sensors ?? .unavailable("本次没有采集")
        func unavailable(_ name: String, _ detail: String) -> SensorColumnDisplay {
            SensorColumnDisplay(name: name, value: "不可用", unit: nil, detail: detail, tone: .unavailable)
        }
        let anything = sensors.failure == nil
        let cpu = sensors.cpuAverageCelsius.map { average in
            SensorColumnDisplay(name: "CPU", value: String(format: "%.1f", average), unit: "°C",
                                detail: sensors.cpuMaxCelsius.map { String(format: "最高 %.1f °C", $0) } ?? "", tone: .normal)
        } ?? unavailable("CPU", anything ? "没有匹配的传感器" : "")
        let gpu = sensors.gpuAverageCelsius.map {
            SensorColumnDisplay(name: "GPU", value: String(format: "%.1f", $0), unit: "°C", detail: "平均", tone: .normal)
        } ?? unavailable("GPU", anything ? "没有匹配的传感器" : "")
        let fan: SensorColumnDisplay
        let cooling = health.coolingHint ? fanCoolingMinutes : nil
        if sensors.fans == [] {
            fan = SensorColumnDisplay(name: "风扇", value: "无风扇", unit: nil, detail: "本机未报告风扇", tone: .unavailable)
        } else if let leading = sensors.leadingFan {
            let count = (sensors.fans?.count ?? 0) > 1 ? " · 共 \(sensors.fans!.count) 个" : ""
            var detail: String
            if let fraction = leading.fraction {
                detail = leading.rpm == 0 ? "静止" : "最大值的 " + Self.percent(fraction)
                if let cooling { detail = Self.percent(fraction) + " · 已持续 \(cooling) 分钟" }
            } else {
                detail = leading.rpm == 0 ? "静止" : "最大值未知"
            }
            fan = SensorColumnDisplay(name: "风扇", value: String(format: "%.0f", leading.rpm), unit: "rpm", detail: detail + count,
                                      tone: cooling == nil ? .normal : .warn)
        } else {
            fan = unavailable("风扇", "")
        }
        let footer: String
        if let failure = sensors.failure {
            footer = "读不到 SMC：\(failure)。其他系统数据不受影响"
        } else if fanCoolingPending {
            footer = "风扇读数暂不可用，“建议降温”待确认"
        } else if let cooling {
            footer = "风扇超过最大值 \(Self.percent(configResult.config.fanHighFraction)) 已持续 \(cooling) 分钟，达到“建议降温”条件"
        } else if sensors.cpuSource == .iohid {
            footer = "来源：SMC 与 IOHID，非公开接口，新芯片上可能读不到"
        } else {
            footer = source
        }
        return SensorCardDisplay(columns: [cpu, gpu, fan], footer: footer)
    }

    nonisolated static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
}

struct SensorCard: View {
    @ObservedObject var state: PanelState
    var body: some View {
        let display = state.sensorDisplay
        VStack(alignment: .leading, spacing: Design.rowGap) {
            SectionHeading(title: "传感器", detail: "实验")
            HStack(alignment: .top, spacing: Design.rowGap) {
                ForEach(display.columns.indices, id: \.self) { index in
                    column(display.columns[index]).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            SectionRule()
            Text(display.footer).font(Design.caption).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func column(_ value: SensorColumnDisplay) -> some View {
        let tint = value.tone == .warn ? Design.stateText(.warn) : Design.label
        VStack(alignment: .leading, spacing: Design.tightGap) {
            Text(value.name).font(Design.caption).foregroundStyle(Design.secondary)
            if value.tone == .unavailable {
                Text(value.value).font(Design.body).foregroundStyle(Design.secondary).lineLimit(1)
                    .frame(height: Design.sensorValueHeight, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Design.tightGap) {
                    Text(value.value).font(Design.sensorValue).monospacedDigit()
                    if let unit = value.unit { Text(unit).font(Design.caption) }
                }.foregroundStyle(tint).lineLimit(1).frame(height: Design.sensorValueHeight, alignment: .leading)
            }
            Text(value.detail.isEmpty ? " " : value.detail).font(Design.tiny)
                .foregroundStyle(value.tone == .warn ? tint : Design.secondary).lineLimit(1).truncationMode(.tail)
        }
    }
}
