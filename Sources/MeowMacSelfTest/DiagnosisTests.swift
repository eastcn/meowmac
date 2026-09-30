import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum DiagnosisTests {
    static func rows() -> Bool {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let config = LocalConfig()
        let state = PanelState(configResult: ConfigLoadResult(config: config, error: nil))
        state.now = { now }
        state.snapshot = SystemSnapshot(timestamp: now, cpuUsage: 0.6, memoryPressure: .critical, swapUsedBytes: 0,
            diskAvailableBytes: 50, diskTotalBytes: 100, networkReceivedBytesPerSecond: 0, networkSentBytesPerSecond: 0,
            battery: BatteryMetrics(temperatureCelsius: 35, systemPowerWatts: 8), thermal: .nominal)
        let process = ProcessEnergy(pid: 42, name: "ExampleWorker", cpuPercent: 240, impact: 30)
        let assertion = SleepAssertion(pid: 43, type: "PreventSystemSleep", startedAt: now.addingTimeInterval(-7200), processName: "ExampleSync")
        var tracker = EnergyTracker()
        state.energy = tracker.evaluate(processes: [process], assertions: [assertion], pressure: .critical,
            now: now.addingTimeInterval(-900), config: config)
        guard state.diagnosisRows.isEmpty else { return false }
        state.energy = tracker.evaluate(processes: [process], assertions: [assertion], pressure: .critical, now: now, config: config)
        let rows = state.diagnosisRows
        guard rows.count == 3 else { return false }
        let runaway = rows[0], sleep = rows[1], memory = rows[2]
        return runaway.pid == 42 && runaway.name == "ExampleWorker" && runaway.duration == "已持续 15 分钟"
            && runaway.value == "240%" && runaway.detail.contains("失控进程")
            && sleep.pid == 43 && sleep.name == "ExampleSync" && sleep.value == "2 小时 0 分"
            && sleep.detail == "阻止系统休眠" && sleep.duration.hasPrefix("从 ")
            && memory.pid == nil && memory.name == "内存压力" && memory.duration == "已持续 15 分钟"
            && memory.value == "严重" && memory.level == .severe
    }
}
