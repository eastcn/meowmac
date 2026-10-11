import AppKit
import Foundation
import MeowMacCore
import MeowMacUI
import TunCanaryCore
import TunCanaryUI

@MainActor
enum NetworkPowerBacklogTests {
    static let tests: [(String, @MainActor () async -> Bool)] = [
        ("Backlog.Power/负值缺测与合法换算", { power() }),
        ("Backlog.Power/无效采样不进入功耗曲线", { powerChart() }),
        ("Backlog.Network/失败域名与原因进入展示模型", { siteDetails() }),
        ("Backlog.Network/恢复替换旧失败与空结果", { recovery() }),
        ("Backlog.Network/长域名浅深色合成预览", { previews() }),
        ("Backlog.Network/真实入口展开收起与隐藏卡片", { await nativeDisclosure() }),
    ]

    static func power() -> Bool {
        for invalid in [-1, -7082, Int.min] {
            let value = BatteryMetrics.parse(temperature: 3051, systemLoad: invalid)
            guard value.systemPowerWatts == nil, value.temperatureCelsius == 30.51 else {
                print("无效 SystemLoad \(invalid) 被显示为 \(String(describing: value.systemPowerWatts)) W")
                return false
            }
        }
        return BatteryMetrics.parse(temperature: nil, systemLoad: nil).systemPowerWatts == nil
            && BatteryMetrics.parse(temperature: 3051, systemLoad: 7082).systemPowerWatts == 7.082
            && BatteryMetrics.parse(temperature: nil, systemLoad: 0).systemPowerWatts == 0
    }

    static func powerChart() -> Bool {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        state.now = { now }
        for (index, load) in [8000, -7000, 9000, -1].enumerated() {
            let snapshot = SystemSnapshot(timestamp: now.addingTimeInterval(Double(index - 3) * 10), cpuUsage: 0.2,
                memoryPressure: .normal, swapUsedBytes: nil, diskAvailableBytes: nil, diskTotalBytes: nil,
                networkReceivedBytesPerSecond: nil, networkSentBytesPerSecond: nil,
                battery: .parse(temperature: 3000, systemLoad: load), thermal: .nominal)
            state.snapshot = snapshot
            state.chartHistory.append(snapshot)
        }
        guard let power = state.systemTrends.first(where: { $0.kind == "power" }) else { return false }
        guard power.current == "—", power.points.map(\.value) == [8, 9], power.segments?.count == 2,
              power.help.contains("未读到有效功耗") else {
            print("功耗当前值 \(power.current)，曲线 \(power.points.map(\.value))")
            return false
        }
        return true
    }

    static func fixture() -> AppModel {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = AppModel(now: { now })
        let values: [(String, String, SiteGroup, ProbeCategory)] = [
            ("timeout", "slow.example.com", .overseas, .timeout),
            ("dns", "missing.example.com", .mainland, .dnsFailure),
            ("ok", "ok.example.com", .overseas, .reachable),
            ("restricted", "limited.example.com", .overseas, .restricted),
            ("denied", "permission.example.com", .tailnet, .localNetworkDenied),
        ]
        for (id, host, group, category) in values {
            let site = Site(id: id, name: "示例 " + id, group: group,
                url: URL(string: "https://user:secret@\(host):8443/private?token=hidden")!, isKey: false, inLightProbe: true)
            model.siteHistory.record(SiteResult(site: site, category: category,
                medianLatency: category == .reachable ? 0.015 : nil, attempts: [], checkedAt: now))
        }
        return model
    }

    static func rows(_ model: AppModel) -> [[String: Any]]? {
        guard let data = try? JSONEncoder().encode(model.meowMacDisplay),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["siteResults"] as? [[String: Any]]
    }

    static func siteDetails() -> Bool {
        guard let rows = rows(fixture()), rows.count == 5 else {
            print("站点结果在网络展示模型中丢失")
            return false
        }
        let failures = rows.filter { $0["failed"] as? Bool == true }
        guard failures.count == 2, rows.prefix(2).allSatisfy({ $0["failed"] as? Bool == true }),
              let dns = rows.first(where: { $0["id"] as? String == "dns" }),
              dns["target"] as? String == "missing.example.com:8443", dns["summary"] as? String == "DNS 解析失败",
              dns["checkedAt"] != nil else { return false }
        let text = String(describing: rows)
        return !text.contains("secret") && !text.contains("token=") && !text.contains("/private")
    }

