import AppKit
import MeowMacCore

/// 应用与显式测量共用的定时器路径。观察者只由测量入口注入。
@MainActor
public final class ApplicationCadence {
    public var frame = 0
    public var frameInterval = 0.5
    public var screenSleeping = false
    public var observe: ((String) -> Void)?
    private var frameTimer: Timer?
    private var sampleTimer: Timer?
    private let display: () -> CatDisplay
    private let updateImage: (Int) -> Void
    private let sample: () -> Void

    public init(display: @escaping () -> CatDisplay, updateImage: @escaping (Int) -> Void, sample: @escaping () -> Void) {
        self.display = display; self.updateImage = updateImage; self.sample = sample
    }
    public func startSampling() {
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe?("sampleTimer")
                self.sample()
            }
        }
    }
    public func scheduleFrame() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe?("frameTimer")
                let display = self.display()
                self.frame = display.nextFrame(self.frame, sleeping: self.screenSleeping)
                self.updateImage(self.frame)
                self.scheduleFrame()
            }
        }
    }
    public func stop() { sampleTimer?.invalidate(); frameTimer?.invalidate() }
}

/// 保留采集结果发布的顺序、失败语义、历史和规则输入。
@MainActor
public enum SystemUpdatePath {
    public static func apply(_ latest: SystemSnapshot, state: PanelState, hasBaseline: Bool,
                             thermalChanged: Bool = false, sourceFailureCount: Int? = nil,
                             sourceFailed: (String) -> Void = { _ in },
                             recordNetwork: (SystemSnapshot) -> Void = { _ in }) {
        state.snapshot = latest
        if hasBaseline {
            for (source, failed) in [("CPU", latest.cpuUsage == nil),
                                     ("内存压力", latest.memoryPressure == .unavailable),
                                     ("磁盘", latest.diskAvailableBytes == nil),
                                     ("电池", latest.battery.temperatureCelsius == nil)] {
                state.failures[source] = failed ? (state.failures[source] ?? 0) + 1 : 0
                if state.failures[source] == (sourceFailureCount ?? state.configResult.config.sourceFailureCount) { sourceFailed(source) }
            }
        }
        state.chartHistory.append(latest, force: thermalChanged)
        recordNetwork(latest)
        state.lastRefreshedAt = latest.timestamp
        if latest.thermal == .fair {
            if state.fairSince == nil { state.fairSince = latest.timestamp }
        } else { state.fairSince = nil }
        let fanHighSince = FanHighTracker.next(since: state.fanHighSince, readings: latest.sensors, at: latest.timestamp,
            config: state.configResult.config.alertRules.detectorConfig(state.configResult.config))
        if fanHighSince != state.fanHighSince { state.fanHighSince = fanHighSince }
    }
}
