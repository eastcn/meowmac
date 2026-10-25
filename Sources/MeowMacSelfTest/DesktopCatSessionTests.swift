import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

/// 桌面猫的“AI 会话”指标与结束提示（D46，plan 条目 5：D2、D3、D10）。数据全部虚构。
@MainActor
enum DesktopCatSessionTests {
    static var tests: [(String, @MainActor () async -> Bool)] {
        [
            ("Core.DesktopCatSessions/数值、灰色空闲、“—”与悬停提示", { values() }),
            ("Core.DesktopCatSessions/提示区版式：0～2 条、四个角、1 列和 2 列", { layout() }),
            ("Core.DesktopCatSessions/提示区随猫的大小分角", { sizes() }),
            ("Core.DesktopCatSessions/提示命中：提示内、空隙、提示外", { hits() }),
            ("UI.DesktopCatSessions/点提示只关这一条，不开面板", { await click() }),
            ("UI.DesktopCatSessions/没选这项时提示变化不触发渲染", { await unselected() }),
            ("UI.DesktopCatSessions/提示宽度上限与名称截断", { widths() }),
            ("UI.DesktopCatSessions/目录分组：没装不列，选中、取消与满 8 项", { catalog() }),
            ("UI.DesktopCatSessions/菜单与设置的“AI 会话”分组", { menus() }),
            ("Core.DesktopCatSessions/配置读写与坏值", { config() }),
        ]
    }

    static let at: Date = {
        var c = DateComponents(); c.year = 2027; c.month = 1; c.day = 15; c.hour = 14; c.minute = 2
        c.timeZone = TimeZone(identifier: "Asia/Shanghai"); return Calendar(identifier: .gregorian).date(from: c)!
    }()
    static let zone = TimeZone(identifier: "Asia/Shanghai")!

    static func snapshot(claude: Int, codex: Int, unknown: Int = 0, roots: [QuotaProvider: AgentSessionRoot] = [.claude: .ok, .codex: .ok]) -> AgentSessionSnapshot {
        var sessions = (0..<claude).map { AgentSessionState(provider: .claude, id: "c\($0)", phase: .running, lastWriteAt: at, now: at) }
        sessions += (0..<codex).map { AgentSessionState(provider: .codex, id: "x\($0)", phase: .running, lastWriteAt: at, now: at) }
        sessions += (0..<unknown).map { AgentSessionState(provider: .codex, id: "u\($0)", phase: .unknown, lastWriteAt: at, now: at) }
        sessions.append(AgentSessionState(provider: .claude, id: "done", phase: .finished, lastWriteAt: at, now: at))
        return AgentSessionSnapshot(checkedAt: at, roots: roots, sessions: sessions)
    }

    static func item(_ snapshot: AgentSessionSnapshot?) -> DesktopCatItem {
        var inputs = DesktopCatInputs(); inputs.agentSessions = snapshot
        return DesktopCatCatalog.items(selected: [AgentSessionCadence.metricID], inputs: inputs)[0]
    }

    static func values() -> Bool {
        guard DesktopCatMetric(id: "agent.sessions") == .agentSessions, DesktopCatMetric.agentSessions.category == .agents,
              DesktopCatCategory.agents.title == "AI 会话" else { return false }
        let busy = item(snapshot(claude: 2, codex: 1))
        guard busy.label == "AI 会话", busy.value == "3 在跑", busy.bar == nil, !busy.missing, !busy.muted,
              busy.tooltip(timeZone: zone) == "Claude 2 个在跑，Codex 1 个 · 14:02 更新" else { print("在跑：\(busy.tooltip(timeZone: zone))"); return false }
        // 未确认的不计入数值，悬停里追加。
        let unsure = item(snapshot(claude: 1, codex: 0, unknown: 2))
        guard unsure.value == "1 在跑", unsure.tooltip(timeZone: zone) == "Claude 1 个在跑，Codex 0 个，另有 2 个未确认 · 14:02 更新" else { return false }
        // 没有在跑：灰色“空闲”，不是缺数据。
        let idle = item(snapshot(claude: 0, codex: 0))
        guard idle.value == "空闲", idle.muted, !idle.missing, idle.bar == nil else { return false }
        // 某个渠道没装就不写它；读不了写明。
        let onlyCodex = item(snapshot(claude: 0, codex: 1, roots: [.claude: .missing, .codex: .ok]))
        let half = item(snapshot(claude: 0, codex: 1, roots: [.claude: .unavailable, .codex: .ok]))
        guard onlyCodex.tooltip(timeZone: zone) == "Codex 1 个在跑 · 14:02 更新",
              half.tooltip(timeZone: zone) == "Claude 记录读不了，Codex 1 个 · 14:02 更新" else { return false }
        // 两个渠道都读不了、还没检查过：“—”。
        let none = item(snapshot(claude: 0, codex: 0, roots: [.claude: .unavailable, .codex: .missing]))
        let pending = item(nil)
        return none.value == "—" && none.missing && pending.value == "—" && pending.tooltip() == "AI 会话 · 暂无数据"
    }

