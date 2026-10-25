import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

/// 右键菜单、设置入口与底部设置菜单（plan 条目 4）。
@MainActor
enum DesktopCatSettingsTests {
    static var tests: [(String, @MainActor () async -> Bool)] {
        [
            ("UI.DesktopCat/右键菜单分组勾选与上下限", { menuEntries() }),
            ("UI.DesktopCat/右键菜单原生项与回调", { nativeMenu() }),
            ("UI.DesktopCat/设置分组即时写配置且不进草稿", { await settings() }),
            ("UI.DesktopCat/位置文字与暂放主屏", { positionText() }),
            ("UI.DesktopCat/底部设置菜单显示桌面猫开关", { bottomMenu() }),
            ("UI.DesktopCatWindow/桌面猫设置定位外观栏分组", { await settingsFocus() }),
        ]
    }

    static func state() -> (PanelState, URL) {
        let url = DesktopCatConfigTests.temporaryURL()
        let state = PanelPreviewRenderer.syntheticState()
        state.desktopCatConfigURL = url
        // 与本机是否装了 Claude、Codex 无关：默认按没装，“AI 会话”的目录由 `DesktopCatSessionTests.catalog` 单独覆盖。
        state.agentSessionRootsExist = { false }
        return (state, url)
    }

    static func metrics(_ entries: [DesktopCatMenu.Entry]) -> [(id: String, title: String, checked: Bool, enabled: Bool)] {
        entries.compactMap { if case .metric(let id, let title, let checked, let enabled) = $0 { return (id, title, checked, enabled) }; return nil }
    }

    static func menuEntries() -> Bool {
        let inputs = DesktopCatConfigTests.inputs()
        let catalog = DesktopCatCatalog.entries(inputs)
        // 默认 4 项：上限 8 项（D47），未选项都可加。
        let four = DesktopCatMenu.entries(catalog: catalog, selected: DesktopCatConfig.defaultMetrics, inputs: inputs)
        let headers = four.compactMap { if case .header(let title) = $0 { return title }; return nil }
        guard headers == ["系统", "传感器与电池", "额度", "网络"], four.last == .footer("已选 4 / 8") else { return false }
        let fourRows = metrics(four)
        guard fourRows.count == catalog.count,
              fourRows.filter(\.checked).map(\.id) == ["system.cpu", "system.memory", "quota.claude.minutes:300", "network.speed"],
              fourRows.allSatisfy(\.enabled) else { return false }
        // 满 8 项：未选项变灰。
        let full = DesktopCatMenu.entries(catalog: catalog, selected: DesktopCatConfig.defaultMetrics + eightExtra, inputs: inputs)
        guard full.last == .footer("已选 8 / 8，先取消一项再添加") else { return false }
        let rows = metrics(full)
        guard rows.count == catalog.count, rows.filter(\.checked).count == 8,
              rows.filter(\.checked).allSatisfy(\.enabled), rows.filter({ !$0.checked }).allSatisfy({ !$0.enabled }) else { return false }
        // 7 项：未选项仍可加。
        guard metrics(DesktopCatMenu.entries(catalog: catalog, selected: Array((DesktopCatConfig.defaultMetrics + eightExtra).prefix(7)), inputs: inputs))
                .allSatisfy(\.enabled) else { return false }
        // 只剩 1 项：这一项不能取消，其余可加。
        let single = metrics(DesktopCatMenu.entries(catalog: catalog, selected: ["network.speed"], inputs: inputs))
        guard single.first(where: { $0.id == "network.speed" }).map({ $0.checked && !$0.enabled }) == true,
              single.filter({ $0.id != "network.speed" }).allSatisfy({ !$0.checked && $0.enabled }) else { return false }
        // 已选但暂时不在目录里的项列在本类末尾，可取消。
        var removed = inputs; removed.quotaProviders = [.claude]
        let partial = metrics(DesktopCatMenu.entries(catalog: DesktopCatCatalog.entries(removed), selected: ["system.cpu", "quota.codex.minutes:300"], inputs: removed))
        guard let codex = partial.first(where: { $0.id == "quota.codex.minutes:300" }), codex.checked, codex.enabled,
              codex.title == "Codex · 5 小时（暂无数据）" else { return false }
        return DesktopCatMenu.entries(catalog: catalog, selected: ["system.cpu", "system.disk"], inputs: inputs).last == .footer("已选 2 / 8")
    }

    /// 默认 4 项之外再选 4 项，凑满 8 项。
    static let eightExtra = ["system.power", "system.disk", "quota.codex.minutes:300", "quota.cost.today"]

    static func invoke(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        return NSApplication.shared.sendAction(action, to: item.target, from: item)
    }

