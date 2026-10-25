import AppKit
import MeowMacCore

/// 桌面猫的右键菜单（D5）和设置里“添加指标…”共用的分组目录。
@MainActor
public enum DesktopCatMenu {
    public enum Entry: Equatable {
        case header(String)
        case metric(id: String, title: String, checked: Bool, enabled: Bool)
        case separator
        case footer(String)
    }

    /// 按类分组，已选打勾；满 `maxMetrics` 项时未选项变灰，只剩 1 项时已选项变灰。已选但暂时不在目录里的项也列出，便于取消。
    public static func entries(catalog: [DesktopCatCatalogEntry], selected: [String], inputs: DesktopCatInputs = DesktopCatInputs()) -> [Entry] {
        let full = selected.count >= DesktopCatConfig.maxMetrics, last = selected.count <= 1
        var result: [Entry] = []
        for category in DesktopCatCategory.allCases {
            var rows = catalog.filter { $0.category == category }.map { ($0.id, $0.title) }
            for id in selected where DesktopCatMetric(id: id)?.category == category && !rows.contains(where: { $0.0 == id }) {
                rows.append((id, DesktopCatCatalog.title(for: id, inputs: inputs) + "（暂无数据）"))
            }
            guard !rows.isEmpty else { continue }
            result.append(.header(category.title))
            for (id, title) in rows {
                let checked = selected.contains(id)
                result.append(.metric(id: id, title: title, checked: checked, enabled: checked ? !last : !full))
            }
        }
        result.append(.separator)
        let suffix = full ? "，先取消一项再添加" : last ? "，至少保留 1 项" : ""
        result.append(.footer("已选 \(selected.count) / \(DesktopCatConfig.maxMetrics)" + suffix))
        return result
    }

    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func invoke() { run() }
    }

    private static func item(_ title: String, enabled: Bool = true, checked: Bool = false, action: (() -> Void)?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action == nil ? nil : #selector(Action.invoke), keyEquivalent: "")
        if let action { let target = Action(action); item.target = target; item.representedObject = target }
        item.isEnabled = enabled; item.state = checked ? .on : .off
        return item
    }

    /// 指标目录菜单：点一项即增减并立即写配置。
    public static func metricsMenu(state: PanelState) -> NSMenu {
        let menu = NSMenu(title: "指标"); menu.autoenablesItems = false
        for entry in entries(catalog: state.desktopCatCatalog, selected: state.desktopCat.metrics, inputs: state.desktopCatInputs) {
            switch entry {
            case .header(let title): menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .metric(let id, let title, let checked, let enabled):
                menu.addItem(item(title, enabled: enabled, checked: checked) { state.updateDesktopCat { try $0.toggling(id) } })
            case .separator: menu.addItem(.separator())
            case .footer(let text): menu.addItem(item(text, enabled: false, action: nil))
            }
        }
        return menu
    }

    /// 右键菜单：打开面板；指标 ▸；桌面猫设置…；让猫回去。
    public static func make(state: PanelState, openPanel: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(item("打开面板", action: openPanel))
        menu.addItem(.separator())
        let metrics = item("指标", action: nil)
        metrics.submenu = metricsMenu(state: state)
        menu.addItem(metrics)
        menu.addItem(item("桌面猫设置…") { state.onOpenDesktopCatSettings() })
        menu.addItem(.separator())
        // 等同于在设置里关掉开关。
        menu.addItem(item("让猫回去") { state.updateDesktopCat { $0.with(enabled: false) } })
        return menu
    }
}
