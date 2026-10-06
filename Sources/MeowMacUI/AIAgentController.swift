import AppKit
import SwiftUI
import MeowMacCore
import MeowMacSystem
import os

@MainActor
public final class AIDiagnosisSession: ObservableObject {
    public let prompt: String
    public let installations: [AIAgentInstallation]
    @Published public var selected: AIAgent?
    @Published public var launching = false
    @Published public var message: String?
    public init(prompt: String, installations: [AIAgentInstallation], preference: AIAgent, lastSuccessful: AIAgent?) {
        self.prompt = prompt; self.installations = installations
        selected = preference.resolved(available: Set(installations.map(\.agent)), lastSuccessful: lastSuccessful)
    }
}

/// 外部动作全部可注入。预览只检测，复制和启动分别由用户动作触发。
@MainActor
public final class AIAgentController {
    public typealias TerminalLauncher = CleaningController.Launcher
    public typealias DesktopLauncher = (URL, URL?, @escaping (Error?) -> Void) -> Void
    private let state: PanelState
    private let configURL: URL
    private let detect: () -> [AIAgentInstallation]
    private let findTerminal: (CleanTerminal) -> URL?
    private let launchTerminal: TerminalLauncher
    private let launchDesktop: DesktopLauncher
    private let copy: (String) -> Void
    private let workingDirectory: URL
    private let prepareDirectory: (URL) throws -> Void
    private let recordSuccess: (AIAgent) throws -> Void
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "ai-agent")
    public private(set) var lastSuccessful: AIAgent?

    public init(state: PanelState, configURL: URL = ConfigStore.defaultURL,
                detect: (() -> [AIAgentInstallation])? = nil,
                findTerminal: @escaping (CleanTerminal) -> URL? = { $0.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } },
                launchTerminal: TerminalLauncher? = nil, launchDesktop: DesktopLauncher? = nil,
                copy: @escaping (String) -> Void = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) },
                workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MeowMac/agent"),
                prepareDirectory: @escaping (URL) throws -> Void = {
                    try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                }, readLast: (() throws -> AIAgent?)? = nil, recordSuccess: ((AIAgent) throws -> Void)? = nil) {
        self.state = state; self.configURL = configURL
        self.detect = detect ?? { AIAgentDetector(findApplication: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).detect() }
        self.findTerminal = findTerminal
        self.launchTerminal = launchTerminal ?? { TerminalScriptLauncher.launch(terminal: $0, application: $1, script: $2, scriptPrefix: "agent", completion: $3) }
        self.launchDesktop = launchDesktop ?? { application, url, completion in
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            let finished: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in Task { @MainActor in completion(error) } }
            if let url { NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration, completionHandler: finished) }
            else { NSWorkspace.shared.openApplication(at: application, configuration: configuration, completionHandler: finished) }
        }
        self.copy = copy; self.workingDirectory = workingDirectory; self.prepareDirectory = prepareDirectory
        let historyURL = configURL.deletingLastPathComponent().appendingPathComponent("last-ai-agent.json")
        self.recordSuccess = recordSuccess ?? { agent in
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(agent).write(to: historyURL, options: .atomic)
        }
        do {
            if let readLast { lastSuccessful = try readLast() }
            else if FileManager.default.fileExists(atPath: historyURL.path) {
                lastSuccessful = try JSONDecoder().decode(AIAgent.self, from: Data(contentsOf: historyURL))
            }
        } catch { logger.error("上次 agent 记录读取失败：\(error.localizedDescription, privacy: .private)") }
        refresh()
    }
    public func refresh() { state.aiAgentInstallations = detect() }
    public func preview(prompt: String) -> AIDiagnosisSession {
        refresh()
        return AIDiagnosisSession(prompt: prompt, installations: state.aiAgentInstallations, preference: state.aiAgentPreference, lastSuccessful: lastSuccessful)
    }
    public func select(_ agent: AIAgent) {
        do { try ConfigStore.saveAIAgent(agent, to: configURL); state.aiAgentPreference = agent; state.aiSettingsError = nil }
        catch { settingsFailure(error) }
    }
    public func setEntry(_ enabled: Bool) {
        do { try ConfigStore.saveAIDiagnosisEntry(enabled, to: configURL); state.aiDiagnosisEntry = enabled; state.aiSettingsError = nil }
        catch { settingsFailure(error) }
    }
    private func settingsFailure(_ error: Error) {
        state.aiSettingsError = "AI 诊断设置未保存：" + error.localizedDescription
        logger.error("AI 诊断设置保存失败：\(error.localizedDescription, privacy: .private)")
    }
    public func copyPrompt(_ session: AIDiagnosisSession) { copy(session.prompt); session.message = "已复制提示词" }
    public func launch(_ session: AIDiagnosisSession) {
        guard !session.launching, let agent = session.selected else { return }
        refresh()
        guard let installed = state.aiAgentInstallations.first(where: { $0.agent == agent }) else {
            fail(session, "所选 agent 未安装或不再可执行。请重新打开预览，或复制提示词。"); return
        }
        let completion: (Error?) -> Void = { [weak self, weak session] error in
            guard let self else { return }
            session?.launching = false
            if let error {
                if let session { self.fail(session, error.localizedDescription) }
                else { self.logger.error("agent 启动失败：\(error.localizedDescription, privacy: .private)") }
                return
            }
            // 窗口关闭不取消已发出的启动；成功历史独立于预览会话的寿命。
            self.lastSuccessful = agent
            session?.message = [.qoder, .chatGPT, .deepSeekHarness].contains(agent) ? "已复制，请粘贴" : "已打开 " + agent.name
            do { try self.recordSuccess(agent) }
            catch {
                if let session { session.message = (session.message ?? "") + "；上次 agent 记录未保存" }
                self.logger.error("上次 agent 记录保存失败：\(error.localizedDescription, privacy: .private)")
            }
        }
        if agent.executableName != nil {
            let available = Set(CleanTerminal.allCases.filter { $0 != .automatic && findTerminal($0) != nil })
            state.availableCleanTerminals = available
            guard let terminal = state.cleanTerminalPreference.resolved(available: available), let application = findTerminal(terminal) else {
                fail(session, state.cleanTerminalPreference == .automatic ? "没有可用的终端。请到设置 › 通用选择终端，或复制提示词。" : "未找到已安装的 " + state.cleanTerminalPreference.name + "。请到设置 › 通用选择终端，或复制提示词。"); return
            }
            do { try prepareDirectory(workingDirectory) }
            catch { fail(session, "无法准备排查工作目录：" + error.localizedDescription); return }
            if agent == .qoder { copy(session.prompt) }
            session.launching = true; session.message = nil
            launchTerminal(terminal, application, AIAgentCommand.script(agent: agent, executable: installed.location.path, prompt: session.prompt, workingDirectory: workingDirectory.path), completion)
        } else {
            if [.chatGPT, .deepSeekHarness].contains(agent) { copy(session.prompt) }
            session.launching = true; session.message = nil
            launchDesktop(installed.location, agent.promptURL(session.prompt), completion)
        }
    }
    private func fail(_ session: AIDiagnosisSession, _ reason: String) {
        session.launching = false; session.message = "启动未确认成功：" + reason + " 可用“复制提示词”手动排查。"
        logger.error("agent 启动失败：\(reason, privacy: .private)")
    }
}