    static func nativeMenu() -> Bool {
        let (state, url) = state(); defer { try? FileManager.default.removeItem(at: url) }
        guard state.updateDesktopCat({ $0.with(enabled: true) }) else { return false }
        var opened = 0, settings = 0
        state.onOpenDesktopCatSettings = { settings += 1 }
        let menu = DesktopCatMenu.make(state: state, openPanel: { opened += 1 })
        guard menu.items.map(\.title) == ["打开面板", "", "指标", "桌面猫设置…", "", "让猫回去"],
              menu.items[1].isSeparatorItem, menu.items[4].isSeparatorItem, let submenu = menu.items[2].submenu else { return false }
        guard submenu.items.filter(\.isSectionHeader).map(\.title) == ["系统", "传感器与电池", "额度", "网络"],
              submenu.items.last?.title == "已选 4 / 8", submenu.items.last?.isEnabled == false,
              let cpu = submenu.items.first(where: { $0.title == "CPU" }), cpu.state == .on, cpu.isEnabled,
              let power = submenu.items.first(where: { $0.title == "整机功耗" }), power.state == .off, power.isEnabled else { return false }
        // 点 CPU：立即减为 3 项并写入文件；再开菜单，整机功耗可加。
        guard invoke(cpu), state.desktopCat.metrics == ["system.memory", "quota.claude.minutes:300", "network.speed"],
              ConfigStore.load(from: url).config.desktopCat.metrics == state.desktopCat.metrics else { return false }
        let again = DesktopCatMenu.make(state: state, openPanel: {}).items[2].submenu!
        guard let power2 = again.items.first(where: { $0.title == "整机功耗" }), power2.isEnabled, invoke(power2),
              state.desktopCat.metrics.last == "system.power" else { return false }
        // 加满 8 项：末行“已选 8 / 8”，未选项变灰，点了也不加。
        guard state.updateDesktopCat({ try ["system.cpu", "system.disk", "quota.codex.minutes:300", "quota.cost.today"].reduce($0) { try $0.adding($1) } }),
              state.desktopCat.metrics.count == 8 else { return false }
        let full = DesktopCatMenu.make(state: state, openPanel: {}).items[2].submenu!
        guard full.items.last?.title == "已选 8 / 8，先取消一项再添加", full.items.last?.isEnabled == false,
              let fan = full.items.first(where: { $0.title == "风扇" }), fan.state == .off, !fan.isEnabled,
              let disk = full.items.first(where: { $0.title == "磁盘剩余" }), disk.state == .on, disk.isEnabled else { return false }
        guard invoke(menu.items[0]), opened == 1, invoke(menu.items[3]), settings == 1 else { return false }
        guard invoke(menu.items[5]), !state.desktopCat.enabled, !ConfigStore.load(from: url).config.desktopCat.enabled else { return false }
        return true
    }

