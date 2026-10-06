import AppKit
import SwiftUI
import MeowMacCore

@MainActor
public enum SettingsMenu {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func invoke() { run() }
    }
    public static func make(state: PanelState) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, to destination: NSMenu? = nil, key: String = "", enabled: Bool = true, checked: Bool = false, action: @escaping () -> Void) {
            let target = Action(action)
            let item = NSMenuItem(title: title, action: #selector(Action.invoke), keyEquivalent: key)
            item.target = target; item.representedObject = target
            item.isEnabled = enabled; item.state = checked ? .on : .off
            (destination ?? menu).addItem(item)
        }
        add("设置…", key: ",") { state.onOpenSettings(nil) }
        menu.addItem(.separator())
        add("打开配置文件…", action: state.onOpenConfig)
        add("在访达中显示配置目录", action: state.onShowConfigFolder)
        menu.addItem(.separator())
        add("关于 MeowMac") { NSApplication.shared.orderFrontStandardAboutPanel(nil) }
        add("退出 MeowMac", key: "q", action: state.onQuit)
        return menu
    }
    public static func cleanTerminalMenu(state: PanelState) -> NSMenu {
        state.onPrepareCleanTerminalMenu()
        let menu = NSMenu(title: "终端"); menu.autoenablesItems = false
        for terminal in CleanTerminal.allCases {
            var title = terminal.name
            if terminal == .automatic, let selected = terminal.resolved(available: state.availableCleanTerminals) {
                title += "（当前：" + selected.name + "）"
            }
            let target = Action { state.onSelectCleanTerminal(terminal) }
            let item = NSMenuItem(title: title, action: #selector(Action.invoke), keyEquivalent: "")
            item.target = target; item.representedObject = target
            item.state = state.cleanTerminalPreference == terminal ? .on : .off
            item.isEnabled = terminal == .automatic || state.availableCleanTerminals.contains(terminal)
            menu.addItem(item)
            if terminal == .automatic { menu.addItem(.separator()) }
        }
        return menu
    }

    /// D41：总开关加各类开关。未授权时第一项引导到系统设置。
    public static func presentCleanTerminals(state: PanelState, anchor: NSView) {
        cleanTerminalMenu(state: state).popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY), in: anchor)
    }

    static func present(state: PanelState) {
        guard let event = NSApplication.shared.currentEvent, let view = event.window?.contentView else { return }
        NSMenu.popUpContextMenu(make(state: state), with: event, for: view)
    }
    public static var configurationFile: URL { ConfigStore.defaultURL }
    public static var configurationDirectory: URL { configurationFile.deletingLastPathComponent() }
}

struct SettingsMenuPreview: View {
    let state: PanelState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(SettingsMenu.make(state: state).items.enumerated()), id: \.offset) { _, item in
                if item.isSeparatorItem { SectionRule().padding(.horizontal, Design.rowGap).padding(.vertical, Design.smallGap) }
                else {
                    HStack(spacing: Design.gap) {
                        Text(item.state == .on ? "✓" : "").frame(width: Design.cardInset)
                        Text(item.title)
                        if item.submenu != nil { Spacer(minLength: 0); Text("›").font(Design.button) }
                        Spacer(minLength: 0)
                        if !item.keyEquivalent.isEmpty { Text("⌘" + item.keyEquivalent.uppercased()).foregroundStyle(Design.secondary) }
                    }.font(Design.body).foregroundStyle(item.isEnabled ? Design.label : Design.secondary).frame(height: Design.menuRow)
                }
            }
        }.padding(Design.gap).frame(width: Design.menuWidth).modifier(GlassSurface())
    }
}
