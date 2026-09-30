import Foundation

public struct CatMotion {
    private var smoothed: Double = 0
    private let alpha: Double

    public init(alpha: Double = 0.25) { self.alpha = alpha }

    public mutating func update(cpu: Double, pressure: MemoryPressure, config: LocalConfig) -> Double {
        let load = min(1, max(0, max(cpu, pressure.load(config: config))))
        smoothed = alpha * load + (1 - alpha) * smoothed
        return Self.frameInterval(load: smoothed, config: config)
    }

    public static func frameInterval(load: Double, config: LocalConfig) -> Double {
        let bounded = min(1, max(0, load))
        return config.idleFrameSeconds + (config.fullFrameSeconds - config.idleFrameSeconds) * bounded
    }
}
