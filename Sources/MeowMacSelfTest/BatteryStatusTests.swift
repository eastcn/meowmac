import Foundation
import MeowMacCore
import MeowMacSystem

/// 电池读数的采集与解析（D44）。夹具全部是虚构值。
enum BatteryStatusTests {
    static let tests: [(String, () -> Bool)] = [
        ("System.Battery/四种供电状态与无电池", { states() }),
        ("System.Battery/预计时间 65535、0 与负数", { estimates() }),
        ("System.Battery/放电负电流与功率换算", { power() }),
        ("System.Battery/缺字段与类型错误只影响对应项", { missingAndWrongTypes() }),
        ("System.Battery/最大容量与原始容量换算并存", { capacity() }),
        ("System.Battery/旧 BatteryMetrics JSON 仍能解码", { legacyDecoding() }),
        ("System.Battery/白名单读取器不读不传序列号键", { whitelist() }),
        ("System.Battery/解析失败只给出键名和类别", { issuesWithoutRawText() }),
        ("System.Live.Battery/本机读数与 pmset、system_profiler 对照", { live() }),
    ]

    /// 一份虚构的放电读数，各测试在此基础上改字段。
    static func fixture(_ overrides: [String: Any] = [:], removing: [String] = []) -> [String: Any] {
        var value: [String: Any] = [
            "BatteryInstalled": kCFBooleanTrue!, "ExternalConnected": kCFBooleanFalse!,
            "IsCharging": kCFBooleanFalse!, "FullyCharged": kCFBooleanFalse!,
            "CurrentCapacity": 62, "MaxCapacity": 97, "AppleRawMaxCapacity": 4321, "DesignCapacity": 4500,
            "CycleCount": 123, "DesignCycleCount9C": 1000, "Voltage": 12000, "Amperage": -775,
            "AvgTimeToEmpty": 260, "AvgTimeToFull": 65535, "Temperature": 3100,
            "PowerTelemetryData": ["SystemLoad": 9300], "AdapterDetails": ["Watts": 65],
        ]
        for (key, item) in overrides { value[key] = item }
        for key in removing { value.removeValue(forKey: key) }
        return value
    }

    private static func check(_ name: String, _ ok: Bool) -> Bool {
        if !ok { print("电池用例不符：\(name)") }
        return ok
    }

    static func states() -> Bool {
        let t = kCFBooleanTrue!, f = kCFBooleanFalse!
        let cases: [(String, [String: Any], BatteryPowerState)] = [
            ("使用电池", fixture(), .battery),
            ("充电中", fixture(["ExternalConnected": t, "IsCharging": t, "Amperage": 2050]), .charging),
            ("充电且标记充满时仍算充电中", fixture(["ExternalConnected": t, "IsCharging": t, "FullyCharged": t]), .charging),
            ("已充满", fixture(["ExternalConnected": t, "FullyCharged": t, "Amperage": 0]), .charged),
            ("接电源未充电", fixture(["ExternalConnected": t, "IsCharging": f, "FullyCharged": f, "Amperage": 0]), .acNotCharging),
            ("BatteryInstalled 为假", fixture(["BatteryInstalled": f]), .noBattery),
            ("没有服务", [:], .noBattery),
        ]
        for (name, properties, expected) in cases {
            guard check(name, BatteryStatus.parse(properties).state == expected) else { return false }
        }
        let none = BatteryStatus.parse([:])
        return check("无电池不带读数", none == .noBattery && !none.hasBattery && none.percent == nil)
            && check("状态文案", BatteryPowerState.acNotCharging.title == "接电源 · 未充电" && BatteryPowerState.battery.title == "使用电池"
                && BatteryPowerState.charging.title == "充电中" && BatteryPowerState.charged.isExternalPower && !BatteryPowerState.battery.isExternalPower)
    }