    static func recovery() -> Bool {
        let model = fixture()
        guard var recovered = model.siteHistory.latest(for: "timeout") else { return false }
        recovered.category = .reachable; recovered.medianLatency = 0.018
        recovered.checkedAt = recovered.checkedAt.addingTimeInterval(120)
        model.siteHistory.record(recovered)
        guard let rows = rows(model), rows.count == 5,
              rows.filter({ $0["failed"] as? Bool == true }).count == 1,
              let row = rows.first(where: { $0["id"] as? String == "timeout" }), row["failed"] as? Bool == false,
              (row["summary"] as? String)?.contains("可达") == true else { return false }
        model.siteHistory.clear()
        return Self.rows(model)?.isEmpty == true
    }

    static func previews() -> Bool {
        let model = fixture()
        let site = Site(id: "long", name: "一个名称较长的自定义探测目标，用于检查换行与完整展示", group: SiteGroup(rawValue: "自定义分组"),
            url: URL(string: "https://a-very-long-target-name-for-readable-network-results.example.com:8443")!, isKey: false, inLightProbe: true)
        model.siteHistory.record(SiteResult(site: site, category: .tlsError, medianLatency: nil, attempts: [], checkedAt: model.now()))
        guard let rows = model.meowMacDisplay.siteResults,
              rows.contains(where: { $0.id == "long" && $0.failed && $0.group == "自定义分组" }) else { return false }
        let output = URL(fileURLWithPath: "build/acceptance/backlog-fixes/network", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for dark in [false, true] {
                guard let data = PanelPreviewRenderer.networkProbeResultsPNG(rows, dark: dark),
                      let image = NSBitmapImageRep(data: data), image.pixelsWide == 720, image.pixelsHigh > 0 else { return false }
                try data.write(to: output.appendingPathComponent(dark ? "results-dark.png" : "results-light.png"))
            }
            return true
        } catch { print("网络结果预览失败：\(error)"); return false }
    }

    static func nativeDisclosure() async -> Bool {
        for hideSites in [false, true] {
            let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
            let model = fixture()
            state.now = model.now; state.networkModel = model; state.selectedTab = .network
            let hosting = PanelHosting.make(state: state)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 1),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentViewController = hosting.controller
            defer { window.contentViewController = nil; window.close() }
            do {
                if hideSites {
                    let root = URL(fileURLWithPath: "build/acceptance/backlog-fixes/network/native-layout-" + UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
                    state.layoutStore = PanelLayoutStore(rootURL: root)
                    var layout = PanelLayout.default
                    guard let index = layout.cards["network"]?.firstIndex(where: { $0.id == "network.sites" }),
                          let catID = state.selectedCat?.id else { return false }
                    layout.cards["network"]?[index].visible = false
                    try state.saveLayout(layout, for: catID)
                }
                _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(nanoseconds: 100_000_000)
                guard !hideSites || !state.renderedCardIDs(for: .network).contains("network.sites"),
                      hosting.measurements.interactionFrames["network.result.dns"] == nil else { return false }
                for shouldExpand in [true, false] {
                    let size = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                    guard let frame = hosting.measurements.interactionFrames["network.probeResults"] else {
                        print("探测结果入口消失，隐藏站点卡片：\(hideSites)"); return false
                    }
                    let view = hosting.controller.view
                    let point = view.convert(NSPoint(x: frame.midX, y: view.isFlipped ? frame.midY : size.height - frame.midY), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
                        window.sendEvent(event)
                    }
                    _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                    let resultVisible = hosting.measurements.interactionFrames["network.result.dns"] != nil
                    guard resultVisible == shouldExpand else {
                        print("探测结果未随点击\(shouldExpand ? "展开" : "收起")，隐藏站点卡片：\(hideSites)"); return false
                    }
                }
            } catch { print("探测结果入口验收失败：\(error)"); return false }
        }
        return true
    }
}
