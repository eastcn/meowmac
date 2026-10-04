import Foundation
import MeowMacCore

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

    /// 温度一行的副信息：最热核心和 GPU。读不到时写原因。
    var temperatureDetail: String {
        guard let sensors = snapshot?.sensors else { return snapshot == nil ? "等待采集" : "SoC 不可用" }
        var parts: [String] = []
        if let hottest = sensors.cpuMaxCelsius { parts.append(String(format: "最热 %.1f", hottest)) }
        if let gpu = sensors.gpuAverageCelsius { parts.append(String(format: "GPU %.1f", gpu)) }
        return parts.isEmpty ? "SoC 不可用" : parts.joined(separator: " · ")
    }

    /// 风扇一行的副信息和是否达到降温条件。
    var fanDetail: (text: String, warn: Bool) {
        guard let sensors = snapshot?.sensors, let leading = sensors.leadingFan else {
            return (fanCoolingPending ? "待确认" : snapshot == nil ? "等待采集" : "不可用", false)
        }
        let count = (sensors.fans?.count ?? 0) > 1 ? " · 共 \(sensors.fans!.count) 个" : ""
        if health.coolingHint, let minutes = fanCoolingMinutes, let fraction = leading.fraction {
            return (Self.percent(fraction) + " · 已持续 \(minutes) 分钟" + count, true)
        }
        if leading.rpm == 0 { return ("静止" + count, false) }
        guard let fraction = leading.fraction else { return ("最大值未知" + count, false) }
        return ("最大值的 " + Self.percent(fraction) + count, false)
    }

    /// 传感器读不到时写在悬停提示里的原因。
    var sensorHelp: String {
        guard let sensors = snapshot?.sensors else { return "等待采集" }
        let source = sensors.cpuSource == .iohid ? "SMC 与 IOHID" : "SMC"
        if let failure = sensors.failure { return "读不到 SMC：\(failure)。其他系统数据不受影响" }
        return "来源：\(source)，非公开接口，新芯片上可能读不到"
    }

    nonisolated static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
}
