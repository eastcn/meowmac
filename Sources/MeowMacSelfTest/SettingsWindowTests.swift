import AppKit
import MeowMacUI

@MainActor
enum SettingsWindowTests {
    final class Draft: SettingsDraftSession {
        var saved = 0, value = 0, succeed = true
        var isDirty: Bool { value != saved }
        var canSave: Bool { isDirty }
        var isBusy: Bool { false }
        var statusText: String { "合成草稿" }
        func save() async -> Bool { if succeed { saved = value }; return succeed }
        func discard() { value = saved }
    }
    static func navigation() async -> Bool {
        let flow = SettingsNavigation(), draft = Draft()
        flow.sessions[.appearance] = draft
        var closed = false; flow.onClose = { closed = true }
        guard flow.request(.section(.appearance)) else { return false }
        draft.value = 1
        guard !flow.request(.section(.network)), flow.pending == .section(.network), flow.section == .appearance else { return false }
        await flow.resolve(.keepEditing)
        guard flow.section == .appearance, draft.value == 1, flow.pending == nil else { return false }
        _ = flow.request(.section(.network)); draft.succeed = false
        await flow.resolve(.save)
        guard flow.section == .appearance, draft.isDirty else { return false }
        draft.succeed = true; _ = flow.request(.section(.network)); await flow.resolve(.save)
        guard flow.section == .network, draft.saved == 1, !draft.isDirty else { return false }
        _ = flow.request(.section(.appearance)); draft.value = 2
        _ = flow.request(.section(.cats)); await flow.resolve(.discard)
        guard flow.section == .cats, draft.value == 1 else { return false }
        _ = flow.request(.section(.appearance)); draft.value = 3
        guard !flow.request(.close), !closed else { return false }
        await flow.resolve(.keepEditing)
        guard !closed, draft.value == 3 else { return false }
        _ = flow.request(.close); await flow.resolve(.discard)
        guard closed, draft.value == 1 else { return false }
        closed = false; draft.value = 4; draft.succeed = false
        _ = flow.request(.close); await flow.resolve(.save)
        guard !closed, flow.section == .appearance else { return false }
        draft.succeed = true; _ = flow.request(.close); await flow.resolve(.save)
        return closed && draft.saved == 4 && !draft.isDirty
    }
    static func window() -> Bool {
        let controller = SettingsWindowController(state: PanelPreviewRenderer.syntheticState())
        controller.open(section: .cats, load: false)
        guard let first = controller.window, first.title == "设置", controller.navigation.section == .cats,
              abs(first.contentRect(forFrameRect: first.frame).width - 760) < 1 else { return false }
        controller.open(section: .network, load: false)
        guard controller.window === first, controller.navigation.section == .network else { return false }
        controller.closeWithoutConfirmation(); controller.open(load: false)
        defer { controller.closeWithoutConfirmation() }
        return controller.window !== first && controller.navigation.section == .network
    }
    static func shortcut() -> Bool {
        SettingsShortcut.matches(characters: ",", modifiers: .command, appActive: true, ownsWindow: true)
            && !SettingsShortcut.matches(characters: ",", modifiers: [.command, .shift], appActive: true, ownsWindow: true)
            && !SettingsShortcut.matches(characters: ",", modifiers: [.command, .option], appActive: true, ownsWindow: true)
            && !SettingsShortcut.matches(characters: ",", modifiers: .command, appActive: false, ownsWindow: true)
            && !SettingsShortcut.matches(characters: ",", modifiers: .command, appActive: true, ownsWindow: false)
            && !SettingsShortcut.matches(characters: "q", modifiers: .command, appActive: true, ownsWindow: true)
    }
    static func fixedSidebar() -> Bool {
        let controller = SettingsWindowController(state: PanelPreviewRenderer.syntheticState())
        controller.open(load: false)
        defer { controller.closeWithoutConfirmation() }
        guard let window = controller.window, let content = window.contentView else { return false }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func check() -> Bool {
            SettingsControlTestSupport.settle(window)
            let items = window.toolbar?.items ?? []
            guard !items.contains(where: { $0.itemIdentifier.rawValue.lowercased().contains("togglesidebar") }) else {
                print("设置窗口仍有侧栏切换工具栏项"); return false
            }
            guard let list = descendants(content).compactMap({ $0 as? NSOutlineView }).first,
                  abs(list.frame.width - 190) < 1, !list.isHiddenOrHasHiddenAncestor else {
                print("设置窗口侧栏列表未显示或宽度不是 190 pt"); return false
            }
            var sidebar: NSView = list
            while let parent = sidebar.superview, !(parent is NSSplitView) { sidebar = parent }
            guard let split = sidebar.superview as? NSSplitView,
                  split.arrangedSubviews.contains(where: { $0 === sidebar }), !split.isSubviewCollapsed(sidebar) else {
                print("设置窗口原生侧栏已收起"); return false
            }
            return true
        }
        guard check() else { return false }
        window.setContentSize(NSSize(width: 760, height: 460))
        guard check() else { return false }
        _ = NSApplication.shared.sendAction(Selector("toggleSidebar:"), to: nil, from: nil)
        return check()
    }
}
