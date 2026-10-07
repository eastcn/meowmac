import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum ApplicationCadenceTests {
    static func lifecycle() async -> Bool {
        var level = HealthLevel.normal
        var frames: [Int] = [], samples = 0
        let cadence = ApplicationCadence(display: {
            CatDisplay(id: "fixture", name: "示例", rendering: "template", level: level,
                load: 0.24, frameInterval: 0.02, speedLines: false, template: true,
                stopped: level == .severe, reducedMotion: false)
        }, updateImage: { frames.append($0) }, sample: { samples += 1 })
        cadence.frameInterval = 0.02
        cadence.startSampling(); cadence.scheduleFrame()
        do {
            try await Task.sleep(nanoseconds: 150_000_000)
            guard frames.count >= 2, Set(frames).count >= 2, samples == 0 else { return false }
            level = .severe; let frozen = cadence.frame
            try await Task.sleep(nanoseconds: 150_000_000)
            guard cadence.frame == frozen else { return false }
            level = .normal
            cadence.screenSleeping = true; let sleeping = cadence.frame
            try await Task.sleep(nanoseconds: 150_000_000)
            guard cadence.frame == sleeping else { return false }
            cadence.screenSleeping = false
            try await Task.sleep(nanoseconds: 1_700_000_000)
            guard samples == 1, cadence.frame != sleeping || Set(frames.suffix(5)).count > 1 else { return false }
            cadence.stop()
            try await Task.sleep(nanoseconds: 50_000_000)
            let count = frames.count
            try await Task.sleep(nanoseconds: 100_000_000)
            return frames.count == count && samples == 1
        } catch { cadence.stop(); return false }
    }
    static func systemUpdate() -> Bool {
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        state.now = { time }
        var failed: [String] = [], recorded = 0
        let latest = SystemSnapshot(timestamp: time, cpuUsage: nil, memoryPressure: .unavailable,
            swapUsedBytes: nil, diskAvailableBytes: nil, diskTotalBytes: nil,
            networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
            battery: BatteryMetrics(temperatureCelsius: nil, systemPowerWatts: nil), thermal: .fair)
        SystemUpdatePath.apply(latest, state: state, hasBaseline: false,
            sourceFailed: { failed.append($0) }, recordNetwork: { _ in recorded += 1 })
        guard state.failures.isEmpty, state.fairSince == time, state.snapshot?.timestamp == time,
              state.lastRefreshedAt == time, recorded == 1 else { return false }
        for _ in 0..<state.configResult.config.sourceFailureCount {
            SystemUpdatePath.apply(latest, state: state, hasBaseline: true,
                sourceFailed: { failed.append($0) }, recordNetwork: { _ in recorded += 1 })
        }
        return Set(failed) == Set(["CPU", "内存压力", "磁盘", "电池"])
            && state.failures["CPU"] == state.configResult.config.sourceFailureCount
            && state.fairSince == time && !state.allReminders.isEmpty
    }
}
