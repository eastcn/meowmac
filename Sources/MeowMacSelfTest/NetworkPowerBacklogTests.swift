import AppKit
import Foundation
import MeowMacCore
import MeowMacUI
import TunCanaryCore
import TunCanaryUI

@MainActor
enum NetworkPowerBacklogTests {
    static let tests: [(String, @MainActor () async -> Bool)] = [
        ("Backlog.Power/负值缺测与合法换算", { power() }),
        ("Backlog.Power/无效采样不进入功耗曲线", { powerChart() }),
    ]

    static func power() -> Bool {
        for invalid in [-1, -7082, Int.min] {
            let value = BatteryMetrics.parse(temperature: 3051, systemLoad: invalid)
            guard value.systemPowerWatts == nil, value.temperatureCelsius == 30.51 else {
                print("无效 SystemLoad \(invalid) 被显示为 \(String(describing: value.systemPowerWatts)) W")
                return false
            }
        }
        return BatteryMetrics.parse(temperature: nil, systemLoad: nil).systemPowerWatts == nil
            && BatteryMetrics.parse(temperature: 3051, systemLoad: 7082).systemPowerWatts == 7.082
            && BatteryMetrics.parse(temperature: nil, systemLoad: 0).systemPowerWatts == 0
    }

    static func powerChart() -> Bool {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        state.now = { now }
        for (index, load) in [8000, -7000, 9000, -1].enumerated() {
            let snapshot = SystemSnapshot(timestamp: now.addingTimeInterval(Double(index - 3) * 10), cpuUsage: 0.2,
                memoryPressure: .normal, swapUsedBytes: nil, diskAvailableBytes: nil, diskTotalBytes: nil,
                networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
                battery: .parse(temperature: 3000, systemLoad: load), thermal: .nominal)
            state.snapshot = snapshot
            state.chartHistory.append(snapshot)
        }
        guard let power = state.systemTrends.first(where: { $0.kind == "power" }) else { return false }
        guard power.current == "—", power.points.map(\.value) == [8, 9], power.segments?.count == 2,
              power.help.contains("未读到有效功耗") else {
            print("功耗当前值 \(power.current)，曲线 \(power.points.map(\.value))")
            return false
        }
        return true
    }
}
