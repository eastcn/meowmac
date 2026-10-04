import AppKit
import Foundation
import MeowMacCore
import MeowMacUI
import TunCanaryCore
import TunCanaryUI

@MainActor
enum NetworkUITests {
    static let tests: [(String, @MainActor () async -> Bool)] = [
        ("UI.Network/结论、计数与持续时长", { verdicts() }),
        ("UI.Network/已恢复异常与刚启动", { recent() }),
        ("UI.Network/站点、速率与出口变化", { trends() }),
        ("UI.Network/快照含趋势", { snapshot() }),
        ("UI.Network/真实面板首屏", { await firstScreen() }),
        ("UI.Network/浅深色合成预览", { previews() }),
    ]

    private static func display(_ variant: PanelPreviewRenderer.NetworkPreview) -> (PanelState, NetworkDisplay, NetworkTrendsDisplay)? {
        let state = PanelPreviewRenderer.networkState(variant)
        guard let model = state.networkModel, let trends = state.networkTrends else { return nil }
        return (state, model.meowMacDisplay, trends)
    }

    static func verdicts() -> Bool {
        guard let normal = display(.normal)?.1, let warn = display(.warn)?.1, let severe = display(.severe)?.1 else { return false }
        let checks = { (value: NetworkDisplay) in value.checks.map(\.status) }
        guard normal.conclusion == "网络正常", normal.detail == "4 项通过 · 1 项未确认", normal.passed == 4,
              checks(normal) == ["通过", "通过", "通过", "通过", "未确认"] else { print("正常：\(normal.conclusion) \(normal.detail)"); return false }
        guard warn.conclusion == "代理 DNS 提醒 · 8 分钟", warn.detail == "3 项通过 · 1 项提醒 · 1 项未确认",
              warn.checks[3].hint?.isEmpty == false, warn.checks[3].since != nil, warn.checks[1].detail == "已断开，符合预期" else {
            print("提醒：\(warn.conclusion) \(warn.detail)"); return false
        }
        guard severe.conclusion == "代理 TUN 失败 · 12 分钟", severe.detail == "2 项通过 · 1 项失败 · 2 项未确认" else {
            print("严重：\(severe.conclusion) \(severe.detail)"); return false
        }
        // 事件里先“出现”再“变化”，开始时刻取“出现”；中间夹着“消失”的旧异常不算。
        let now = Date()
        let events = [FaultEvent(date: now.addingTimeInterval(-900), kind: .appeared, key: .tunInactive, severity: .warning),
                      FaultEvent(date: now.addingTimeInterval(-800), kind: .cleared, key: .tunInactive, severity: .warning),
                      FaultEvent(date: now.addingTimeInterval(-300), kind: .appeared, key: .tunInactive, severity: .warning),
                      FaultEvent(date: now.addingTimeInterval(-100), kind: .changed, key: .tunInactive, severity: .critical)]
        return AppModel.faultStart(.tunInactive, events: events) == now.addingTimeInterval(-300)
            && AppModel.faultStart(.tunInactive, events: Array(events.prefix(2))) == nil
            && AppModel.faultStart(nil, events: events) == nil
    }

    static func recent() -> Bool {
        guard let normal = display(.normal)?.2, let warn = display(.warn)?.2, let day = display(.day)?.2, let fresh = display(.fresh)?.2 else { return false }
        print("已恢复：\(normal.recent) | \(warn.recent) | \(day.recent) | \(fresh.recent)")
        guard normal.recent.hasPrefix("近 1 小时：海外 "), normal.recent.hasSuffix("失败 1 轮"),
              warn.recent == "近 1 小时：没有已恢复的异常",
              day.recent.hasPrefix("近 24 小时："), day.recent.contains("代理 TUN"), day.recent.contains("失败"),
              day.recent.contains("代理 DNS"), day.recent.contains("提醒"), day.recent.contains("海外"),
              fresh.recent.hasSuffix("启动，较早时段暂无记录") else { return false }
        // 超过 3 条时写“等 N 项”；最后一轮仍失败的站点不算已恢复。
        let now = Date()
        var history = NetworkHistory()
        history.append(sites: [SiteRoundRecord(sampledAt: now.addingTimeInterval(-60), group: .overseas, passed: 0, total: 2, medianMilliseconds: nil)], now: now)
        let events = (0..<4).flatMap { index -> [FaultEvent] in
            let key: FaultKey = [.tunInactive, .mihomoNoResponse, .dnsNotRestored, .tailnetRoute][index]
            return [FaultEvent(date: now.addingTimeInterval(Double(-3000 + index * 600)), kind: .appeared, key: key, severity: .warning),
                    FaultEvent(date: now.addingTimeInterval(Double(-2900 + index * 600)), kind: .cleared, key: key, severity: .warning)]
        }
        let text = PanelState.recentText(events: events, history: history, range: .hour, start: now.addingTimeInterval(-3600), end: now)
        return text.hasSuffix("等 4 项") && text.hasPrefix("近 1 小时：Tailnet") && !text.contains("海外")
    }

