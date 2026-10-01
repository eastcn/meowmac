import Foundation
import Darwin
import MeowMacCore
import MeowMacSystem
import MeowMacUI

@MainActor
enum MemoryTests {
    static func usage() -> Bool {
        var statistics = vm_statistics64()
        statistics.internal_page_count = 1_000
        statistics.purgeable_count = 200
        statistics.wire_count = 300
        statistics.compressor_page_count = 100
        statistics.active_count = 4_000
        statistics.inactive_count = 8_000
        let expected: UInt64 = 1_200 * 16_384
        guard SystemCollector.usedMemoryBytes(statistics, pageSize: 16_384) == expected else { return false }
        statistics.inactive_count = 80_000
        guard SystemCollector.usedMemoryBytes(statistics, pageSize: 16_384) == expected else { return false }
        statistics.purgeable_count = 2_000
        return SystemCollector.usedMemoryBytes(statistics, pageSize: 16_384) == 400 * 16_384
    }

    static func pressure() -> Bool {
        guard SystemCollector.pressurePercent(availableLevel: 45) == 55,
              SystemCollector.pressurePercent(availableLevel: 100) == 0,
              SystemCollector.pressurePercent(availableLevel: 0) == 100,
              SystemCollector.pressurePercent(availableLevel: nil) == nil else { return false }
        let state = PanelPreviewRenderer.syntheticState()
        let metric = state.overviewMetrics[1]
        guard metric.numericValue == 55, metric.fraction == 0.55, metric.value == "55%",
              metric.detail == "已用 11 / 16 GB" else { return false }
        state.snapshot = SystemSnapshot(timestamp: state.now(), cpuUsage: nil, memoryPressure: .unavailable,
            swapUsedBytes: nil, diskAvailableBytes: nil, diskTotalBytes: nil,
            networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
            battery: BatteryMetrics(temperatureCelsius: nil, systemPowerWatts: nil), thermal: .nominal)
        return state.overviewMetrics[1].value == "—" && state.overviewMetrics[1].numericValue == nil
    }

    static func ignoredAssertions() -> Bool {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let assertion = SleepAssertion(pid: 43, type: "PreventSystemSleep", startedAt: now.addingTimeInterval(-10_800))
        var tracker = EnergyTracker()
        let energy = tracker.evaluate(processes: [], assertions: [assertion], pressure: .normal, now: now, config: LocalConfig())
        guard energy.longAssertions.isEmpty else { return false }
        let state = PanelPreviewRenderer.syntheticState()
        // 即使旧调用者传入断言，诊断和健康判定也不使用它。
        state.energy = EnergyDiagnosis(topFive: [], runaway: [], longAssertions: [assertion], prolongedMemoryPressure: false)
        return state.diagnosisRows.isEmpty && state.health.issues.allSatisfy { !$0.message.contains("休眠") }
    }
}
