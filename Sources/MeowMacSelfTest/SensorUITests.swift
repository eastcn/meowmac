import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum SensorUITests {
    static var tests: [(String, @MainActor () -> Bool)] { [
        ("Core.PanelLayout/旧布局补齐传感器功能块", { migration() }),
        ("UI.Sensors/卡片六种状态文案", { cardStates() }),
        ("UI.Sensors/温度双线与风扇行", { trendRows() }),
        ("UI.Sensors/浅深色合成预览", { previews() }),
    ] }

    private static let oldSystem: [[String: Any]] = [
        ["id": "system.disk", "visible": true], ["id": "system.chart", "visible": true], ["id": "system.energy", "visible": false],
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
        let expected = ["system.sensors", "system.disk", "system.chart", "system.energy"]
        // v1、v2 本机布局都只缺 system.sensors：插到磁盘之前并显示，其余顺序和显隐不变。
        for version in [1, 2] {
            guard let layout = try? PanelLayout.parse(layoutJSON(version: version, system: oldSystem)),
                  layout.placements(for: .system).map(\.id) == expected,
                  layout.placements(for: .system).map(\.visible) == [true, true, true, false] else { print("v\(version) 迁移失败"); return false }
            // 写回包含完整四项，再读一次不变。
            guard let data = try? JSONEncoder().encode(layout),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ((object["cards"] as? [String: Any])?["system"] as? [Any])?.count == 4,
                  (try? PanelLayout.parse(data)) == layout else { print("v\(version) 写回失败"); return false }
        }
        // 其他缺项、未知 id、重复项仍拒绝；直接构造的三项布局也不能通过校验。
        let missingDisk: [[String: Any]] = [["id": "system.chart", "visible": true], ["id": "system.energy", "visible": true], ["id": "system.sensors", "visible": true]]
        let unknown = oldSystem + [["id": "system.fans", "visible": true]]
        let duplicate = oldSystem + [["id": "system.chart", "visible": true]]
        let onlyTwo = Array(oldSystem.prefix(2))
        for (name, system) in [("缺磁盘", missingDisk), ("未知 id", unknown), ("重复", duplicate), ("缺两项", onlyTwo)] {
            if (try? PanelLayout.parse(layoutJSON(version: 2, system: system))) != nil { print("\(name) 未被拒绝"); return false }
        }
        var direct = PanelLayout.default
        direct.cards["system"] = direct.placements(for: .system).filter { $0.id != "system.sensors" }
        guard (try? direct.validated()) == nil else { return false }
        // 猫包 panel 同样补齐；内置猫不受影响。
        guard let builtin = try? CatPackageLoader.builtin("builtin.slim"), builtin.package.panel == .default,
              var manifest = try? JSONSerialization.jsonObject(with: builtin.files["manifest.json"]!) as? [String: Any],
              let panel = try? JSONSerialization.jsonObject(with: layoutJSON(version: 2, system: oldSystem)) else { return false }
        manifest["schemaVersion"] = 2
        manifest["panel"] = panel
        guard let data = try? JSONSerialization.data(withJSONObject: manifest),
              let package = try? CatPackage.parse(data, builtin: true) else { print("猫包迁移失败"); return false }
        return package.panel.placements(for: .system).map(\.id) == expected
            && PanelLayout.default.placements(for: .system).map(\.id) == ["system.chart", "system.energy", "system.sensors", "system.disk"]
            && CatPackageLoader.builtinIDs.count == 4 && CatPackageLoader.builtinIDs.allSatisfy { (try? CatPackageLoader.builtin($0))?.package.panel == .default }
    }

    static func cardStates() -> Bool {
        func columns(_ variant: PanelPreviewRenderer.SensorPreview) -> (SensorCardDisplay, [String]) {
            let display = PanelPreviewRenderer.sensorState(variant).sensorDisplay
            return (display, display.columns.map { "\($0.name)|\($0.value)|\($0.unit ?? "")|\($0.detail)|\($0.tone.rawValue)" })
        }
        let idle = columns(.idle), spinning = columns(.spinning)
        let gpu = columns(.gpuMissing), noFan = columns(.noFan), none = columns(.unavailable)
        let source = "来源：SMC，非公开接口，新芯片上可能读不到"
        guard idle.1.map({ $0.split(separator: "|").map(String.init) }).map({ $0[0] }) == ["CPU", "GPU", "风扇"],
              idle.1[2] == "风扇|0|rpm|静止|normal", idle.1[1].hasSuffix("|°C|平均|normal"), idle.1[0].contains("|最高 "),
              idle.0.footer == source else { print("静止：\(idle)"); return false }
        guard spinning.1[2].hasPrefix("风扇|"), spinning.1[2].contains("|rpm|最大值的 "), spinning.1[2].hasSuffix("|normal") else { print("转动：\(spinning)"); return false }
        guard gpu.1[1] == "GPU|不可用||没有匹配的传感器|unavailable", gpu.1[0].hasSuffix("|normal"), gpu.0.footer == source else { print("GPU：\(gpu)"); return false }
        guard noFan.1[2] == "风扇|无风扇||本机未报告风扇|unavailable", noFan.0.footer == source else { print("无风扇：\(noFan)"); return false }
        guard none.1 == ["CPU|不可用|||unavailable", "GPU|不可用|||unavailable", "风扇|不可用|||unavailable"],
              none.0.footer == "传感器不可用：无法连接 SMC 传感器服务。其他系统数据不受影响" else { print("全部不可用：\(none)"); return false }
        // 尚未采集时不显示“不可用”，只写等待。
        let waiting = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil)).sensorDisplay
        return waiting.footer == "等待采集" && waiting.columns.allSatisfy { $0.value == "—" }
    }

    static func trendRows() -> Bool {
        let state = PanelPreviewRenderer.sensorState(.spinning)
        let rows = state.systemTrends
        guard rows.map(\.kind) == ["cpu", "memory", "power", "temperature", "fan"],
              let temperature = rows.first(where: { $0.kind == "temperature" }), let fan = rows.last else { return false }
        let all = temperature.points.map(\.value) + (temperature.secondaryPoints ?? []).map(\.value)
        guard temperature.name == "温度", temperature.current.hasPrefix("SoC "), temperature.secondaryCurrent?.hasPrefix("电池 ") == true,
              temperature.points.count == 15 || temperature.points.count == 16, temperature.secondaryPoints?.count == temperature.points.count,
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
              unavailable[3].current == "SoC —", unavailable[3].points.isEmpty else { return false }
        // 阈值跟随本机配置。
        let custom = PanelPreviewRenderer.sensorState(.spinning)
        var config = LocalConfig(); config.fanHighFraction = 0.7
        custom.configResult = ConfigLoadResult(config: config, error: nil)
        return custom.systemTrends.last?.threshold == 4200
    }

    static func previews() -> Bool {
        let output = URL(fileURLWithPath: "build/acceptance/sensors/previews", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for variant in PanelPreviewRenderer.SensorPreview.allCases {
                for dark in [false, true] {
                    guard let image = PanelPreviewRenderer.sensorPNG(state: PanelPreviewRenderer.sensorState(variant), dark: dark),
                          let bitmap = NSBitmapImageRep(data: image), bitmap.pixelsWide == 720 else { return false }
                    try image.write(to: output.appendingPathComponent(variant.rawValue + (dark ? "-dark.png" : "-light.png")))
                }
            }
            return true
        } catch { print("传感器预览失败：\(error)"); return false }
    }
}
