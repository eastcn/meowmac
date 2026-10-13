import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum NetworkLayoutTests {
    static let tests: [(String, @MainActor () -> Bool)] = [
        ("Core.PanelLayout/旧布局补上速率功能块", migration),
        ("Core.PanelLayout/速率块缺项与未知 id 仍拒绝", rejection),
        ("UI.PanelLayout/速率块隐藏、排序与设置列表", settings),
    ]

    private static func layoutJSON(version: Int, network: [[String: Any]]) -> Data {
        var root: [String: Any] = [
            "schemaVersion": version, "tabs": ["network", "system", "quota"],
            "cards": [
                "system": ["system.chart", "system.energy", "system.disk"].map { ["id": $0, "visible": true] },
                "quota": ["quota.trend", "quota.cost", "quota.storage"].map { ["id": $0, "visible": true] },
                "network": network,
            ],
        ]
        if version == 2 { root["overview"] = ["order": ["cpu", "memory", "quota", "network"], "hidden": [], "quota": ["provider": "claude", "window": "auto"]] }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    /// 2026-10-04 之前写入的网络页：三项，顺序和显隐都改过。
    private static let legacy: [[String: Any]] = [
        ["id": "network.egress", "visible": true], ["id": "network.sites", "visible": false], ["id": "network.checks", "visible": true],
    ]

    static func migration() -> Bool {
        for version in [1, 2] {
            guard let layout = try? PanelLayout.parse(layoutJSON(version: version, network: legacy)),
                  layout.placements(for: .network).map(\.id) == ["network.egress", "network.sites", "network.traffic", "network.proxy", "network.checks"],
                  layout.placements(for: .network).map(\.visible) == [true, false, true, true, true] else { print("v\(version) 迁移失败"); return false }
            guard let data = try? JSONEncoder().encode(layout),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ((object["cards"] as? [String: Any])?["network"] as? [Any])?.count == 5,
                  (try? PanelLayout.parse(data)) == layout else { print("v\(version) 写回失败"); return false }
        }
        // 2026-10-04 的四项布局：保留原来的顺序和显隐，仅补代理块。
        let full: [[String: Any]] = [["id": "network.traffic", "visible": false]] + legacy
        guard let kept = try? PanelLayout.parse(layoutJSON(version: 2, network: full)),
              kept.placements(for: .network).map(\.id) == ["network.traffic", "network.proxy", "network.egress", "network.sites", "network.checks"],
              kept.placements(for: .network).first?.visible == false else { return false }
        // 猫包 panel 同样补上；内置猫仍是默认布局。
        guard let builtin = try? CatPackageLoader.builtin("builtin.slim"),
              var manifest = try? JSONSerialization.jsonObject(with: builtin.files["manifest.json"]!) as? [String: Any],
              let panel = try? JSONSerialization.jsonObject(with: layoutJSON(version: 2, network: legacy)) else { return false }
        manifest["schemaVersion"] = 2
        manifest["panel"] = panel
        guard let data = try? JSONSerialization.data(withJSONObject: manifest),
              let package = try? CatPackage.parse(data, builtin: true) else { print("猫包迁移失败"); return false }
        return package.panel.placements(for: .network).map(\.id) == ["network.egress", "network.sites", "network.traffic", "network.proxy", "network.checks"]
            && PanelLayout.default.placements(for: .network).map(\.id) == ["network.checks", "network.sites", "network.traffic", "network.proxy", "network.egress"]
            && CatPackageLoader.builtinIDs.allSatisfy { (try? CatPackageLoader.builtin($0))?.package.panel == .default }
    }

    static func rejection() -> Bool {
        let missing: [[String: Any]] = [["id": "network.checks", "visible": true], ["id": "network.egress", "visible": true]]
        let unknown = legacy + [["id": "network.speed", "visible": true]]
        let duplicate = legacy + [["id": "network.sites", "visible": true]]
        let twice = legacy + [["id": "network.traffic", "visible": true], ["id": "network.traffic", "visible": true]]
        for (name, network) in [("缺站点和速率", missing), ("未知 id", unknown), ("重复", duplicate), ("速率重复", twice)] {
            if (try? PanelLayout.parse(layoutJSON(version: 2, network: network))) != nil { print("\(name) 未被拒绝"); return false }
        }
        var crossTab = try! JSONSerialization.jsonObject(with: layoutJSON(version: 2, network: legacy)) as! [String: Any]
        var cards = crossTab["cards"] as! [String: Any]
        cards["quota"] = (cards["quota"] as! [[String: Any]]) + [["id": "network.traffic", "visible": true]]
        crossTab["cards"] = cards
        return (try? PanelLayout.parse(JSONSerialization.data(withJSONObject: crossTab))) == nil
    }

    static func settings() -> Bool {
        var layout = PanelLayout.default
        layout.cards["network"] = [PanelCardPlacement(id: "network.traffic"), PanelCardPlacement(id: "network.proxy"), PanelCardPlacement(id: "network.checks"),
                                   PanelCardPlacement(id: "network.sites", visible: false), PanelCardPlacement(id: "network.egress")]
        guard (try? layout.validated()) != nil,
              layout.visibleIDs(for: .network) == ["network.traffic", "network.proxy", "network.checks", "network.egress"] else { return false }
        let titles = PanelLayoutCatalog.definitions[.network]?.map(\.title)
        return titles == ["连接检查", "站点延迟", "上下行速率", "代理流量", "出口 IP"]
            && PanelLayoutCatalog.definitions[.network]?.allSatisfy(\.canHide) == true
    }
}
