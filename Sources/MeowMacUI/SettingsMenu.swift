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
        func add(_ title: String, key: String = "", enabled: Bool = true, checked: Bool = false, action: @escaping () -> Void) {
            let target = Action(action)
            let item = NSMenuItem(title: title, action: #selector(Action.invoke), keyEquivalent: key)
            item.target = target; item.representedObject = target
            item.isEnabled = enabled; item.state = checked ? .on : .off
            menu.addItem(item)
        }
        add("打开配置文件…", action: state.onOpenConfig)
        add("在访达中显示配置目录", action: state.onShowConfigFolder)
        menu.addItem(.separator())
        add("猫配置", enabled: false) {}
        let catRow = NSHostingView(rootView: HStack {
            Text("猫配置"); Spacer(); Text("暂未开放").font(Design.button)
        }.font(Design.body).foregroundStyle(Design.secondary).padding(.horizontal, Design.inset)
            .frame(width: Design.menuWidth, height: Design.menuRow))
        catRow.frame = NSRect(x: 0, y: 0, width: Design.menuWidth, height: Design.menuRow)
        menu.items.last?.view = catRow
        add("开机启动", checked: state.loginEnabled) { state.onToggleLogin(!state.loginEnabled) }
        menu.addItem(.separator())
        add("关于 MeowMac") { NSApplication.shared.orderFrontStandardAboutPanel(nil) }
        add("退出 MeowMac", key: "q", action: state.onQuit)
        return menu
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
                        if !item.isEnabled { Spacer(minLength: 0); Text("暂未开放").font(Design.button) }
                        Spacer(minLength: 0)
                        if !item.keyEquivalent.isEmpty { Text("⌘" + item.keyEquivalent.uppercased()).foregroundStyle(Design.secondary) }
                    }.font(Design.body).foregroundStyle(item.isEnabled ? Design.label : Design.secondary).frame(height: Design.menuRow)
                }
            }
        }.padding(Design.gap).frame(width: Design.menuWidth).modifier(GlassSurface())
    }
}
