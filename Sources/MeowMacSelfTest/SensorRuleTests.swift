import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum SensorRuleTests {
    static var tests: [(String, @MainActor () -> Bool)] { [
        ("Core.Sensors/风扇持续计时", { tracker() }),
        ("Core.Sensors/风扇降温边界与档位", { reminders() }),
        ("UI.Sensors/降温卡片图例与猫", { panel() }),
    ] }

    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func snapshot(fans: [FanReading]?, thermal: ThermalLevel = .nominal) -> SystemSnapshot {
        SystemSnapshot(timestamp: now, cpuUsage: 0.3, memoryPressure: .normal, swapUsedBytes: 0, diskAvailableBytes: 400, diskTotalBytes: 500,
                       networkReceivedBytesPerSecond: 0, networkSentBytesPerSecond: 0,
                       battery: BatteryMetrics(temperatureCelsius: 32, systemPowerWatts: 10), thermal: thermal,
                       sensors: SensorReadings(cpuAverageCelsius: 80, cpuMaxCelsius: 90, cpuSource: .smc, gpuAverageCelsius: 70, fans: fans))
    }

    static func tracker() -> Bool {
        let config = LocalConfig()
        let high = snapshot(fans: [FanReading(rpm: 5000, maxRPM: 6000)]).sensors
        let low = snapshot(fans: [FanReading(rpm: 4800, maxRPM: 6000)]).sensors
        let start = FanHighTracker.next(since: nil, readings: high, at: now, config: config)
        let kept = FanHighTracker.next(since: start, readings: high, at: now.addingTimeInterval(60), config: config)
        // 恰好等于阈值不算超过；回落、读不到、最大值缺失都重置计时。
        return start == now && kept == now
            && FanHighTracker.next(since: start, readings: low, at: now, config: config) == nil
            && FanHighTracker.next(since: start, readings: nil, at: now, config: config) == nil
            && FanHighTracker.next(since: start, readings: .unavailable("无法连接"), at: now, config: config) == nil
            && FanHighTracker.next(since: start, readings: snapshot(fans: [FanReading(rpm: 6000, maxRPM: nil)]).sensors, at: now, config: config) == nil
            && FanHighTracker.next(since: start, readings: snapshot(fans: []).sensors, at: now, config: config) == nil
    }

    static func reminders() -> Bool {
        let config = LocalConfig()
        func health(_ system: SystemSnapshot, fanSince: Date?, fairSince: Date? = nil) -> HealthSummary {
            HealthEvaluator.evaluate(HealthInputs(system: system, energy: nil, quotaUsedPercent: [], network: .green, failedSources: [:],
                                                  fairSince: fairSince, now: now, fanHighSince: fanSince), config: config)
        }
        func cooling(_ system: SystemSnapshot, fanSince: Date?, fairSince: Date? = nil) -> Reminder? {
            ReminderCollector.collect(HealthInputs(system: system, energy: nil, quotaUsedPercent: [], network: .green, failedSources: [:],
                                                   fairSince: fairSince, now: now, fanHighSince: fanSince), config: config)
                .reminders.first { $0.kind == .cooling }
        }
        let high = snapshot(fans: [FanReading(rpm: 5000, maxRPM: 6000)])
        // 299 秒不触发，300 秒触发；只加降温标记，档位保持正常，不可暂缓。
        guard cooling(high, fanSince: now.addingTimeInterval(-299)) == nil, !health(high, fanSince: now.addingTimeInterval(-299)).coolingHint,
              let fan = cooling(high, fanSince: now.addingTimeInterval(-300)), fan.detail == "风扇转速持续超过最大值的 80%", !fan.canSnooze,
              case let summary = health(high, fanSince: now.addingTimeInterval(-300)), summary.coolingHint, summary.level == .normal else { print("边界失败"); return false }
        // 热状态读不到时风扇规则照样生效。
        guard cooling(snapshot(fans: [FanReading(rpm: 5000, maxRPM: 6000)], thermal: .unavailable), fanSince: now.addingTimeInterval(-600)) != nil else { return false }
        // 当前已回落、读不到或最大值缺失时，即使计时还在也不触发。
        guard cooling(snapshot(fans: [FanReading(rpm: 4000, maxRPM: 6000)]), fanSince: now.addingTimeInterval(-600)) == nil,
              cooling(snapshot(fans: nil), fanSince: now.addingTimeInterval(-600)) == nil,
              cooling(snapshot(fans: [FanReading(rpm: 6000, maxRPM: nil)]), fanSince: now.addingTimeInterval(-600)) == nil else { return false }
        // 多风扇任一超过即触发。
        guard cooling(snapshot(fans: [FanReading(rpm: 1000, maxRPM: 6000), FanReading(rpm: 4900, maxRPM: 5000)]), fanSince: now.addingTimeInterval(-300)) != nil else { return false }
        // 与热状态同时满足：只有一条降温提醒，写热状态。
        let both = ReminderCollector.collect(HealthInputs(system: snapshot(fans: [FanReading(rpm: 5000, maxRPM: 6000)], thermal: .fair), energy: nil,
            quotaUsedPercent: [], network: .green, failedSources: [:], fairSince: now.addingTimeInterval(-300), now: now,
            fanHighSince: now.addingTimeInterval(-300)), config: config).reminders.filter { $0.kind == .cooling }
        // 调高阈值后同一转速不触发。
        var strict = config; strict.fanHighFraction = 0.9
        let strictCooling = ReminderCollector.collect(HealthInputs(system: high, energy: nil, quotaUsedPercent: [], network: .green, failedSources: [:],
            fairSince: nil, now: now, fanHighSince: now.addingTimeInterval(-600)), config: strict).reminders.contains { $0.kind == .cooling }
        return both.count == 1 && both[0].detail == "热状态 fair 持续偏高" && !strictCooling
    }

    static func panel() -> Bool {
        let state = PanelPreviewRenderer.sensorState(.cooling)
        let display = state.sensorDisplay
        guard state.health.coolingHint, state.health.level == .normal,
              state.coolingLegend == "风扇超过最大值 80% 已持续 6 分钟，达到‘建议降温’条件",
              display.columns[2].tone == .warn, display.columns[2].detail.hasSuffix("% · 已持续 6 分钟"),
              display.footer == "风扇超过最大值 80% 已持续 6 分钟，达到“建议降温”条件" else {
            print("降温面板：\(state.coolingLegend) \(display)"); return false
        }
        // 快照带上同一份显示值。
        guard let encoded = try? JSONEncoder().encode(PanelSnapshot(state: state)),
              let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let system = object["system"] as? [String: Any], let sensors = system["sensors"] as? [String: Any],
              sensors["footer"] as? String == display.footer, system["coolingLegend"] as? String == state.coolingLegend,
              system["fanHighSince"] != nil, ((system["latest"] as? [String: Any])?["sensors"] as? [String: Any])?["fans"] != nil else { return false }
        // 猫的形态不变：与同一负载的未触发状态相同。
        let calm = PanelPreviewRenderer.sensorState(.cooling); calm.fanHighSince = nil
        let hot = state.catDisplay(reducedMotion: false), base = calm.catDisplay(reducedMotion: false)
        guard hot.level == base.level, hot.template == base.template, hot.stopped == base.stopped, !calm.health.coolingHint else { return false }
        // 未满 5 分钟不改写。
        let early = PanelPreviewRenderer.sensorState(.cooling); early.fanHighSince = early.now().addingTimeInterval(-120)
        guard !early.health.coolingHint, early.sensorDisplay.columns[2].tone == .normal,
              early.coolingLegend == "热状态 fair 及以上的时段" else { return false }
        // 热状态和风扇同时满足时写热状态。
        let both = PanelPreviewRenderer.sensorState(.cooling)
        both.fairSince = both.now().addingTimeInterval(-600)
        var snapshot = both.snapshot!
        snapshot = SystemSnapshot(timestamp: snapshot.timestamp, cpuUsage: snapshot.cpuUsage, memoryPressure: snapshot.memoryPressure,
                                  swapUsedBytes: snapshot.swapUsedBytes, diskAvailableBytes: snapshot.diskAvailableBytes, diskTotalBytes: snapshot.diskTotalBytes,
                                  networkReceivedBytesPerSecond: 0, networkSentBytesPerSecond: 0, battery: snapshot.battery, thermal: .fair,
                                  memoryUsedBytes: snapshot.memoryUsedBytes, memoryTotalBytes: snapshot.memoryTotalBytes,
                                  memoryPressurePercent: snapshot.memoryPressurePercent, sensors: snapshot.sensors)
        both.snapshot = snapshot
        return both.coolingLegend == "热状态 fair 已持续 10 分钟，达到‘建议降温’条件"
    }
}
