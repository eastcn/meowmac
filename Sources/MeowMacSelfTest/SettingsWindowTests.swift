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
}
