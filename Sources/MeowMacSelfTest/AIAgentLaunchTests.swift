import AppKit
import Foundation
import MeowMacCore
import MeowMacSystem
import MeowMacUI

@MainActor
enum AIAgentLaunchTests {
    static func detection() -> Bool {
        let home = "/example/home with spaces"
        let executable = Set([home + "/.local/bin/codex", "/opt/homebrew/bin/codex", home + "/.nvm/versions/node/v22.9.0/bin/opencode", home + "/.nvm/versions/node/v9.0.0/bin/opencode"])
        let detector = AIAgentDetector(home: home, isExecutable: { executable.contains($0) }, nodeVersions: { _ in ["v9.0.0", "v22.10.0", "v22.9.0", "../invalid"] }, findApplication: {
            $0 == "com.openai.chat" ? URL(fileURLWithPath: "/example/ChatGPT.app") : nil
        })
        let results = detector.detect()
        guard results.map(\.agent) == [.codex, .openCode, .chatGPT],
              results[0].location.path == home + "/.local/bin/codex",
              results[1].location.path == home + "/.nvm/versions/node/v22.9.0/bin/opencode",
              results[0].displayDirectory(home: home) == "~/.local/bin" else { return false }
        let root = URL(fileURLWithPath: "build/acceptance/ai-agent-launch/detection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let bin = root.appendingPathComponent(".local/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let file = bin.appendingPathComponent("codex"); try Data("fake".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            // 真文件检查只测试合成 home；其他固定目录在闭包中显式排除。
            let check: (String) -> Bool = { path in
                var directory: ObjCBool = false
                return path.hasPrefix(root.path + "/") && FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                    && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
            }
            let detector = AIAgentDetector(home: root.path, isExecutable: check, nodeVersions: { _ in [] }, findApplication: { _ in nil })
            guard detector.detect().isEmpty else { return false }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            guard detector.detect().map(\.agent) == [.codex] else { return false }
            try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            return detector.detect().isEmpty
        } catch { print("agent 检测测试失败：\(error)"); return false }
    }
    static func controller() -> Bool {
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        var installed = AIAgent.agents.map { AIAgentInstallation(agent: $0, location: URL(fileURLWithPath: "/example/" + $0.name)) }
        var detectionCount = 0, copies: [String] = [], terminals: [String] = [], desktops: [(URL, URL?)] = [], recorded: [AIAgent] = []
        var terminalAvailable = true, finish: ((Error?) -> Void)?
        let controller = AIAgentController(state: state, configURL: URL(fileURLWithPath: "/example/config.json"),
            detect: { detectionCount += 1; return installed }, findTerminal: { terminalAvailable && $0 == .ghostty ? URL(fileURLWithPath: "/example/Ghostty.app") : nil },
            launchTerminal: { _, _, agent, executable, prompt, work, completion in
                terminals.append(AIAgentCommand.script(agent: agent, executable: executable, prompt: prompt, workingDirectory: work, runnerExecutable: "/example/MeowMac", reportPath: "/example/report")); finish = completion },
            launchDesktop: { app, url, completion in desktops.append((app, url)); completion(nil) },
            copy: { copies.append($0) }, prepareDirectory: { _ in }, readLast: { .gemini }, recordSuccess: { recorded.append($0) })
        let preview = controller.preview(prompt: "合成提示词 ' \n第二行")
        guard preview.selected == .gemini, detectionCount == 2, copies.isEmpty, terminals.isEmpty, desktops.isEmpty else { return false }
        controller.copyPrompt(preview); guard copies == [preview.prompt] else { return false }; copies.removeAll()
        for agent in AIAgent.agents {
            preview.selected = agent; controller.launch(preview)
            if agent.executableName != nil {
                guard preview.launching, let script = terminals.last,
                      script.contains(CleaningCommand.quote("/example/" + agent.name)), !script.contains("--yolo"), !script.contains("dangerously-skip") else { return false }
                controller.launch(preview); finish?(nil)
            }
            guard !preview.launching, recorded.last == agent, controller.lastSuccessful == agent else { return false }
            if agent == .claudeDesktop { guard desktops.last?.1 == agent.promptURL(preview.prompt), copies.isEmpty else { return false } }
            if [.qoder, .chatGPT, .deepSeekHarness].contains(agent) { guard copies.last == preview.prompt, preview.message == "已复制，请粘贴" else { return false } }
            copies.removeAll()
        }
        guard terminals.count == 5, desktops.count == 3 else { return false }
        let previous = controller.lastSuccessful; preview.selected = .codex; controller.launch(preview)
        finish?(NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "合成启动错误"]))
        guard preview.message?.contains("合成启动错误") == true, controller.lastSuccessful == previous else { return false }
        let count = terminals.count; terminalAvailable = false; controller.launch(preview)
        guard terminals.count == count, preview.message?.contains("没有可用的终端") == true else { return false }
        state.cleanTerminalPreference = .iterm; controller.launch(preview)
        guard preview.message?.contains("iTerm2") == true else { return false }
        installed = []; controller.launch(preview)
        guard terminals.count == count, preview.message?.contains("未安装或不再可执行") == true else { return false }
        let empty = controller.preview(prompt: "empty")
        return empty.selected == nil && empty.installations.isEmpty && copies.isEmpty
    }
    static func completionAfterClose() -> Bool {
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        var finish: ((Error?) -> Void)?, recorded: [AIAgent] = []
        let controller = AIAgentController(state: state,
            detect: { [.init(agent: .codex, location: URL(fileURLWithPath: "/example/codex"))] },
            findTerminal: { $0 == .ghostty ? URL(fileURLWithPath: "/example/Ghostty.app") : nil },
            launchTerminal: { _, _, _, _, _, _, completion in finish = completion }, prepareDirectory: { _ in },
            readLast: { nil }, recordSuccess: { recorded.append($0) })
        var session: AIDiagnosisSession? = controller.preview(prompt: "合成提示词")
        weak var weakSession = session
        controller.launch(session!); session = nil
        guard weakSession == nil else { return false }
        finish?(nil)
        return controller.lastSuccessful == .codex && recorded == [.codex]
    }
    static func shell() -> Bool {
        let root = URL(fileURLWithPath: "build/acceptance/ai-agent-launch/shell-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let work = root.appendingPathComponent("work ' dir"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("agent ' $(touch injected) `touch injected2`")
            let marker = root.appendingPathComponent("arguments.txt")
            let fake = "#!/bin/sh\nprintf '%s\\0' \"$PWD\" \"$PATH\" \"$@\" > " + CleaningCommand.quote(marker.path) + "\nexit 7\n"
            try Data(fake.utf8).write(to: executable); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let prompt = "合成 ' \" \n$(touch injected) `touch injected2`"
            for agent in [AIAgent.claudeCode, .codex, .openCode, .gemini, .qoder] {
                let script = root.appendingPathComponent("agent.command")
                try Data(AIAgentCommand.script(agent: agent, executable: executable.path, prompt: prompt, workingDirectory: work.path, runnerExecutable: Bundle.main.executableURL!.path, reportPath: root.appendingPathComponent("result.json").path).utf8).write(to: script)
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = [script.path]
                process.environment = ["PATH": "/usr/bin:/bin"]
                let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = output
                try process.run(); try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8)); try input.fileHandleForWriting.close()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); process.waitUntilExit()
                let fields = try Data(contentsOf: marker).split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
                guard process.terminationStatus == 7, Array(fields.dropFirst(2)) == agent.arguments(prompt: prompt),
                      fields.first == work.path, fields[1].hasPrefix(root.path + ":"),
                      try JSONDecoder().decode(AIAgentLaunchReport.self, from: Data(contentsOf: root.appendingPathComponent("result.json"))).pid != nil,
                      text.contains("状态 7"), !FileManager.default.fileExists(atPath: script.path),
                      !FileManager.default.fileExists(atPath: work.appendingPathComponent("injected").path),
                      !FileManager.default.fileExists(atPath: work.appendingPathComponent("injected2").path) else { return false }
            }
            return true
        } catch { print("agent shell 测试失败：\(error)"); return false }
    }
    static func liveGhostty() async -> Bool {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else { return false }
        let root = URL(fileURLWithPath: "build/acceptance/ai-agent-launch/live-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("fake agent '")
            let marker = root.appendingPathComponent("argument.txt")
            let work = root.appendingPathComponent("work"); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let prompt = "合成诊断 ' \" 空格\n$(echo literal) `echo literal`"
            try Data(("#!/bin/sh\nprintf '%s' \"$1\" > " + CleaningCommand.quote(marker.path) + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let error: Error? = await withCheckedContinuation { continuation in
                AIAgentTerminalLauncher.launch(terminal: .ghostty, application: application, agent: .codex,
                    executable: executable.path, prompt: prompt, workingDirectory: work.path, reportRoot: root,
                    openTerminal: { TerminalScriptLauncher.launch(terminal: $0, application: $1, script: $2, scriptPrefix: "agent-test", completion: $3) },
                    completion: { continuation.resume(returning: $0) })
            }
            guard error == nil else { print("假 agent 启动错误：\(String(describing: error))"); return false }
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(nanoseconds: 100_000_000) }
            guard try String(contentsOf: marker) == prompt else { return false }
            // 用户窗口等待回车，不结束进程；假工具已退出，删除已用的合成可执行文件。
            try FileManager.default.removeItem(at: executable)
            print("Ghostty 假 agent 收到完整提示词；未启动真实 agent。窗口等待回车。")
            return true
        } catch { print("假 agent 实机测试失败：\(error)"); return false }
    }
}