    static func estimates() -> Bool {
        let t = kCFBooleanTrue!
        for invalid in [65535, 0, -1, -260] {
            let discharge = BatteryStatus.parse(fixture(["AvgTimeToEmpty": invalid]))
            let charging = BatteryStatus.parse(fixture(["ExternalConnected": t, "IsCharging": t, "AvgTimeToFull": invalid]))
            guard check("无效预计时间 \(invalid)", discharge.minutesToEmpty == nil && discharge.estimateMinutes == nil
                && charging.minutesToFull == nil && charging.estimateMinutes == nil) else { return false }
        }
        let discharge = BatteryStatus.parse(fixture())
        let charging = BatteryStatus.parse(fixture(["ExternalConnected": t, "IsCharging": t, "AvgTimeToFull": 35, "AvgTimeToEmpty": 400]))
        // 接电源未充电时系统可能仍给出数值，D3 规定不显示。
        let idle = BatteryStatus.parse(fixture(["ExternalConnected": t, "AvgTimeToEmpty": 300, "AvgTimeToFull": 20]))
        return check("放电取 AvgTimeToEmpty", discharge.estimateMinutes == 260)
            && check("充电取 AvgTimeToFull", charging.estimateMinutes == 35)
            && check("接电源未充电不显示", idle.estimateMinutes == nil && idle.minutesToEmpty == 300)
    }

    static func power() -> Bool {
        let discharge = BatteryStatus.parse(fixture())
        let charging = BatteryStatus.parse(fixture(["ExternalConnected": kCFBooleanTrue!, "IsCharging": kCFBooleanTrue!, "Amperage": 2050]))
        let zero = BatteryStatus.parse(fixture(["Amperage": 0], removing: ["Voltage"]))
        // IOKit 可能把负电流存成 64 位无符号数。
        let unsigned = BatteryStatus.parse(fixture(["Amperage": NSNumber(value: UInt64(bitPattern: -775))]))
        return check("放电取绝对值", discharge.powerWatts.map { abs($0 - 9.3) < 0.000001 } == true)
            && check("充电功率", charging.powerWatts.map { abs($0 - 24.6) < 0.000001 } == true)
            && check("电流为 0 时功率为 0", zero.powerWatts == 0)
            && check("无符号位模式还原", unsigned.powerWatts == discharge.powerWatts)
    }

    static func missingAndWrongTypes() -> Bool {
        let noAdapter = BatteryStatus.parse(fixture(removing: ["AdapterDetails"]))
        let noVoltage = BatteryStatus.parse(fixture(removing: ["Voltage"]))
        let adapterNotDictionary = BatteryStatus.parse(fixture(["AdapterDetails": 65]))
        let wrong = BatteryStatus.parse(fixture(["CurrentCapacity": "62", "CycleCount": kCFBooleanTrue!, "Voltage": [12000],
                                                 "AdapterDetails": ["Watts": "65"], "MaxCapacity": 101.5]))
        let wrongBool = BatteryStatus.parse(fixture(["ExternalConnected": kCFBooleanTrue!, "IsCharging": 1, "FullyCharged": "true"]))
        let reference = BatteryStatus.parse(fixture())
        return check("缺适配器只影响适配器", noAdapter.adapterWatts == nil && noAdapter.percent == 62 && noAdapter.powerWatts == reference.powerWatts)
            && check("缺电压功率为空", noVoltage.powerWatts == nil && noVoltage.cycleCount == 123 && noVoltage.estimateMinutes == 260)
            && check("适配器不是字典", adapterNotDictionary.adapterWatts == nil && adapterNotDictionary.percent == 62)
            && check("类型错误逐项为空", wrong.percent == nil && wrong.cycleCount == nil && wrong.powerWatts == nil
                && wrong.adapterWatts == nil && wrong.maxCapacityPercent == nil && wrong.designCapacity == 4500 && wrong.state == .battery)
            && check("布尔字段不接受数字和文字", wrongBool.state == .acNotCharging)
            && check("参照读数", reference.percent == 62 && reference.cycleCount == 123 && reference.designCycleCount == 1000 && reference.adapterWatts == 65)
            && check("温度和整机功耗照旧", BatteryMetrics.parse(properties: fixture()).temperatureCelsius == 31
                && BatteryMetrics.parse(properties: fixture()).systemPowerWatts == 9.3
                && BatteryMetrics.parse(properties: [:]) == BatteryMetrics(temperatureCelsius: nil, systemPowerWatts: nil, status: .noBattery))
    }

