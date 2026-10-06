import AppKit
import Foundation
import MeowMacCore
import MeowMacSystem
import MeowMacUI

@MainActor
enum AIAgentSettingsTests {
    static func controls() -> Bool {
        let root = URL(fileURLWithPath: "build/acceptance/ai-agent-launch/settings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("config.json")
            let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
            var installations = [AIAgentInstallation(agent: .codex, location: URL(fileURLWithPath: "/opt/homebrew/bin/codex"))]
            var detected = 0
            let controller = AIAgentController(state: state, configURL: url, detect: { detected += 1; return installations }, readLast: { nil })
            state.onDetectAIAgents = { controller.refresh() }; state.onSelectAIAgent = { controller.select($0) }; state.onSetAIDiagnosisEntry = { controller.setEntry($0) }
            let actions = ImmediateSettingsActions(state: state)
            actions.selectAgent(.gemini)
            guard state.aiAgentPreference == .automatic, !FileManager.default.fileExists(atPath: url.path),
                  actions.agentEnabled(.automatic), actions.agentEnabled(.codex), !actions.agentEnabled(.gemini) else { return false }
            let settings = SettingsWindowController(state: state); settings.open(section: .general, load: false)
            defer { settings.closeWithoutConfirmation() }
            guard let window = settings.window else { return false }
            window.setContentSize(NSSize(width: 760, height: 1100)); SettingsControlTestSupport.settle(window)
            guard let picker = SettingsControlTestSupport.element(window, id: "settings.ai-agent") as? NSPopUpButton,
                  picker.itemTitles == AIAgent.allCases.map(\.name), picker.item(at: 1)?.isEnabled == false,
                  picker.item(at: 2)?.isEnabled == true,
                  let entry = SettingsControlTestSupport.element(window, id: "settings.ai-entry") as? NSSwitch,
                  let refresh = SettingsControlTestSupport.element(window, id: "settings.ai-detect") as? NSButton else { return false }
            picker.selectItem(at: 2); _ = picker.sendAction(picker.action, to: picker.target)
            entry.state = .off; _ = entry.sendAction(entry.action, to: entry.target)
            guard state.aiAgentPreference == .codex, !state.aiDiagnosisEntry,
                  ConfigStore.load(from: url).config.aiAgent == .codex, !ConfigStore.load(from: url).config.aiDiagnosisEntry else { return false }
            installations.append(AIAgentInstallation(agent: .gemini, location: URL(fileURLWithPath: "/opt/homebrew/bin/gemini")))
            let before = detected; refresh.performClick(nil); SettingsControlTestSupport.settle(window)
            guard detected == before + 1, picker.item(at: 4)?.isEnabled == true else { return false }
            // 损坏配置是负控：保存必须拒绝，控件必须立即恢复，文件不能覆盖。
            try Data("broken".utf8).write(to: url)
            picker.selectItem(at: 4); _ = picker.sendAction(picker.action, to: picker.target)
            guard state.aiAgentPreference == .codex, picker.indexOfSelectedItem == 2, state.aiSettingsError != nil else { return false }
            entry.state = .on; _ = entry.sendAction(entry.action, to: entry.target)
            guard !state.aiDiagnosisEntry, entry.state == .off, try String(contentsOf: url) == "broken" else { return false }
            return SettingsMenu.cleanTerminalMenu(state: state).title == "终端"
        } catch { print("AI 设置控件测试失败：\(error)"); return false }
    }
    static func previews() -> Bool {
        let capture = ProcessInfo.processInfo.environment["MEOWMAC_AI_CAPTURE"] == "1"
        let bitmap = ProcessInfo.processInfo.environment["MEOWMAC_AI_BITMAP"] == "1"
        guard capture || bitmap else { return true }
        let state = PanelPreviewRenderer.syntheticState()
        state.availableCleanTerminals = [.ghostty, .terminal]
        state.aiAgentInstallations = [.init(agent: .codex, location: URL(fileURLWithPath: "/opt/homebrew/bin/codex")),
            .init(agent: .openCode, location: URL(fileURLWithPath: "/example/home/.nvm/versions/node/v22.9.0/bin/opencode")),
            .init(agent: .claudeDesktop, location: URL(fileURLWithPath: "/example/Claude.app")),
            .init(agent: .chatGPT, location: URL(fileURLWithPath: "/example/ChatGPT.app")),
            .init(agent: .deepSeekHarness, location: URL(fileURLWithPath: "/example/Harness.app"))]
        let controller = SettingsWindowController(state: state); controller.open(section: .general, load: false)
        defer { controller.closeWithoutConfirmation() }
        guard let window = controller.window else { return false }
        let root = URL(fileURLWithPath: "build/acceptance/ai-agent-launch/previews")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // 生产设置窗口允许调高。1100 pt 展示完整通用栏，不改变初始 620 pt 和滚动路径。
            window.setContentSize(NSSize(width: 760, height: 1100)); window.setFrameOrigin(NSPoint(x: 80, y: 40))
            for dark in [false, true] {
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); SettingsControlTestSupport.settle(window)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let name = "general-" + (dark ? "dark" : "light")
                if bitmap, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + "-cache.png"))
                }
                if capture { try ConfigPreviewCapture.capture(window, to: root.appendingPathComponent(name + ".png")) }
            }
            print("通用栏预览：生产 SettingsWindow，760 × 1100 pt，浅深色；缓存仅作补充。")
            return true
        } catch { print("通用栏真实窗口截图失败：\(error)"); return false }
    }
}