    static let screen = DesktopCatWindowTests.main.visibleFrame

    /// 窗口里的点换成屏幕坐标。
    static func onScreen(_ rect: CGRect, _ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    static func checkToasts(_ layout: DesktopCatLayout, corner: DesktopCatCorner, base: DesktopCatLayout) -> Bool {
        let frame = DesktopCatGeometry.windowFrame(layout: layout, corner: corner, visibleFrame: screen)
        let baseFrame = DesktopCatGeometry.windowFrame(layout: base, corner: corner, visibleFrame: screen)
        // 窗口贴角不动：猫和气泡的屏幕位置与没有提示时相同。
        guard onScreen(layout.bubbleRect, frame) == onScreen(base.bubbleRect, baseFrame),
              onScreen(layout.catRect, frame) == onScreen(base.catRect, baseFrame) else { print("提示改变了猫或气泡位置：\(corner)"); return false }
        let bounds = CGRect(origin: .zero, size: layout.windowSize)
        for (index, rect) in layout.toastRects.enumerated() {
            guard bounds.contains(rect), rect.height == 24, screen.contains(onScreen(rect, frame)) else { return false }
            // 与气泡同侧对齐。
            guard corner.isLeft ? rect.minX == layout.bubbleRect.minX : rect.maxX == layout.bubbleRect.maxX else { return false }
            if corner.isTop {
                // 上方的角：提示在猫下方 6 pt，新的贴着猫。
                let above = index == 0 ? layout.catRect.maxY : layout.toastRects[index - 1].maxY
                guard rect.minY - above == 6 else { return false }
            } else {
                // 下方的角：提示在气泡上方 6 pt，新的贴着气泡。
                let below = index == 0 ? layout.bubbleRect.minY : layout.toastRects[index - 1].minY
                guard below - rect.maxY == 6 else { return false }
            }
        }
        return true
    }

    static func layout() -> Bool {
        for corner in DesktopCatCorner.allCases {
            for count in [1, 4] {
                let base = DesktopCatLayout(count: count, corner: corner, catTrim: 2)
                for widths in [[], [180], [150, 220], [300, 90, 90]] as [[CGFloat]] {
                    let layout = DesktopCatLayout(count: count, corner: corner, catTrim: 2, toastWidths: widths)
                    guard layout.toastRects.count == min(2, widths.count), layout.toastWidths.allSatisfy({ $0 <= 220 }),
                          checkToasts(layout, corner: corner, base: base) else { print("提示版式：\(corner) \(count) 项 \(widths)"); return false }
                    if widths.isEmpty, layout != base { return false }
                    if !widths.isEmpty, layout.contentSize.height != base.contentSize.height + CGFloat(layout.toastRects.count) * 30 { return false }
                }
            }
        }
        return true
    }

    static func sizes() -> Bool {
        for corner in DesktopCatCorner.allCases {
            for height in [36, 52, 104] as [CGFloat] {
                let base = DesktopCatLayout(count: 4, corner: corner, catHeight: height)
                let layout = DesktopCatLayout(count: 4, corner: corner, catHeight: height, toastWidths: [200, 120])
                guard checkToasts(layout, corner: corner, base: base) else { print("提示随大小：\(corner) \(height)"); return false }
            }
        }
        return true
    }

    static func hits() -> Bool {
        for corner in DesktopCatCorner.allCases {
            let layout = DesktopCatLayout(count: 2, corner: corner, toastWidths: [200, 140])
            let shape = DesktopCatHitShape(layout: layout, catMask: DesktopCatSizeTests.halfMask)
            let first = layout.toastRects[0], second = layout.toastRects[1]
            let gapY = corner.isTop ? (first.maxY + second.minY) / 2 : (second.maxY + first.minY) / 2
            guard shape.toast(at: CGPoint(x: first.midX, y: first.midY)) == 0, shape.toast(at: CGPoint(x: second.midX, y: second.midY)) == 1,
                  shape.contains(CGPoint(x: first.midX, y: first.midY)),
                  // 两条之间的空隙、胶囊圆角外、提示外都不命中。
                  shape.toast(at: CGPoint(x: second.midX, y: gapY)) == nil, !shape.contains(CGPoint(x: second.midX, y: gapY)),
                  shape.toast(at: CGPoint(x: first.minX + 1, y: first.minY + 1)) == nil,
                  shape.toast(at: CGPoint(x: corner.isLeft ? first.maxX + 5 : first.minX - 5, y: first.midY)) == nil else {
                print("提示命中：\(corner)"); return false
            }
        }
        return true
    }

    static func notice(_ name: String) -> AgentSessionToast {
        .single(AgentSessionNotice(id: "claude:" + name, provider: .claude, name: name, duration: 180, completedAt: at, shownAt: at))
    }

    static func click() async -> Bool {
        let (state, controller, url) = DesktopCatWindowTests.controller(enabled: true); defer { try? FileManager.default.removeItem(at: url) }
        guard state.updateDesktopCat({ try $0.adding(AgentSessionCadence.metricID) }) else { return false }
        var opened = 0, dismissed: [[String]] = []
        controller.onOpenPanel = { opened += 1 }
        state.onDismissAgentSessionToast = { dismissed.append($0) }
        state.agentSessionToasts = [notice("示例项目"), .more(count: 2, ids: ["a", "b"])]
        controller.apply(); defer { controller.hide() }
        guard let window = controller.window, controller.model.toasts.count == 2 else { print("点提示：toasts=\(controller.model.toasts.count) window=\(controller.window != nil)"); return false }
        let layout = controller.model.layout
        func point(_ rect: CGRect) -> CGPoint { CGPoint(x: window.frame.minX + rect.midX, y: window.frame.maxY - rect.midY) }
        var mouse = point(layout.toastRects[0])
        controller.mouseLocation = { mouse }
        // 点第 0 条：只关它，不开面板，不拖动。
        controller.mouseDown(); controller.mouseUp()
        guard dismissed == [["claude:示例项目"]], opened == 0, !controller.model.dragging else { print("点提示：\(dismissed) \(opened)"); return false }
        // 点合并的那条：关掉它包含的全部。
        mouse = point(layout.toastRects[1])
        controller.mouseDown(); controller.mouseUp()
        guard dismissed.last == ["a", "b"], opened == 0 else { print("点合并：\(dismissed) \(opened)"); return false }
        // 在提示上按下、拖到别处松手：不关，不移动窗口。
        let home = window.frame
        mouse = point(layout.toastRects[0])
        controller.mouseDown(); mouse.y -= 120; controller.mouseDragged(); controller.mouseUp()
        guard dismissed.count == 2, window.frame == home, opened == 0 else { print("拖开：\(dismissed) \(opened) \(window.frame) \(home)"); return false }
        // 点气泡仍然打开面板。
        mouse = point(layout.bubbleRect)
        controller.mouseDown(); controller.mouseUp()
        return opened == 1
    }

    static func unselected() async -> Bool {
        let (state, controller, url) = DesktopCatWindowTests.controller(enabled: true); defer { try? FileManager.default.removeItem(at: url) }
        controller.apply(); defer { controller.hide() }
        let bubbles = controller.bubbleUpdates, toasts = controller.toastUpdates
        let size = controller.window?.frame.size
        state.agentSessionToasts = [notice("示例项目")]
        try? await Task.sleep(nanoseconds: 30_000_000)
        state.agentSessionToasts = [notice("示例项目"), notice("notes-app")]
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard controller.bubbleUpdates == bubbles, controller.toastUpdates == toasts, controller.model.toasts.isEmpty,
              controller.window?.frame.size == size else { print("未选：\(controller.bubbleUpdates - bubbles) \(controller.toastUpdates - toasts)"); return false }
        // 选上之后同样的变化才显示，窗口按提示区长高。
        guard state.updateDesktopCat({ try $0.adding(AgentSessionCadence.metricID) }) else { return false }
        controller.apply()
        try? await Task.sleep(nanoseconds: 30_000_000)
        // 5 项气泡加 2 条提示：窗口高度按真实版式，提示区 2 × 30 pt。
        let grown = controller.model.layout
        return controller.toastUpdates == toasts + 1 && controller.model.toasts.count == 2 && grown.toastRects.count == 2
            && controller.window?.frame.size == grown.windowSize
            && grown.windowSize.height == DesktopCatLayout(count: 5, corner: .bottomRight, catTrim: grown.catTrim).windowSize.height + 60
    }

    static func widths() -> Bool {
        let short = notice("notes-app"), long = notice("一个名字很长的示例会话标题，再长一些")
        let m1 = DesktopCatToastText.metrics(short), m2 = DesktopCatToastText.metrics(long)
        let more = DesktopCatToastText.metrics(.more(count: 3, ids: ["a", "b", "c"]))
        // 最宽 220 pt；名称最宽 96 pt；截断只发生在名称上（其余部分完整留出）。
        return m1.width <= 220 && m2.width == 220 && m2.nameWidth <= 96 && DesktopCatToastText.truncatesName(long)
            && more.width < 220 && more.nameWidth == 0 && !DesktopCatToastText.truncatesName(.more(count: 3, ids: []))
    }

    // MARK: - 目录入口（plan 条目 6，D11）

    static func catalog() -> Bool {
        var inputs = DesktopCatConfigTests.inputs()
        // 两个根目录都不存在：不列。
        guard !DesktopCatCatalog.entries(inputs).contains(where: { $0.id == AgentSessionCadence.metricID }) else { return false }
        inputs.agentSessionsInstalled = true
        let entries = DesktopCatCatalog.entries(inputs)
        guard let last = entries.last, last.id == AgentSessionCadence.metricID, last.category == .agents, last.title == "AI 会话" else { return false }
        let menu = DesktopCatMenu.entries(catalog: entries, selected: DesktopCatConfig.defaultMetrics, inputs: inputs)
        let headers = menu.compactMap { if case .header(let title) = $0 { return title }; return nil }
        guard headers == ["系统", "传感器与电池", "额度", "网络", "AI 会话"],
              let row = DesktopCatSettingsTests.metrics(menu).first(where: { $0.id == AgentSessionCadence.metricID }),
              !row.checked, row.enabled, row.title == "AI 会话" else { return false }
        // 选中：打勾；满 8 项时未选的它也变灰；只剩它一项时不能取消。
        let selected = DesktopCatSettingsTests.metrics(DesktopCatMenu.entries(catalog: entries, selected: ["system.cpu", AgentSessionCadence.metricID], inputs: inputs))
        let full = DesktopCatSettingsTests.metrics(DesktopCatMenu.entries(catalog: entries, selected: DesktopCatConfig.defaultMetrics + DesktopCatSettingsTests.eightExtra, inputs: inputs))
        let only = DesktopCatSettingsTests.metrics(DesktopCatMenu.entries(catalog: entries, selected: [AgentSessionCadence.metricID], inputs: inputs))
        guard selected.first(where: { $0.id == AgentSessionCadence.metricID }).map({ $0.checked && $0.enabled }) == true,
              full.first(where: { $0.id == AgentSessionCadence.metricID }).map({ !$0.checked && !$0.enabled }) == true,
              only.first(where: { $0.id == AgentSessionCadence.metricID }).map({ $0.checked && !$0.enabled }) == true else { return false }
        // 已选但没装：仍列在本类末尾，标“暂无数据”，可取消；气泡里显示“—”。
        var absent = inputs; absent.agentSessionsInstalled = false
        let stale = DesktopCatSettingsTests.metrics(DesktopCatMenu.entries(catalog: DesktopCatCatalog.entries(absent),
                                                                            selected: ["system.cpu", AgentSessionCadence.metricID], inputs: absent))
        guard let row2 = stale.first(where: { $0.id == AgentSessionCadence.metricID }), row2.checked, row2.enabled,
              row2.title == "AI 会话（暂无数据）" else { return false }
        return DesktopCatCatalog.items(selected: [AgentSessionCadence.metricID], inputs: absent)[0].value == "—"
    }

    static func menus() -> Bool {
        let (state, url) = DesktopCatSettingsTests.state(); defer { try? FileManager.default.removeItem(at: url) }
        guard state.updateDesktopCat({ $0.with(enabled: true) }) else { return false }
        func submenu() -> NSMenu { DesktopCatMenu.make(state: state, openPanel: {}).items[2].submenu! }
        // 没装：右键菜单和设置的“添加指标…”目录（同一个菜单）都不列。
        guard !submenu().items.contains(where: { $0.title == "AI 会话" }),
              !DesktopCatMenu.metricsMenu(state: state).items.contains(where: { $0.title == "AI 会话" }) else { return false }
        state.agentSessionRootsExist = { true }
        let menu = submenu()
        guard menu.items.filter(\.isSectionHeader).map(\.title) == ["系统", "传感器与电池", "额度", "网络", "AI 会话"],
              let item = menu.items.last(where: { $0.title == "AI 会话" && !$0.isSectionHeader }), item.state == .off, item.isEnabled,
              let action = item.action, let target = item.target as? NSObject else { return false }
        // 点一下：加入并写配置；设置的指标行列出它。
        target.perform(action, with: item)
        guard state.desktopCat.metrics.last == AgentSessionCadence.metricID,
              ConfigStore.load(from: url).config.desktopCat.metrics.last == AgentSessionCadence.metricID,
              DesktopCatSettingsActions(state: state).rows.last?.title == "AI 会话" else { return false }
        // 再点：取消。
        let again = submenu().items.last { $0.title == "AI 会话" && !$0.isSectionHeader }!
        (again.target as? NSObject)?.perform(again.action!, with: again)
        return !state.desktopCat.metrics.contains(AgentSessionCadence.metricID)
            && !ConfigStore.load(from: url).config.desktopCat.metrics.contains(AgentSessionCadence.metricID)
    }

    static func config() -> Bool {
        let base = #"{"schemaVersion":1,"quotaRemainingWarn":0.15,"desktopCat":{"enabled":true,"metrics":"#
        // 正常读写。
        guard DesktopCatConfigTests.load(base + #"["system.cpu","agent.sessions"]}}"#, check: { config, _, _ in
            config.metrics == ["system.cpu", "agent.sessions"] && config.diagnostics.isEmpty
        }) else { return false }
        // 重复去重、拼错的 id 跳过，与 D45 一致。
        guard DesktopCatConfigTests.load(base + #"["agent.sessions","agent.sessions","agent.session","system.cpu"]}}"#, check: { config, _, _ in
            config.metrics == ["agent.sessions", "system.cpu"] && config.diagnostics.count == 2
        }) else { return false }
        let url = DesktopCatConfigTests.temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            let config = try DesktopCatConfig(enabled: true).adding(AgentSessionCadence.metricID)
            try ConfigStore.saveDesktopCat(config, to: url)
            let loaded = ConfigStore.load(from: url).config.desktopCat
            guard loaded.metrics == DesktopCatConfig.defaultMetrics + [AgentSessionCadence.metricID], AgentSessionCadence.wanted(loaded),
                  !AgentSessionCadence.wanted(loaded.with(enabled: false)), (try? config.adding(AgentSessionCadence.metricID)) == nil else { return false }
            return true
        } catch { return false }
    }
}