    static func settings() async -> Bool {
        let (state, url) = state(); defer { try? FileManager.default.removeItem(at: url) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meowmac-desktopcat-settings-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        CatRuntime.initialize(state: state, store: CatStore(rootURL: root))
        let appearance = AppearanceSettingsModel(state: state)
        var actions = DesktopCatSettingsActions(state: state)
        actions.screens = { [DesktopCatWindowTests.main, DesktopCatWindowTests.side] }
        actions.screenNames = { [DesktopCatWindowTests.main.id: "示例内建显示器", DesktopCatWindowTests.side.id: "示例外接显示器"] }
        func saved() -> DesktopCatConfig { ConfigStore.load(from: url).config.desktopCat }
        func clean() -> Bool { !appearance.isDirty && appearance.statusText == "尚未修改" }
        // 开关。
        actions.setEnabled(true)
        guard state.desktopCat.enabled, saved().enabled, clean() else { return false }
        guard actions.rows.map(\.title) == ["CPU", "内存压力", "Claude · 5 小时", "网速"], actions.rows.allSatisfy(\.canRemove),
              actions.rows[0].value == "24%", actions.rows[3].value == "↓2.4M ↑128.0K", actions.canAdd,
              actions.countText == "已选 4 / 8 · 拖动调整顺序" else { return false }
        // 加满 8 项：“添加指标…”不可用；再减回 4 项。
        for id in eightExtra { actions.add(id) }
        guard saved().metrics == DesktopCatConfig.defaultMetrics + eightExtra, !actions.canAdd,
              actions.countText == "已选 8 / 8 · 拖动调整顺序", clean() else { return false }
        actions.add("network.status")
        guard saved().metrics.count == 8, state.desktopCatError == "最多显示 8 项指标" else { return false }
        for id in eightExtra { actions.remove(id) }
        guard saved().metrics == DesktopCatConfig.defaultMetrics, actions.canAdd else { return false }
        // 删除、添加、重排（拖到下方的行放在它之后，拖到上方的行放在它之前）。
        actions.remove("system.memory")
        guard saved().metrics == ["system.cpu", "quota.claude.minutes:300", "network.speed"], actions.canAdd, clean() else { return false }
        actions.add("system.power")
        guard saved().metrics == ["system.cpu", "quota.claude.minutes:300", "network.speed", "system.power"], clean() else { return false }
        actions.move("system.cpu", onto: "network.speed")
        guard saved().metrics == ["quota.claude.minutes:300", "network.speed", "system.cpu", "system.power"] else { return false }
        actions.move("system.power", onto: "quota.claude.minutes:300")
        guard saved().metrics == ["system.power", "quota.claude.minutes:300", "network.speed", "system.cpu"] else { return false }
        actions.move("system.power", offset: 1)
        guard saved().metrics == ["quota.claude.minutes:300", "system.power", "network.speed", "system.cpu"], clean() else { return false }
        // 减到 1 项后减号不可用，再减被拒。
        for id in ["system.power", "network.speed", "system.cpu"] { actions.remove(id) }
        guard saved().metrics == ["quota.claude.minutes:300"], actions.rows.first?.canRemove == false else { return false }
        actions.remove("quota.claude.minutes:300")
        guard saved().metrics == ["quota.claude.minutes:300"], state.desktopCatError == "至少保留 1 项指标" else { return false }
        // 放回右下角。
        guard state.updateDesktopCat({ $0.with(placement: DesktopCatPlacement(display: DesktopCatWindowTests.side.id, corner: .topLeft)) }),
              !actions.isDefaultPosition, actions.positionText == "示例外接显示器 · 左上角" else { return false }
        actions.resetPosition()
        guard saved().placement == .default, actions.isDefaultPosition, actions.positionText == "示例内建显示器 · 右下角" else { return false }
        // 关闭后指标和位置保持。
        actions.setEnabled(false)
        guard !saved().enabled, saved().metrics == ["quota.claude.minutes:300"], clean() else { return false }
        // 外观栏有未保存草稿时，桌面猫修改不影响草稿，也不被“取消”撤回。
        appearance.style.restoreDefault()
        appearance.style.setChartMinutes(appearance.style.draft.chartMinutes == 15 ? 60 : 15)
        guard appearance.isDirty else { return false }
        actions.setEnabled(true)
        appearance.discard()
        return saved().enabled && state.desktopCat.enabled && !appearance.isDirty
    }

    static func positionText() -> Bool {
        let main = DesktopCatWindowTests.main, side = DesktopCatWindowTests.side
        let names = [main.id: "示例内建显示器", side.id: "示例外接显示器"]
        return DesktopCatSettingsActions.positionText(.default, screens: [main, side], names: names) == "示例内建显示器 · 右下角"
            && DesktopCatSettingsActions.positionText(DesktopCatPlacement(display: main.id, corner: .bottomLeft), screens: [main], names: names) == "示例内建显示器 · 左下角"
            && DesktopCatSettingsActions.positionText(DesktopCatPlacement(display: side.id, corner: .topRight), screens: [main, side], names: names) == "示例外接显示器 · 右上角"
            && DesktopCatSettingsActions.positionText(DesktopCatPlacement(display: side.id, corner: .topRight), screens: [main], names: names) == "未连接的显示器 · 右上角（暂放主屏）"
            && DesktopCatSettingsActions.positionText(.default, screens: [], names: [:]) == "主屏幕 · 右下角"
    }

    static func bottomMenu() -> Bool {
        let (state, url) = state(); defer { try? FileManager.default.removeItem(at: url) }
        let off = SettingsMenu.make(state: state)
        guard let item = off.items.first(where: { $0.title == "显示桌面猫" }), item.state == .off, item.isEnabled, invoke(item),
              state.desktopCat.enabled, ConfigStore.load(from: url).config.desktopCat.enabled else { return false }
        guard let on = SettingsMenu.make(state: state).items.first(where: { $0.title == "显示桌面猫" }), on.state == .on, invoke(on) else { return false }
        return !state.desktopCat.enabled && !ConfigStore.load(from: url).config.desktopCat.enabled
    }

    /// 前台用例（第 2 轮运行）：“桌面猫设置…”打开设置窗口的外观栏并请求滚动到分组。
    static func settingsFocus() async -> Bool {
        let (state, url) = state(); defer { try? FileManager.default.removeItem(at: url) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meowmac-desktopcat-focus-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        CatRuntime.initialize(state: state, store: CatStore(rootURL: root))
        let settings = SettingsWindowController(state: state)
        settings.openDesktopCat()
        defer { settings.closeWithoutConfirmation() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        return settings.window != nil && settings.navigation.section == .appearance && settings.appearance.desktopCatFocus == 1
            && settings.navigation.sessions[.appearance]?.isDirty == false
    }
}
