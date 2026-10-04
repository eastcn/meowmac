import Foundation
import MeowMacCore
import MeowMacSystem

enum SensorTests {
    static var tests: [(String, () -> Bool)] { [
        ("Core.Sensors/SMC 字节解码", { decoding() }),
        ("Core.Sensors/温度归并与异常值", { temperatures() }),
        ("Core.Sensors/风扇数量最大值与失败", { fans() }),
        ("Core.Sensors/阈值配置默认与覆盖", { config() }),
        ("System.Sensors.Live/本机读数耗时与负载升温", { live() }),
    ] }

    static func decoding() -> Bool {
        var float = Float(52.75)
        let floatBytes = withUnsafeBytes(of: &float) { Array($0) }
        return SMCDecoder.value(type: "flt ", bytes: floatBytes) == 52.75
            && SMCDecoder.value(type: "flt ", bytes: [0, 0]) == nil
            && SMCDecoder.value(type: "fpe2", bytes: [0x1F, 0x40]) == 2000
            && SMCDecoder.value(type: "sp78", bytes: [0x2A, 0x80]) == 42.5
            && SMCDecoder.value(type: "sp78", bytes: [0xFF, 0x00]) == -1
            && SMCDecoder.value(type: "ui8 ", bytes: [2]) == 2
            && SMCDecoder.value(type: "ui16", bytes: [0x01, 0x00]) == 256
            && SMCDecoder.value(type: "ui32", bytes: [0, 0, 0x0A, 0x00]) == 2560
            && SMCDecoder.value(type: "ch8*", bytes: [65]) == nil
            && SMCDecoder.string(SMCDecoder.fourCC("F0Ac")) == "F0Ac"
            && SMCDecoder.fourCC("#KEY") == 0x234B_4559
    }

    static func temperatures() -> Bool {
        // CPU 只取 Tp*，过滤超范围读数；GPU 取 Tg*；其他前缀忽略。
        let smc: [String: Double] = ["Tp00": 50, "Tp04": 60, "Tp08": -9000, "Tp0C": 400, "Te04": 90, "Tg0U": 40, "Tg0X": 44, "TB0T": 30]
        let hid: [String: Double] = ["PMU tdie1": 70, "PMU tdev1": -9000]
        let normal = SensorAggregator.make(smcTemperatures: smc, hidTemperatures: hid, fanCount: 1, fans: [(0, 6000)])
        guard normal.cpuAverageCelsius == 55, normal.cpuMaxCelsius == 60, normal.cpuSource == .smc,
              normal.gpuAverageCelsius == 42, normal.failure == nil else { return false }
        // 没有 Tp* 时改用 IOHID 的 PMU tdie*，并过滤无效的 tdev。
        let hidOnly = SensorAggregator.make(smcTemperatures: ["Tg0U": 40], hidTemperatures: ["PMU tdie1": 48, "PMU tdie2": 52, "PMU tdev1": -9199, "NAND CH0 temp": 39],
                                            fanCount: 0, fans: [])
        guard hidOnly.cpuAverageCelsius == 50, hidOnly.cpuMaxCelsius == 52, hidOnly.cpuSource == .iohid else { return false }
        // 所有 Tp* 都无效时同样改用 IOHID。
        let invalid = SensorAggregator.make(smcTemperatures: ["Tp00": 0], hidTemperatures: ["PMU tdie1": 45], fanCount: nil, fans: [])
        // GPU 读不到时只这一项为空。
        let noGPU = SensorAggregator.make(smcTemperatures: ["Tp00": 50], hidTemperatures: [:], fanCount: 0, fans: [])
        return invalid.cpuSource == .iohid && invalid.cpuAverageCelsius == 45
            && noGPU.gpuAverageCelsius == nil && noGPU.cpuAverageCelsius == 50 && noGPU.failure == nil
    }

