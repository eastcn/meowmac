import Foundation

public struct CatMotion {
    private var smoothed: Double = 0
    private let alpha: Double

    public init(alpha: Double = 0.25) { self.alpha = alpha }

    public mutating func update(cpu: Double, pressure: MemoryPressure, config: LocalConfig) -> Double {
        let raw = max(cpu, pressure.load(config: config))
        let load = raw.isFinite ? min(1, max(0, raw)) : 0
        smoothed = alpha * load + (1 - alpha) * smoothed
        return Self.frameInterval(load: smoothed, config: config)
    }

    public static func frameInterval(load: Double, config: LocalConfig) -> Double {
        let bounded = load.isFinite ? min(1, max(0, load)) : 0
        let idle = config.idleFrameSeconds.isFinite && config.fullFrameSeconds.isFinite &&
            config.idleFrameSeconds > config.fullFrameSeconds && config.fullFrameSeconds > 0 ? config.idleFrameSeconds : 0.5
        let full = config.idleFrameSeconds.isFinite && config.fullFrameSeconds.isFinite &&
            config.idleFrameSeconds > config.fullFrameSeconds && config.fullFrameSeconds > 0 ? config.fullFrameSeconds : 0.05
        let middle = idle + 0.7 * (full - idle)
        return bounded <= 0.5 ? idle + (middle - idle) * (bounded / 0.5) :
            middle + (full - middle) * ((bounded - 0.5) / 0.5)
    }
}
