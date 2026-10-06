import AppKit
import MeowMacCore
import MeowMacSystem
import os

@MainActor
public enum AIAgentTerminalLauncher {
    /// 命令行入口在 AppKit 启动前处理，避免唤起第二个菜单栏实例。
    public static func handleCommandLine(_ arguments: [String]) -> Int32? { AIAgentProcessRunner.handle(arguments) }

    public static func launch(terminal: CleanTerminal, application: URL, agent: AIAgent, executable: String,
                              prompt: String, workingDirectory: String, completion: @escaping (Error?) -> Void) {
        launch(terminal: terminal, application: application, agent: agent, executable: executable, prompt: prompt,
               workingDirectory: workingDirectory,
               reportRoot: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MeowMac/tmp"),
               openTerminal: { TerminalScriptLauncher.launch(terminal: $0, application: $1, script: $2, scriptPrefix: "agent", completion: $3) },
               completion: completion)
    }

    /// 测试可替换终端打开动作；确认仍读取真实子进程的报告。
    public static func launch(terminal: CleanTerminal, application: URL, agent: AIAgent, executable: String,
                              prompt: String, workingDirectory: String, reportRoot: URL, timeoutSeconds: Double = 30,
                              openTerminal: @escaping CleaningController.Launcher, completion: @escaping (Error?) -> Void) {
        let directory = reportRoot.appendingPathComponent("agent-launch-" + UUID().uuidString)
        let report = directory.appendingPathComponent("result.json")
        func cleanup() {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Logger(subsystem: AppIdentity.bundleID, category: "ai-agent").error("启动报告清理失败：\(error.localizedDescription, privacy: .private)") }
        }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { completion(error); return }
        guard let mainExecutable = Bundle.main.executableURL else { cleanup(); completion(failure("无法定位 MeowMac 启动程序。")); return }
        // 应用内的辅助程序使用独立进程名，安装时不会被当作尚未退出的主应用。
        let runner = Bundle.main.bundleURL.pathExtension == "app"
            ? mainExecutable.deletingLastPathComponent().appendingPathComponent("MeowMacAgentRunner").path : mainExecutable.path
        let script = AIAgentCommand.script(agent: agent, executable: executable, prompt: prompt, workingDirectory: workingDirectory,
                                          runnerExecutable: runner, reportPath: report.path)
        openTerminal(terminal, application, script) { error in
            if let error { cleanup(); completion(error); return }
            // 终端的回调不证明 CLI 已执行。窗口关闭也不取消已发出的启动确认。
            Task { @MainActor in
                defer { cleanup() }
                let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
                do {
                    repeat {
                        if FileManager.default.fileExists(atPath: report.path) {
                            let result = try JSONDecoder().decode(AIAgentLaunchReport.self, from: Data(contentsOf: report))
                            if let reason = result.error { completion(failure(reason)) }
                            else if let pid = result.pid, pid > 0 { completion(nil) }
                            else { completion(failure("agent 启动报告无效。")) }
                            return
                        }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    } while ProcessInfo.processInfo.systemUptime < deadline
                    completion(failure("等待 agent 启动结果超时，未更新上次成功记录。请查看终端错误，或复制提示词。"))
                } catch { completion(error) }
            }
        }
    }
    private static func failure(_ reason: String) -> Error { NSError(domain: "MeowMac.AIAgentLaunch", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
}
