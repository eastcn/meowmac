import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum SensorUITests {
    static var tests: [(String, @MainActor () -> Bool)] { [
        ("Core.PanelLayout/旧布局去掉传感器功能块", { migration() }),
        ("UI.Sensors/温度与风扇行六种状态", { rowStates() }),
        ("UI.Sensors/温度双线与风扇行", { trendRows() }),
        ("UI.Sensors/浅深色合成预览", { previews() }),
    ] }

    /// v0.3 第 1 轮写入过的四项布局：传感器块在中间且隐藏。
    private static let withSensors: [[String: Any]] = [
        ["id": "system.disk", "visible": true], ["id": "system.sensors", "visible": false],
        ["id": "system.chart", "visible": true], ["id": "system.energy", "visible": false],
    ]

    private static func layoutJSON(version: Int, system: [[String: Any]]) -> Data {
        var root: [String: Any] = [
            "schemaVersion": version, "tabs": ["system", "quota", "network"],
            "cards": [
                "system": system,
                "quota": ["quota.trend", "quota.cost", "quota.storage"].map { ["id": $0, "visible": true] },
                "network": ["network.checks", "network.sites", "network.egress"].map { ["id": $0, "visible": true] },
            ],
        ]
        if version == 2 { root["overview"] = ["order": ["cpu", "memory", "quota", "network"], "hidden": [], "quota": ["provider": "claude", "window": "auto"]] }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    static func migration() -> Bool {
        // 2026-10-24 起系统页新增电池（D44）：去掉传感器后恰好只缺电池，以可见状态追加到末尾。
        let expected = ["system.disk", "system.chart", "system.energy", "system.battery"]
        // v1、v2 本机布局含 system.sensors：去掉它，其余顺序和显隐不变；不含时照常读取。
        for version in [1, 2] {
            guard let layout = try? PanelLayout.parse(layoutJSON(version: version, system: withSensors)),
                  layout.placements(for: .system).map(\.id) == expected,
                  layout.placements(for: .system).map(\.visible) == [true, true, false, true] else { print("v\(version) 迁移失败"); return false }
            guard let data = try? JSONEncoder().encode(layout),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ((object["cards"] as? [String: Any])?["system"] as? [Any])?.count == 4,
                  (try? PanelLayout.parse(data)) == layout else { print("v\(version) 写回失败"); return false }
            let plain = withSensors.filter { $0["id"] as? String != "system.sensors" }
            guard (try? PanelLayout.parse(layoutJSON(version: version, system: plain))) == layout else { return false }
        }
        // 其他缺项、未知 id、重复项、只剩传感器补位的布局仍拒绝；传感器出现在其他页也拒绝。
        let missingDisk: [[String: Any]] = [["id": "system.chart", "visible": true], ["id": "system.energy", "visible": true], ["id": "system.sensors", "visible": true]]
        let unknown = withSensors + [["id": "system.fans", "visible": true]]
        let duplicate = withSensors + [["id": "system.chart", "visible": true]]
        for (name, system) in [("缺磁盘", missingDisk), ("未知 id", unknown), ("重复", duplicate)] {
            if (try? PanelLayout.parse(layoutJSON(version: 2, system: system))) != nil { print("\(name) 未被拒绝"); return false }
        }
        var crossTab = try! JSONSerialization.jsonObject(with: layoutJSON(version: 2, system: withSensors)) as! [String: Any]
        var cards = crossTab["cards"] as! [String: Any]
        cards["quota"] = (cards["quota"] as! [[String: Any]]) + [["id": "system.sensors", "visible": true]]
        crossTab["cards"] = cards
        guard (try? PanelLayout.parse(JSONSerialization.data(withJSONObject: crossTab))) == nil else { print("跨页传感器未被拒绝"); return false }
        var direct = PanelLayout.default
        direct.cards["system"]?.append(PanelCardPlacement(id: "system.sensors"))
        guard (try? direct.validated()) == nil else { return false }
        // 猫包 panel 同样去掉；内置猫不受影响。
        guard let builtin = try? CatPackageLoader.builtin("builtin.slim"), builtin.package.panel == .default,
              var manifest = try? JSONSerialization.jsonObject(with: builtin.files["manifest.json"]!) as? [String: Any],
              let panel = try? JSONSerialization.jsonObject(with: layoutJSON(version: 2, system: withSensors)) else { return false }
        manifest["schemaVersion"] = 2
        manifest["panel"] = panel
        guard let data = try? JSONSerialization.data(withJSONObject: manifest),
              let package = try? CatPackage.parse(data, builtin: true) else { print("猫包迁移失败"); return false }
        return package.panel.placements(for: .system).map(\.id) == expected
            && PanelLayout.default.placements(for: .system).map(\.id) == ["system.chart", "system.energy", "system.disk", "system.battery"]
            && CatPackageLoader.builtinIDs.count == 4 && CatPackageLoader.builtinIDs.allSatisfy { (try? CatPackageLoader.builtin($0))?.package.panel == .default }
    }

    static func rowStates() -> Bool {
        func rows(_ variant: PanelPreviewRenderer.SensorPreview) -> (temperature: SystemTrend, fan: SystemTrend?) {
            let trends = PanelPreviewRenderer.sensorState(variant).systemTrends
            return (trends.first { $0.kind == "temperature" }!, trends.first { $0.kind == "fan" })
        }
        let idle = rows(.idle), spinning = rows(.spinning), gpu = rows(.gpuMissing), noFan = rows(.noFan), none = rows(.unavailable)
        guard idle.temperature.detail.hasPrefix("最热 "), idle.temperature.detail.contains(" · GPU "), idle.temperature.current.hasSuffix(" °C"),
              idle.temperature.help.contains("来源：SMC，非公开接口，新芯片上可能读不到"),
              idle.fan?.detail == "静止", idle.fan?.current == "0 rpm", idle.fan?.warn == false else { print("静止：\(idle)"); return false }
        guard spinning.fan?.detail.hasPrefix("最大值的 ") == true, spinning.fan?.current.hasSuffix(" rpm") == true else { print("转动：\(spinning)"); return false }
        guard gpu.temperature.detail.hasPrefix("最热 "), !gpu.temperature.detail.contains("GPU") else { print("GPU：\(gpu)"); return false }
        guard noFan.fan == nil, noFan.temperature.detail.contains("GPU") else { print("无风扇：\(noFan)"); return false }
        guard none.temperature.detail == "SoC 不可用", none.temperature.current == "—",
              none.temperature.help.contains("读不到 SMC：无法连接传感器服务。其他系统数据不受影响"),
              none.fan?.detail == "不可用", none.fan?.current == "—", none.fan?.help.contains("读不到 SMC") == true else { print("全部不可用：\(none)"); return false }
        // 尚未采集时写等待，不显示“不可用”。
        let waiting = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        return waiting.temperatureDetail == "等待采集" && waiting.fanDetail.text == "等待采集"
    }

    static func trendRows() -> Bool {
        let state = PanelPreviewRenderer.sensorState(.spinning)
        let rows = state.systemTrends
        guard rows.map(\.kind) == ["cpu", "memory", "power", "temperature", "fan"],
              let temperature = rows.first(where: { $0.kind == "temperature" }), let fan = rows.last else { return false }
        let all = temperature.points.map(\.value) + (temperature.secondaryPoints ?? []).map(\.value)
        guard temperature.name == "温度", temperature.current.hasSuffix(" °C"), temperature.secondaryCurrent?.hasPrefix("电池 ") == true,
              temperature.points.count == 91, temperature.secondaryPoints?.count == temperature.points.count,
              let low = all.min(), let high = all.max(), temperature.lower <= low, temperature.upper >= high,
              temperature.lower.truncatingRemainder(dividingBy: 2) == 0, temperature.upper.truncatingRemainder(dividingBy: 2) == 0 else {
            print("温度行：\(temperature)"); return false
        }
        guard fan.name == "风扇", fan.lower == 0, fan.upper == 6000, fan.threshold == 4800, fan.rangeLabel == "0–6000 rpm",
              fan.current.hasSuffix(" rpm") else { print("风扇行：\(fan)"); return false }
        // 无风扇不画风扇行；读不到时保留风扇行并显示“—”，没有阈值。
        let noFan = PanelPreviewRenderer.sensorState(.noFan).systemTrends
        let unavailable = PanelPreviewRenderer.sensorState(.unavailable).systemTrends
        guard noFan.map(\.kind) == ["cpu", "memory", "power", "temperature"],
              let missing = unavailable.last, missing.kind == "fan", missing.current == "—", missing.rangeLabel.isEmpty, missing.threshold == nil, missing.points.isEmpty,
              unavailable[3].current == "—", unavailable[3].points.isEmpty else { return false }
        // 阈值跟随本机配置。
        let custom = PanelPreviewRenderer.sensorState(.spinning)
        var config = LocalConfig(); config.fanHighFraction = 0.7
        custom.configResult = ConfigLoadResult(config: config, error: nil)
        return custom.systemTrends.last?.threshold == 4200
    }

    static func previews() -> Bool {
        let output = URL(fileURLWithPath: "build/acceptance/sensors/previews-round2", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let cases: [(String, PanelState)] = PanelPreviewRenderer.SensorPreview.allCases.map { ($0.rawValue, PanelPreviewRenderer.sensorState($0)) }
                + [("cooling-diagnosis", PanelPreviewRenderer.sensorState(.cooling, diagnosis: true))]
            for (name, state) in cases {
                for dark in [false, true] {
                    guard let image = PanelPreviewRenderer.systemPagePNG(state: state, dark: dark),
                          let bitmap = NSBitmapImageRep(data: image), bitmap.pixelsWide == 720 else { return false }
                    try image.write(to: output.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
                }
            }
            return true
        } catch { print("系统页预览失败：\(error)"); return false }
    }
}