    static func capacity() -> Bool {
        let value = BatteryStatus.parse(fixture())
        let noDesign = BatteryStatus.parse(fixture(removing: ["DesignCapacity"]))
        return check("系统口径与原始换算并存", value.maxCapacityPercent == 97 && value.rawMaxCapacity == 4321 && value.designCapacity == 4500
                && value.rawHealthPercent.map { abs($0 - 96.0222) < 0.001 } == true)
            && check("缺设计容量时没有换算值", noDesign.rawHealthPercent == nil && noDesign.maxCapacityPercent == 97)
    }

    static func legacyDecoding() -> Bool {
        do {
            let old = try JSONDecoder().decode(BatteryMetrics.self, from: Data(#"{"temperatureCelsius":30.51,"systemPowerWatts":7.082}"#.utf8))
            let empty = try JSONDecoder().decode(BatteryMetrics.self, from: Data("{}".utf8))
            let current = BatteryMetrics.parse(properties: fixture())
            let roundTrip = try JSONDecoder().decode(BatteryMetrics.self, from: JSONEncoder().encode(current))
            return check("旧 JSON", old == BatteryMetrics(temperatureCelsius: 30.51, systemPowerWatts: 7.082) && old.status == nil)
                && check("空对象", empty.temperatureCelsius == nil && empty.status == nil)
                && check("新字段往返", roundTrip == current && roundTrip.status?.percent == 62)
        } catch { print("电池解码失败：\(error)"); return false }
    }

    static func whitelist() -> Bool {
        // 虚构的完整注册表：顶层和嵌套字典里都混有序列号键。
        var registry = fixture()
        registry["Serial"] = "FAKE-SERIAL-0001"
        registry["BatterySerialNumber"] = "FAKE-SERIAL-0002"
        registry["AdapterDetails"] = ["Watts": 65, "SerialString": "FAKE-SERIAL-0003", "Manufacturer": "Example"]
        registry["PowerTelemetryData"] = ["SystemLoad": 9300, "Serial": "FAKE-SERIAL-0004"]
        registry["BatteryData"] = ["Serial": "FAKE-SERIAL-0005", "DesignCapacity": 4500]
        var asked: [String] = []
        let filtered = BatteryRegistryKeys.filtered { key in asked.append(key); return registry[key] }
        let text = String(describing: filtered)
        let askedSerial = asked.contains { $0.lowercased().contains("serial") }
        let topLevelOK = Set(filtered.keys).isSubset(of: BatteryRegistryKeys.all) && Set(asked) == BatteryRegistryKeys.all
        let adapter = filtered["AdapterDetails"] as? [String: Any], telemetry = filtered["PowerTelemetryData"] as? [String: Any]
        return check("不请求序列号键", !askedSerial && topLevelOK)
            && check("嵌套字典只留白名单子键", adapter.map { Set($0.keys) == ["Watts"] } == true && telemetry.map { Set($0.keys) == ["SystemLoad"] } == true)
            && check("输出不含序列号", !text.contains("FAKE-SERIAL") && !text.lowercased().contains("serial") && filtered["BatteryData"] == nil)
            && check("过滤后仍能解析", BatteryStatus.parse(filtered) == BatteryStatus.parse(fixture()))
            && check("源码中的白名单没有序列号键", !BatteryRegistryKeys.all.contains { $0.lowercased().contains("serial") }
                && !BatteryRegistryKeys.nested.values.joined().contains { $0.lowercased().contains("serial") })
    }

    static func issuesWithoutRawText() -> Bool {
        let secret = "FAKE-SERIAL-RAW-9999"
        let broken = fixture(["Voltage": secret, "CycleCount": [secret], "AdapterDetails": ["Watts": secret]], removing: ["AvgTimeToFull"])
        let issues = BatteryStatus.issues(broken)
        let text = issues.map(\.description).joined(separator: ",")
        let expected: Set<String> = ["Voltage:wrongType", "CycleCount:wrongType", "AdapterDetails.Watts:wrongType", "AvgTimeToFull:missing"]
        return check("问题列表只含键名和类别", Set(issues.map(\.description)) == expected && !text.contains(secret))
            && check("完整夹具没有问题", BatteryStatus.issues(fixture()).isEmpty)
            && check("解析结果不带原文", !String(describing: BatteryStatus.parse(broken)).contains(secret))
    }

    // MARK: - 实机对照（MEOWMAC_LIVE=1）

    /// 只经应用自己的白名单读取器取 IORegistry 值，不运行 ioreg。`system_profiler` 只取过滤后的行。
    /// 原值写 `build/acceptance/battery/`，终端只打印是否一致。
    static func live() -> Bool {
        let properties = SystemCollector.batteryProperties()
        let metrics = BatteryMetrics.parse(properties: properties)
        guard let status = metrics.status else { print("电池实测：没有读数"); return false }
        let issues = BatteryStatus.issues(properties)
        guard let pmset = run("/usr/bin/pmset", ["-g", "batt"]),
              let profiler = run("/bin/sh", ["-c", #"/usr/sbin/system_profiler SPPowerDataType | /usr/bin/grep -E '^ *(Cycle Count|Maximum Capacity|Condition|State of Charge \(%\)|Charging|Fully Charged):'"#]) else {
            print("电池实测：命令执行失败"); return false
        }
        let profilerFields = Dictionary(profiler.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { first, _ in first })
        let onBattery = pmset.contains("'Battery Power'"), onAC = pmset.contains("'AC Power'")
        let pmsetPercent = firstMatch(#"(\d+)%"#, in: pmset).flatMap(Int.init)
        let pmsetCharging = pmset.contains("; charging;") || pmset.contains("finishing charge")
        let sourceOK = status.state == .battery ? onBattery : (status.hasBattery && onAC)
        let chargingOK = (status.state == .charging) == pmsetCharging
        let percentOK = status.percent != nil && status.percent == pmsetPercent
        let cycleOK = status.cycleCount != nil && profilerFields["Cycle Count"].flatMap { Int($0) } == status.cycleCount
        let maxOK = status.maxCapacityPercent != nil
            && profilerFields["Maximum Capacity"].map { $0.replacingOccurrences(of: "%", with: "") }.flatMap { Int($0) } == status.maxCapacityPercent
        let lines = [
            "时间：\(ISO8601DateFormatter().string(from: Date()))",
            "MeowMac 白名单读取：state=\(status.state.rawValue) percent=\(describe(status.percent)) maxCapacity=\(describe(status.maxCapacityPercent))%",
            "  rawMaxCapacity=\(describe(status.rawMaxCapacity))mAh designCapacity=\(describe(status.designCapacity))mAh rawHealth=\(status.rawHealthPercent.map { String(format: "%.1f", $0) } ?? "—")%",
            "  cycle=\(describe(status.cycleCount))/\(describe(status.designCycleCount)) power=\(status.powerWatts.map { String(format: "%.2f", $0) } ?? "—")W",
            "  toEmpty=\(describe(status.minutesToEmpty))min toFull=\(describe(status.minutesToFull))min adapter=\(describe(status.adapterWatts))W",
            "  temperature=\(metrics.temperatureCelsius.map { String(format: "%.2f", $0) } ?? "—") systemPower=\(metrics.systemPowerWatts.map { String(format: "%.2f", $0) } ?? "—")W",
            "  issues=\(issues.map(\.description).joined(separator: ","))",
            "pmset -g batt：", pmset,
            "system_profiler SPPowerDataType（按行首字段过滤）：", profiler,
            "对照：供电=\(sourceOK) 充电=\(chargingOK) 电量=\(percentOK) 循环=\(cycleOK) 最大容量=\(maxOK)",
        ]
        do {
            let directory = URL(fileURLWithPath: "build/acceptance/battery", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("live-reading.txt"))
        } catch { print("电池实测：写入 build/acceptance/battery 失败（\(type(of: error))）"); return false }
        print("电池实测对照：供电 \(sourceOK)，充电 \(chargingOK)，电量 \(percentOK)，循环次数 \(cycleOK)，最大容量 \(maxOK)，字段问题 \(issues.count) 项")
        return sourceOK && chargingOK && percentOK && cycleOK && maxOK
    }

    private static func describe(_ value: Int?) -> String { value.map(String.init) ?? "—" }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
