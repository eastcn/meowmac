import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

/// 电池卡片和布局迁移（D44、设计稿 battery.html）。全部为虚构数据。
@MainActor
enum BatteryCardTests {
    static let tests: [(String, @MainActor () async -> Bool)] = [
        ("Core.PanelLayout/电池块迁移与拒绝", { migration() }),
        ("UI.Battery/四种状态文案与预计时间", { texts() }),
        ("UI.Battery/功率格式与摘要文案", { formats() }),
        ("UI.Battery/无电池不渲染与悬停选择", { availabilityAndHover() }),
        ("UI.Battery/真实容器首屏仍含磁盘", { await firstScreen() }),
        ("UI.Battery/四种状态浅深合成预览", { previews() }),
    ]

    static let output = URL(fileURLWithPath: "build/acceptance/battery/preview", isDirectory: true)

    private static func check(_ name: String, _ ok: Bool) -> Bool {
        if !ok { print("电池卡片用例不符：\(name)") }
        return ok
    }

    private static func layoutJSON(system: [[String: Any]], version: Int = 2) -> Data {
        var root: [String: Any] = [
            "schemaVersion": version, "tabs": ["system", "quota", "network"],
            "cards": [
                "system": system,
                "quota": ["quota.trend", "quota.cost", "quota.storage"].map { ["id": $0, "visible": true] },
                "network": ["network.checks", "network.sites", "network.traffic", "network.proxy", "network.egress"].map { ["id": $0, "visible": true] },
            ],
        ]
        if version == 2 { root["overview"] = ["order": ["cpu", "memory", "quota", "network"], "hidden": [], "quota": ["provider": "claude", "window": "auto"]] }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    static func migration() -> Bool {
        func items(_ values: [(String, Bool)]) -> [[String: Any]] { values.map { ["id": $0.0, "visible": $0.1] } }
        // 用户调过顺序和显隐的旧三项布局：电池以可见状态追加到末尾。
        let old = items([("system.disk", false), ("system.chart", true), ("system.energy", true)])
        for version in [1, 2] {
            guard let layout = try? PanelLayout.parse(layoutJSON(system: old, version: version)),
                  check("v\(version) 追加到末尾", layout.placements(for: .system).map(\.id) == ["system.disk", "system.chart", "system.energy", "system.battery"]),
                  check("v\(version) 显隐不变", layout.placements(for: .system).map(\.visible) == [false, true, true, true]) else { return false }
            guard let data = try? JSONEncoder().encode(layout),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  check("写入时系统页四项", ((object["cards"] as? [String: Any])?["system"] as? [Any])?.count == 4),
                  check("写回可再读", (try? PanelLayout.parse(data)) == layout) else { return false }
        }
        // 默认顺序：磁盘之后。
        let defaultOld = items([("system.chart", true), ("system.energy", true), ("system.disk", true)])
        guard check("默认排在磁盘之后", (try? PanelLayout.parse(layoutJSON(system: defaultOld)))?.placements(for: .system).map(\.id)
                    == ["system.chart", "system.energy", "system.disk", "system.battery"]) else { return false }
        // 同时有 system.sensors：先去掉传感器，再补电池。
        let sensors = items([("system.chart", true), ("system.sensors", false), ("system.energy", true), ("system.disk", true)])
        guard check("与传感器删除同时生效", (try? PanelLayout.parse(layoutJSON(system: sensors)))?.placements(for: .system).map(\.id)
                    == ["system.chart", "system.energy", "system.disk", "system.battery"]) else { return false }
        // 已有电池的四项布局保持原样，包括隐藏状态。
        let hidden = items([("system.battery", false), ("system.chart", true), ("system.energy", true), ("system.disk", true)])
        guard check("已有电池保持原样", (try? PanelLayout.parse(layoutJSON(system: hidden)))?.placements(for: .system).map(\.visible) == [false, true, true, true]) else { return false }
        // 其他缺项、重复、未知 id、跨页仍拒绝。
        let rejects: [(String, [[String: Any]])] = [
            ("缺磁盘", items([("system.chart", true), ("system.energy", true)])),
            ("缺能耗和电池", items([("system.chart", true), ("system.disk", true)])),
            ("重复", items([("system.chart", true), ("system.energy", true), ("system.disk", true), ("system.disk", true)])),
            ("未知 id", items([("system.chart", true), ("system.energy", true), ("system.disk", true), ("system.fans", true)])),
            ("电池重复", items([("system.chart", true), ("system.energy", true), ("system.disk", true), ("system.battery", true), ("system.battery", true)])),
        ]
        for (name, system) in rejects {
            guard check(name + "被拒绝", (try? PanelLayout.parse(layoutJSON(system: system))) == nil) else { return false }
        }
        var cross = try! JSONSerialization.jsonObject(with: layoutJSON(system: defaultOld)) as! [String: Any]
        var cards = cross["cards"] as! [String: Any]
        cards["quota"] = (cards["quota"] as! [[String: Any]]) + [["id": "system.battery", "visible": true]]
        cross["cards"] = cards
        guard check("跨页电池被拒绝", (try? PanelLayout.parse(JSONSerialization.data(withJSONObject: cross))) == nil) else { return false }
        var direct = PanelLayout.default
        direct.cards["system"]?.removeLast()
        guard check("直接校验不补位", (try? direct.validated()) == nil),
              check("默认布局四项", PanelLayout.default.placements(for: .system).map(\.id) == ["system.chart", "system.energy", "system.disk", "system.battery"]),
              check("目录标题", PanelLayoutCatalog.definitions[.system]?.last?.title == "电池" && PanelLayoutCatalog.definitions[.system]?.last?.canHide == true) else { return false }
        // 猫包 panel 同样适用。
        guard let builtin = try? CatPackageLoader.builtin("builtin.slim"),
              var manifest = try? JSONSerialization.jsonObject(with: builtin.files["manifest.json"]!) as? [String: Any],
              let panel = try? JSONSerialization.jsonObject(with: layoutJSON(system: old)) else { return false }
        manifest["schemaVersion"] = 2
        manifest["panel"] = panel
        guard let data = try? JSONSerialization.data(withJSONObject: manifest), let package = try? CatPackage.parse(data, builtin: true) else {
            print("电池块：猫包迁移失败"); return false
        }
        return check("猫包迁移", package.panel.placements(for: .system).map(\.id) == ["system.disk", "system.chart", "system.energy", "system.battery"])
    }

    private static func display(_ status: BatteryStatus, history: BatteryHistory = BatteryHistory(), now: Date = Date(timeIntervalSince1970: 1_900_000_000)) -> BatteryCardDisplay {
        BatteryCardDisplay.make(status: status, temperature: 31, systemPower: 9.3, history: history, now: now)
    }

    static func texts() -> Bool {
        let discharge = display(BatteryStatus(state: .battery, percent: 62, maxCapacityPercent: 100, rawMaxCapacity: 4321, designCapacity: 4500,
                                              cycleCount: 123, designCycleCount: 1000, powerWatts: 9.3, minutesToEmpty: 260))
        let charging = display(BatteryStatus(state: .charging, percent: 68, powerWatts: 24.6, minutesToFull: 35, adapterWatts: 65))
        let ac = display(BatteryStatus(state: .acNotCharging, percent: 80, powerWatts: 0, minutesToEmpty: 300, minutesToFull: 20, adapterWatts: 65))
        let charged = display(BatteryStatus(state: .charged, percent: 100, powerWatts: 0, adapterWatts: 96))
        let noEstimate = display(BatteryStatus(state: .battery, percent: 58, powerWatts: 8.1))
        let chargingNoEstimate = display(BatteryStatus(state: .charging, percent: 40, powerWatts: 30))
        let hourly = display(BatteryStatus(state: .battery, percent: 90, powerWatts: 5, minutesToEmpty: 360))
        let short = display(BatteryStatus(state: .charging, percent: 90, powerWatts: 5, minutesToFull: 5))
        return check("使用电池", discharge.percent == "62" && discharge.state == "使用电池" && discharge.rate == "放电 9.3 W"
                && discharge.estimate.plain == "预计还能用 4 小时 20 分" && discharge.estimate.emphasis == "4 小时 20 分"
                && discharge.health == "100%" && discharge.cycles == "123" && discharge.designCycles == "1000"
                && discharge.meta == "电池 31.0 °C · 低电量 20%" && discharge.healthHelp.contains("原始满充 4321 mAh · 设计容量 4500 mAh · 换算 96.0%"))
            && check("充电中（D6 不写目标百分比）", charging.state == "充电中" && charging.rate == "充电 24.6 W"
                && charging.estimate.plain == "预计 35 分钟充满" && charging.estimate.emphasis == "35 分钟"
                && !charging.estimate.plain.contains("%") && charging.meta == "电池 31.0 °C · 适配器 65 W")
            && check("接电源未充电", ac.state == "接电源 · 未充电" && ac.rate == "整机 9.3 W"
                && ac.estimate.plain == "由电源供电，电池保持在 80%" && ac.estimate.emphasis.isEmpty)
            && check("已充满", charged.state == "已充满" && charged.rate == "整机 9.3 W" && charged.estimate.plain == "由电源供电，电池已充满"
                && charged.meta == "电池 31.0 °C · 适配器 96 W")
            && check("预计时间不可用", noEstimate.estimate.plain == "续航估算中，系统还没给出预计时间" && noEstimate.estimate.emphasis.isEmpty
                && chargingNoEstimate.estimate.plain == "充电中，系统还没给出预计充满时间")
            && check("整小时与分钟", hourly.estimate.emphasis == "6 小时" && short.estimate.emphasis == "5 分钟")
            && check("缺字段写“—”", noEstimate.health == "—" && noEstimate.cycles == "—" && noEstimate.designCycles == nil
                && charging.healthHelp.contains("原始满充 — · 设计容量 — · 换算 —")
                && display(BatteryStatus(state: .charging, percent: 50)).rate == "充电 —"
                && display(BatteryStatus(state: .charging, percent: 50)).meta == "电池 31.0 °C · 适配器 —"
                && BatteryCardDisplay.make(status: BatteryStatus(state: .acNotCharging), temperature: nil, systemPower: nil, history: BatteryHistory(), now: Date()).rate == "整机 —")
    }

    static func formats() -> Bool {
        let watts = [(0.0, "0.0 W"), (9.95, "10.0 W"), (9.94, "9.9 W"), (100, "100.0 W"), (24.649, "24.6 W")].allSatisfy { BatteryFormat.watts($0.0) == $0.1 }
        let invalid = [nil, -1, .nan, .infinity].allSatisfy { BatteryFormat.watts($0) == "—" }
        let t0 = Date(timeIntervalSince1970: 1_900_000_000)
        func history(_ values: [(TimeInterval, Int, BatteryPowerState, Double?)]) -> BatteryHistory {
            BatteryHistory(records: values.enumerated().map { index, value in
                BatteryHistoryRecord(sampledAt: t0.addingTimeInterval(value.0), percent: value.1, state: value.2, dischargeWatts: value.3, segmentStart: index == 0)
            })
        }
        let used = history((0...72).map { (Double($0) * 300, 90 - $0 / 3, .battery, $0 % 2 == 0 ? 8 : 9.2) })
        let usedText = display(BatteryStatus(state: .battery, percent: 66), history: used, now: t0.addingTimeInterval(72 * 300)).summary
        let noWatts = history([(0, 80, .battery, nil), (300, 79, .battery, nil)])
        let noWattsText = display(BatteryStatus(state: .battery, percent: 79), history: noWatts, now: t0.addingTimeInterval(300)).summary
        let fresh = display(BatteryStatus(state: .battery, percent: 58), history: history([(0, 58, .battery, 8.1)]), now: t0.addingTimeInterval(240)).summary
        let empty = display(BatteryStatus(state: .battery, percent: 58), now: t0).summary
        let acDay = history((0...288).map { (Double($0) * 300, 80, .acNotCharging, nil) })
        let acText = display(BatteryStatus(state: .acNotCharging, percent: 80), history: acDay, now: t0.addingTimeInterval(86400)).summary
        let acShort = display(BatteryStatus(state: .acNotCharging, percent: 80), history: history([(0, 80, .acNotCharging, nil), (300, 80, .acNotCharging, nil)]),
                              now: t0.addingTimeInterval(5400)).summary
        return check("功率格式边界", watts && invalid)
            && check("用电池摘要", usedText == "用电池 6 小时 · 耗电 24% · 平均 8.6 W")
            && check("没有功率时省略平均", noWattsText == "用电池 5 分钟 · 耗电 1%")
            && check("刚启动写已记录", fresh == "已记录 4 分钟" && empty == "已记录 1 分钟")
            && check("近 24 小时未用电池", acText == "近 24 小时未用电池" && acShort == "已记录 1 小时 30 分")
    }

    static func availabilityAndHover() -> Bool {
        let none = PanelPreviewRenderer.syntheticState()
        let base = none.snapshot!
        none.snapshot = SystemSnapshot(timestamp: base.timestamp, cpuUsage: base.cpuUsage, memoryPressure: base.memoryPressure, swapUsedBytes: nil,
            diskAvailableBytes: base.diskAvailableBytes, diskTotalBytes: base.diskTotalBytes, networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
            battery: BatteryMetrics(temperatureCelsius: nil, systemPowerWatts: 8, status: .noBattery), thermal: .nominal)
        let unread = PanelPreviewRenderer.syntheticState()
        let state = PanelPreviewRenderer.batteryState(.discharge)
        guard check("无电池不渲染", !none.renderedCardIDs(for: .system).contains("system.battery") && none.batteryDisplay == nil),
              check("未采集时不渲染", unread.snapshot?.battery.status == nil && !unread.renderedCardIDs(for: .system).contains("system.battery")),
              check("有电池排在磁盘之后", state.renderedCardIDs(for: .system) == ["system.chart", "system.energy", "system.disk", "system.battery"]) else { return false }
        let root = URL(fileURLWithPath: "build/acceptance/battery/tests/panel-app", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        CatRuntime.initialize(state: state, store: CatStore(rootURL: root))
        var hidden = PanelLayout.default
        hidden.cards["system"]?[3].visible = false
        do { try state.saveLayout(hidden, for: "builtin.slim") } catch { print("电池块：保存布局失败 \(error)"); return false }
        guard check("隐藏后不渲染", state.renderedCardIDs(for: .system) == ["system.chart", "system.energy", "system.disk"]) else { return false }
        do { try state.saveLayout(.default, for: "builtin.slim") } catch { return false }
        // 悬停：只选距鼠标不超过 5 分钟的真实样本；没有记录的时段写“无记录”。
        let now = state.batteryNow
        guard let last = state.batteryHistory.records.last else { return false }
        state.batteryHoverDate = last.sampledAt.addingTimeInterval(-100)
        guard check("选最近的真实样本", state.batteryHoverRecord == last && state.batteryHoverText == ["电量 62%", "使用电池"]) else { return false }
        // 设计稿凌晨的 2 小时空档：空档中间离两侧样本都超过 5 分钟。
        let gapStart = now.addingTimeInterval(-288 * 300 + 80 * 300), gapEnd = now.addingTimeInterval(-288 * 300 + 104 * 300)
        state.batteryHoverDate = gapStart.addingTimeInterval(gapEnd.timeIntervalSince(gapStart) / 2)
        guard check("空档写无记录", state.batteryHoverRecord == nil && state.batteryHoverText == ["无记录"]) else { return false }
        let history = BatteryHistory(records: [BatteryHistoryRecord(sampledAt: now.addingTimeInterval(-1000), percent: 50, state: .charging, segmentStart: true)])
        guard check("5 分钟边界", history.selection(at: now.addingTimeInterval(-700), now: now) != nil
                    && history.selection(at: now.addingTimeInterval(-699), now: now) == nil
                    && history.selection(at: now.addingTimeInterval(10), now: now) == nil) else { return false }
        // 斜纹：窗口开头、段与段之间、最后一点到现在超过 330 秒。
        let domain = now.addingTimeInterval(-86400)...now
        let segments = state.batteryHistory.segments(now: now)
        let missing = BatteryHistory.missingPeriods(segments, domain: domain)
        let sparse = PanelPreviewRenderer.batteryState(.sparse)
        let sparseMissing = BatteryHistory.missingPeriods(sparse.batteryHistory.segments(now: sparse.batteryNow), domain: sparse.batteryDomain)
        return check("两段之间一处空档", segments.count == 2 && missing.count == 1
                && abs(missing[0].lowerBound.timeIntervalSince(gapStart.addingTimeInterval(-300))) < 1 && abs(missing[0].upperBound.timeIntervalSince(gapEnd)) < 1)
            && check("刚启动时段起点前全是斜纹", sparseMissing.count == 1 && sparseMissing[0].lowerBound == sparse.batteryDomain.lowerBound
                && abs(sparseMissing[0].upperBound.timeIntervalSince(sparse.batteryNow.addingTimeInterval(-240))) < 1)
            && check("没有点时整段斜纹", BatteryHistory.missingPeriods([], domain: domain) == [domain])
            && check("窗口开头超过 330 秒才算缺失", BatteryHistory.missingPeriods([[BatteryHistoryRecord(sampledAt: domain.lowerBound.addingTimeInterval(331), percent: 50, state: .battery, segmentStart: true)]], domain: domain).first?.upperBound
                == domain.lowerBound.addingTimeInterval(331))
    }

    /// SPEC：正常状态的系统页在 820 pt 内完整显示趋势图、能耗排行和磁盘。电池在磁盘之后，可滚动到达。
    static func firstScreen() async -> Bool {
        var report: [String] = []
        for kind in PanelPreviewRenderer.BatteryPreview.allCases {
            let state = PanelPreviewRenderer.batteryState(kind)
            state.selectedTab = .system
            let panel = PanelHosting.make(state: state)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = panel.controller
            defer { window.contentViewController = nil }
            do {
                let size = try await PanelPreviewRenderer.settleLayout(panel.controller)
                let m = panel.measurements, bottoms = m.cardBottoms
                guard let disk = bottoms["system.disk"], let battery = bottoms["system.battery"], let energy = bottoms["system.energy"],
                      let frame = m.interactionFrames["graph.battery"] else { print("电池首屏：缺少测量 \(bottoms)"); return false }
                report.append("\(kind.rawValue)：面板 \(size.height)，可视 \(m.viewportHeight)，内容 \(m.contentHeight)，磁盘底边 \(disk)，电池底边 \(battery)，电池块高 \(battery - disk)，曲线 \(frame.width)×\(frame.height)")
                guard check("\(kind.rawValue) 首屏", size.width == 360 && size.height <= 820 && energy < disk && disk <= m.viewportHeight && battery > disk),
                      check("\(kind.rawValue) 曲线 328 pt", abs(frame.width - 328) <= 2 && abs(frame.height - 24) <= 0.5) else { print(report.last!); return false }
            } catch { print("电池首屏测量失败：\(error)"); return false }
        }
        print("电池首屏测量：" + report.joined(separator: "；"))
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? Data((report.joined(separator: "\n") + "\n").utf8).write(to: output.appendingPathComponent("first-screen.txt"))
        return true
    }

    static func previews() -> Bool {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var heights: [String] = []
            for kind in PanelPreviewRenderer.BatteryPreview.allCases {
                for dark in [false, true] {
                    let state = PanelPreviewRenderer.batteryState(kind)
                    guard let png = PanelPreviewRenderer.systemPagePNG(state: state, dark: dark), let bitmap = NSBitmapImageRep(data: png),
                          bitmap.pixelsWide == 720 else { return false }
                    let name = "battery-" + kind.rawValue + (dark ? "-dark" : "-light")
                    try png.write(to: output.appendingPathComponent(name + ".png"))
                    heights.append("\(name)：\(bitmap.pixelsHigh / 2) pt")
                }
            }
            // 悬停：真实样本的时刻、电量和供电状态。
            for dark in [false, true] {
                let state = PanelPreviewRenderer.batteryState(.discharge)
                state.chartHoverKind = "battery"
                state.batteryHoverDate = state.batteryNow.addingTimeInterval(-3 * 3600 - 60)
                guard state.batteryHoverRecord != nil, let png = PanelPreviewRenderer.systemPagePNG(state: state, dark: dark) else { return false }
                try png.write(to: output.appendingPathComponent("battery-hover" + (dark ? "-dark.png" : "-light.png")))
            }
            try Data((heights.joined(separator: "\n") + "\n").utf8).write(to: output.appendingPathComponent("heights.txt"))
            return true
        } catch { print("电池合成预览失败：\(error)"); return false }
    }
}
