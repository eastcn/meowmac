import AppKit
import MeowMacCore
import MeowMacUI

@MainActor
enum ProxyTrafficNativeTests {
    static func syntheticState() -> PanelState {
        let state = PanelPreviewRenderer.networkState(.normal)
        // 网络背景和代理卡片共用同一个固定时钟，所有名称都是虚构的。
        let now = state.now()
        state.selectedTab = .network
        var rows: [ProxyTrafficRow] = []
        let names = ["DemoUpdater", "DemoBrowser Helper With A Long Name", "DemoCoder", "DemoMessenger", "DemoUnknown"]
        for day in 0..<7 {
            for hour in 8...17 {
                let date = Calendar.current.date(byAdding: .day, value: -day, to: now)!
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ProxyTrafficSummaryTests.zone
                let time = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
                let multiplier = Int64((hour == 15 ? 8 : 1) * (7 - day) * 1024 * 1024)
                let processes = names.enumerated().map { (index, name) in (Optional(name), multiplier / Int64(index + 2), multiplier * Int64(6 - index)) }
                let items = processes.flatMap { name, up, down in
                (0..<5).map { i in ProxyTrafficItem(process: name, host: "\(i).updates.example.com", rule: "Match",
                    node: "DemoNode", group: "DemoGroup", up: up / 6, down: down / 6) }
                }.sorted { $0.up + $0.down > $1.up + $1.down }
                rows.append(ProxyTrafficSummaryTests.row(hour: ProxyTrafficTime.hour(time, timeZone: ProxyTrafficSummaryTests.zone),
                processes: processes, items: items, direct: .init(down: multiplier * 20), match: .init(down: multiplier * 10)))
            }
        }
        precondition(rows.allSatisfy({ (try? $0.encoded()) != nil }))
        state.proxyTraffic = ProxyTrafficViewData(rows: rows, available: true)
        return state
    }

    /// 展开整页并使用既有材质退路，仅补充检查文字布局；不替代原生弹出面板验收。
    static func supplementalPreviews() -> Bool {
        let root = URL(fileURLWithPath: "build/acceptance/preview", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let state = syntheticState(), rows = state.proxyTraffic.rows
            var count = 0
            for dark in [false, true] {
                for variant in 0..<6 {
                    state.proxyTraffic = ProxyTrafficViewData(rows: rows, available: variant != 5)
                    state.proxyTrafficRange = [2, 4].contains(variant) ? .week : .today
                    state.expandedProxyProcesses = [1, 3].contains(variant) ? ["process:DemoUpdater"] : []
                    let name = ["today", "today-expanded", "week", "today-expanded-current", "week-current", "unavailable"][variant]
                    guard let png = PanelPreviewRenderer.networkPagePNG(state: state, dark: dark) else { return false }
                    try png.write(to: root.appendingPathComponent("proxy-supplement-" + name + (dark ? "-dark.png" : "-light.png")))
                    count += 1
                }
            }
            print("补充整页合成布局：\(count) 张；展开页面、材质退路，不作为原生图像验收证据")
            return count == 12
        } catch { print("补充预览失败：\(error)"); return false }
    }

    static func previews() async -> Bool {
        let root = URL(fileURLWithPath: "build/acceptance/preview", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let state = syntheticState()
            let rows = state.proxyTraffic.rows
            let hosting = PanelHosting.make(state: state)
            let anchorWindow = NSWindow(contentRect: NSRect(x: 200, y: 700, width: 100, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
            anchorWindow.isReleasedWhenClosed = false
            let anchor = NSButton(frame: NSRect(x: 10, y: 10, width: 70, height: 20)); anchor.title = "合成预览"
            anchorWindow.contentView?.addSubview(anchor); anchorWindow.makeKeyAndOrderFront(nil)
            let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = hosting.controller
            defer { popover.performClose(nil); popover.contentViewController = nil; anchorWindow.close() }
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            var count = 0
            for dark in [false, true] {
                popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                hosting.controller.view.appearance = popover.appearance
                for variant in 0..<6 {
                    state.proxyTraffic = ProxyTrafficViewData(rows: rows, available: variant != 5)
                    state.proxyTrafficRange = [2, 4].contains(variant) ? .week : .today
                    state.expandedProxyProcesses = [1, 3].contains(variant) ? ["process:DemoUpdater"] : []
                    let size = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                    guard popover.isShown, size.width == 360, size.height <= 820,
                          let window = hosting.controller.view.window,
                          let traffic = hosting.measurements.cardBottoms["network.traffic"],
                          traffic <= hosting.measurements.viewportHeight,
                          let scroll = scrollView(in: hosting.controller.view), let document = scroll.documentView else {
                        print("代理卡片首屏或容器不符：\(size)，底边 \(hosting.measurements.cardBottoms)")
                        return false
                    }
                    document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    print("原生代理卡片容器：\(size)，速率底边 \(traffic)，首屏内容高 \(hosting.measurements.viewportHeight)")
                    try await Task.sleep(nanoseconds: 300_000_000)
                    let name = ["today", "today-expanded", "week", "today-expanded-current", "week-current", "unavailable"][variant]
                    try ConfigPreviewCapture.capture(window, to: root.appendingPathComponent("proxy-" + name + (dark ? "-dark.png" : "-light.png")))
                    count += 1
                }
            }
            // 禁用和无网络模型也必须走真实容器，不能因 NetworkPage 不存在而丢卡片。
            state.networkModel = nil; state.proxyTraffic = ProxyTrafficViewData(enabled: false)
            let disabled = try await PanelPreviewRenderer.settleLayout(hosting.controller)
            guard state.renderedCardIDs(for: .network) == ["network.proxy"], disabled.width == 360, disabled.height <= 820 else { return false }
            print("代理卡片：\(count) 张真实360pt弹出面板浅深色截图；网络速率首屏、禁用和无网络模型通过")
            return count == 12
        } catch { print("代理卡片原生预览失败：\(error)"); return false }
    }
}