    static func fans() -> Bool {
        let none = SensorAggregator.make(smcTemperatures: ["Tp00": 50], hidTemperatures: [:], fanCount: 0, fans: [])
        let unreadable = SensorAggregator.make(smcTemperatures: ["Tp00": 50], hidTemperatures: [:], fanCount: nil, fans: [])
        let noActual = SensorAggregator.make(smcTemperatures: [:], hidTemperatures: [:], fanCount: 1, fans: [(nil, 6000)])
        guard none.fans == [], none.leadingFan == nil, none.fanHigh(threshold: 0.8) == nil,
              unreadable.fans == nil, unreadable.fanHigh(threshold: 0.8) == nil,
              noActual.fans == nil, noActual.failure == "没有匹配的传感器" else { return false }
        // 多风扇：显示比例最高的，任一风扇超过阈值即判定。
        let two = SensorAggregator.make(smcTemperatures: [:], hidTemperatures: [:], fanCount: 2, fans: [(3000, 6000), (4500, 5000)])
        guard two.fans?.count == 2, two.leadingFan == FanReading(rpm: 4500, maxRPM: 5000), two.fanHigh(threshold: 0.8) == true,
              two.fanHigh(threshold: 0.9) == false else { return false }
        // 最大值缺失或为 0：不算比例，也不判定该风扇；只剩这类风扇时不判定。
        let noMax = SensorAggregator.make(smcTemperatures: [:], hidTemperatures: [:], fanCount: 2, fans: [(5000, nil), (2000, 0)])
        guard noMax.leadingFan?.rpm == 5000, noMax.leadingFan?.fraction == nil, noMax.fanHigh(threshold: 0.8) == nil else { return false }
        let mixed = SensorAggregator.make(smcTemperatures: [:], hidTemperatures: [:], fanCount: 2, fans: [(5900, nil), (1000, 5000)])
        guard mixed.leadingFan == FanReading(rpm: 1000, maxRPM: 5000), mixed.fanHigh(threshold: 0.8) == false else { return false }
        // FNum 大于实际给出的风扇数时，只用读到的。
        let partial = SensorAggregator.make(smcTemperatures: [:], hidTemperatures: [:], fanCount: 3, fans: [(1200, 6000)])
        // 全部失败：保留调用方的原因。
        let failed = SensorAggregator.make(smcTemperatures: [:], hidTemperatures: [:], fanCount: nil, fans: [], failure: "无法连接 SMC 传感器服务")
        return partial.fans?.count == 1
            && failed == SensorReadings.unavailable("无法连接 SMC 传感器服务")
            && FanReading(rpm: 0, maxRPM: 6000).fraction == 0
    }

    static func config() -> Bool {
        let defaults = LocalConfig()
        guard defaults.fanHighFraction == 0.8, defaults.fanHighSeconds == 300,
              let old = try? JSONDecoder().decode(LocalConfig.self, from: Data(#"{"schemaVersion":1,"fairThermalSeconds":120}"#.utf8)),
              old.fanHighFraction == 0.8, old.fanHighSeconds == 300, old.fairThermalSeconds == 120,
              let custom = try? JSONDecoder().decode(LocalConfig.self, from: Data(#"{"fanHighFraction":0.7,"fanHighSeconds":60}"#.utf8)) else { return false }
        return custom.fanHighFraction == 0.7 && custom.fanHighSeconds == 60
    }

    /// 本机实测。原值只写 build/acceptance/sensors/，不进仓库。
    static func live() -> Bool {
        let reader = SensorReader()
        var start = Date()
        let first = reader.sample()
        let firstMilliseconds = Date().timeIntervalSince(start) * 1000
        var durations: [Double] = []
        for _ in 0..<10 {
            start = Date(); _ = reader.sample(); durations.append(Date().timeIntervalSince(start) * 1000)
        }
        let steady = durations.reduce(0, +) / Double(durations.count)
        let before = reader.sample()
        // 进程内负载：每个核心一个线程，60 秒后自行结束，不启动或结束任何进程。
        let deadline = Date().addingTimeInterval(60)
        let group = DispatchGroup()
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            group.enter()
            Thread.detachNewThread {
                var value = 0.0
                while Date() < deadline { for index in 0..<10_000 { value += sin(Double(index)) } }
                if value == .infinity { print(value) }
                group.leave()
            }
        }
        var hottest = reader.sample()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 5)
            let current = reader.sample()
            if (current.cpuAverageCelsius ?? 0) > (hottest.cpuAverageCelsius ?? 0) { hottest = current }
        }
        group.wait()
        let rise = (hottest.cpuAverageCelsius ?? 0) - (before.cpuAverageCelsius ?? 0)
        let report: [String: Any] = [
            "firstSampleMilliseconds": firstMilliseconds, "steadySampleMilliseconds": steady,
            "first": describe(first), "beforeLoad": describe(before), "hottestUnderLoad": describe(hottest), "cpuRise": rise,
        ]
        do {
            let directory = URL(fileURLWithPath: "build/acceptance/sensors")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("live.json"))
        } catch { print("实测记录写入失败：\(error)"); return false }
        print(String(format: "首次 %.1f ms，平均 %.1f ms，负载升温 %.1f °C", firstMilliseconds, steady, rise))
        guard let cpu = first.cpuAverageCelsius, (20...110).contains(cpu), first.gpuAverageCelsius != nil,
              let fan = first.leadingFan, (fan.maxRPM ?? 0) > 0 else { print("读数不完整"); return false }
        return steady < 20 && rise > 2
    }

    private static func describe(_ value: SensorReadings) -> [String: Any] {
        func json(_ number: Double?) -> Any { number ?? NSNull() }
        return [
            "cpuAverage": json(value.cpuAverageCelsius), "cpuMax": json(value.cpuMaxCelsius),
            "cpuSource": value.cpuSource?.rawValue ?? NSNull(), "gpuAverage": json(value.gpuAverageCelsius),
            "fans": value.fans.map { $0.map { ["rpm": $0.rpm, "max": json($0.maxRPM)] } } ?? NSNull(),
            "failure": value.failure ?? NSNull(),
        ]
    }
}