    static func trends() -> Bool {
        guard let (_, severeDisplay, severe) = display(.severe), let (_, _, normal) = display(.normal), let (dayState, dayDisplay, day) = display(.day),
              let (_, warnDisplay, _) = display(.warn) else { return false }
        let overseas = severe.sites[1], subnet = normal.sites[2]
        guard overseas.value == "失败", overseas.valueDetail == "连续 6 轮", overseas.valueTone == .red, overseas.detail == "0 / 4 通过",
              subnet.value == "—", !subnet.probed, subnet.detail == "0 / 0 · 不探测",
              normal.sites[1].points.count == 30, normal.sites[1].points.filter(\.failed).count == 1,
              normal.sites[0].unit == " ms", normal.sites[0].valueDetail == "延迟中位数" else { return false }
        // 24 小时：站点 10 分钟一桶，空档画斜纹；速率 5 分钟一桶。
        guard day.range == .day, day.sites[0].points.count <= 144, day.sites[0].points.count >= 138,
              day.sites[0].missing.count == 1, day.traffic[0].missing.count == 1,
              day.traffic[0].points.count <= 288, day.traffic[0].points.allSatisfy({ $0.high != nil }) else {
            print("24 小时：站点 \(day.sites[0].points.count) 点 \(day.sites[0].missing)，速率 \(day.traffic[0].points.count) 点 \(day.traffic[0].missing)"); return false
        }
        dayState.networkRange = .hour
        guard dayState.networkTrends?.sites[0].points.count == 30 else { return false }
        // 出口：Cloudflare 30 天里变过 2 次；提醒状态 Claude 刚变过。
        let cloudflare = dayDisplay.egress[0], claude = warnDisplay.egress[1]
        guard cloudflare.changes == 2, cloudflare.ip == "2001:db8:d002:0:188:253:121:92", claude.changes == 1,
              claude.segments.last?.ip == "198.51.100.27", severeDisplay.egress.count == 2 else {
            print("出口：\(cloudflare.segments.map(\.ip)) \(claude.segments.map(\.ip))"); return false
        }
        return PanelState.rate(2.4 * 1024 * 1024) == ("2.4", " MB/s") && PanelState.rate(128 * 1024) == ("128", " KB/s")
            && PanelState.rate(12.34 * 1024) == ("12.3", " KB/s") && PanelState.niceLatency(0) == 100 && PanelState.niceLatency(950) == 1500
    }

    static func snapshot() -> Bool {
        let state = PanelPreviewRenderer.networkState(.warn)
        guard let data = try? JSONEncoder().encode(PanelSnapshot(state: state)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let network = object["network"] as? [String: Any], let trends = network["trends"] as? [String: Any],
              (trends["sites"] as? [Any])?.count == 3, (trends["traffic"] as? [Any])?.count == 2, trends["recent"] is String else { return false }
        return object.count == 8
    }

    static func firstScreen() async -> Bool {
        for variant in [PanelPreviewRenderer.NetworkPreview.normal, .warn] {
            let state = PanelPreviewRenderer.networkState(variant)
            let panel = PanelHosting.make(state: state)
            let controller = panel.controller, measurements = panel.measurements
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentViewController = controller
            defer { window.contentViewController = nil }
            do {
                let size = try await PanelPreviewRenderer.settleLayout(controller)
                let bottoms = measurements.cardBottoms
                print("网络页 \(variant.rawValue)：面板 \(size.height)，固定 \(measurements.fixedHeight)，内容 \(measurements.contentHeight)，可视 \(measurements.viewportHeight)，"
                      + "底边 \(bottoms.filter { $0.key.hasPrefix("network.") }.sorted { $0.value < $1.value }.map { "\($0.key)=\($0.value)" })")
                guard abs(size.width - 360) < 0.5, size.height <= 820,
                      let checks = bottoms["network.checks"], let sites = bottoms["network.sites"], let traffic = bottoms["network.traffic"],
                      bottoms["network.egress"] != nil, checks < sites, sites < traffic else { return false }
                // 正常：结论、检查、站点和速率都在首屏；提醒（1 项展开）：结论、检查和站点在首屏。
                let required = variant == .normal ? traffic : sites
                guard required <= measurements.viewportHeight else { return false }
            } catch { print("网络页尺寸验证失败：\(error)"); return false }
        }
        return true
    }

    static func previews() -> Bool {
        let output = URL(fileURLWithPath: "build/acceptance/network/previews", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for variant in PanelPreviewRenderer.NetworkPreview.allCases {
                for dark in [false, true] {
                    guard let image = PanelPreviewRenderer.networkPagePNG(state: PanelPreviewRenderer.networkState(variant), dark: dark),
                          let bitmap = NSBitmapImageRep(data: image), bitmap.pixelsWide == 720 else { return false }
                    try image.write(to: output.appendingPathComponent(variant.rawValue + (dark ? "-dark.png" : "-light.png")))
                }
            }
            return true
        } catch { print("网络页预览失败：\(error)"); return false }
    }
}
