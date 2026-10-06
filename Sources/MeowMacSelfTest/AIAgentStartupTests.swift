import AppKit
import Foundation
import MeowMacCore
import MeowMacSystem
import MeowMacUI

@MainActor
enum AIAgentStartupTests {
    static func failures() async -> Bool {
        let root = URL(fileURLWithPath: "build/acceptance/ai-agent-launch/r1-failures-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("fake agent '")
            for (index, reason) in ["无法进入", "不再可执行", "不再可执行", "解释器不可用", "解释器不可用", "解释器不可用"].enumerated() {
                if FileManager.default.fileExists(atPath: executable.path) { try FileManager.default.removeItem(at: executable) }
                if index != 1 {
                    let contents = index == 3 ? "#!/missing/synthetic-interpreter\n" : index == 4 ? "invalid executable"
                        : index == 5 ? "#!/usr/bin/env missing-synthetic-interpreter\n" : "#!/bin/sh\nexit 0\n"
                    try Data(contents.utf8).write(to: executable)
                    try FileManager.default.setAttributes([.posixPermissions: index == 2 ? 0o600 : 0o700], ofItemAtPath: executable.path)
                }
                var processes: [Process] = [], recorded: [AIAgent] = [], copies: [String] = []
                let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
                let controller = AIAgentController(state: state,
                    detect: { [.init(agent: .codex, location: executable)] },
                    findTerminal: { $0 == .ghostty ? URL(fileURLWithPath: "/example/Ghostty.app") : nil },
                    launchTerminal: { terminal, app, agent, executable, prompt, work, finish in
                        AIAgentTerminalLauncher.launch(terminal: terminal, application: app, agent: agent, executable: executable,
                            prompt: prompt, workingDirectory: work, reportRoot: root, timeoutSeconds: 2,
                            openTerminal: { _, _, script, opened in
                                do { processes.append(try open(script: script, root: root)); opened(nil) }
                                catch { opened(error) }
                            }, completion: finish)
                    }, copy: { copies.append($0) }, workingDirectory: index == 0 ? root.appendingPathComponent("missing") : root,
                    prepareDirectory: { _ in }, readLast: { .openCode }, recordSuccess: { recorded.append($0) })
                let preview = AIDiagnosisWindowController(controller: controller)
                preview.open(prompt: "合成提示词 ' \n第二行")
                guard let window = preview.window, let session = preview.session else { return false }
                SettingsControlTestSupport.settle(window)
                guard let launch = SettingsControlTestSupport.element(window, id: "ai-preview.launch") as? NSButton else { return false }
                launch.performClick(nil)
                // 此时终端已返回成功，CLI 尚未确认，旧记录必须保留。
                guard session.launching, controller.lastSuccessful == .openCode, recorded.isEmpty else { return false }
                for _ in 0..<60 where session.launching { try await Task.sleep(nanoseconds: 50_000_000) }
                processes.forEach { $0.waitUntilExit() }
                SettingsControlTestSupport.settle(window)
                guard !session.launching, controller.lastSuccessful == .openCode, recorded.isEmpty,
                      session.message?.contains(reason) == true, session.message?.contains("复制提示词") == true,
                      let copy = SettingsControlTestSupport.element(window, id: "ai-preview.copy") as? NSButton, copy.isEnabled else {
                    print("CLI 失败反馈不符：场景 \(index)，\(session.message ?? "无反馈")"); preview.close(); return false
                }
                copy.performClick(nil)
                guard copies == [session.prompt] else { preview.close(); return false }
                preview.close()
                guard try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy({ !$0.hasPrefix("agent-launch-") }) else { return false }
            }
            return true
        } catch { print("CLI 启动失败测试出错：\(error)"); return false }
    }

    static func success() async -> Bool {
        let root = URL(fileURLWithPath: "build/acceptance/ai-agent-launch/r1-success-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("fake agent"), marker = root.appendingPathComponent("input.txt")
            let ready = root.appendingPathComponent("input-ready")
            // 在已启动和退出之间留出窗口，验证确认不等待会话结束，标准输入仍可读。
            let script = "#!/usr/bin/env sh\n[ -t 0 ] && [ -t 1 ] || exit 23\n: > " + CleaningCommand.quote(ready.path)
                + "\nread -r value\nprintf '%s' \"$value\" > " + CleaningCommand.quote(marker.path) + "\n/bin/sleep 1\nexit 7\n"
            try Data(script.utf8).write(to: executable); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            var processes: [Process] = [], recorded: [AIAgent] = []
            let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
            let controller = AIAgentController(state: state,
                detect: { [.init(agent: .codex, location: executable)] },
                findTerminal: { $0 == .ghostty ? URL(fileURLWithPath: "/example/Ghostty.app") : nil },
                launchTerminal: { terminal, app, agent, executable, prompt, work, finish in
                    AIAgentTerminalLauncher.launch(terminal: terminal, application: app, agent: agent, executable: executable,
                        prompt: prompt, workingDirectory: work, reportRoot: root,
                        openTerminal: { _, _, script, opened in
                            do { processes.append(try open(script: script, root: root, input: "合成输入\n\n", inputReady: ready, inputConsumed: marker)); opened(nil) }
                            catch { opened(error) }
                        }, completion: finish)
                }, workingDirectory: root, prepareDirectory: { _ in }, readLast: { .openCode }, recordSuccess: { recorded.append($0) })
            var session: AIDiagnosisSession? = controller.preview(prompt: "合成提示词")
            weak var released = session
            controller.launch(session!)
            guard controller.lastSuccessful == .openCode, recorded.isEmpty else { return false }
            session = nil
            guard released == nil else { return false }
            for _ in 0..<60 where recorded.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
            let confirmedWhileRunning = processes.first?.isRunning == true
            for _ in 0..<60 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(nanoseconds: 50_000_000) }
            processes.forEach { $0.waitUntilExit() }
            let input = try String(contentsOf: marker)
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            print("CLI 伪终端：确认时仍运行=\(confirmedWhileRunning)，记录=\(recorded)，退出=\(processes.first?.terminationStatus ?? -1)，输入=\(input)")
            if input.isEmpty { print("伪终端输出：" + (try String(contentsOf: root.appendingPathComponent("terminal.txt")))) }
            return confirmedWhileRunning && controller.lastSuccessful == .codex && recorded == [.codex]
                && processes.first?.terminationStatus == 7 && input == "合成输入"
                && files.allSatisfy { !$0.hasPrefix("agent-launch-") }
        } catch { print("CLI 启动成功测试出错：\(error)"); return false }
    }

    static func timeout() async -> Bool {
        let root = URL(fileURLWithPath: "build/acceptance/ai-agent-launch/r1-timeout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let error: Error? = await withCheckedContinuation { continuation in
            AIAgentTerminalLauncher.launch(terminal: .ghostty, application: URL(fileURLWithPath: "/example/Ghostty.app"), agent: .codex,
                executable: "/example/codex", prompt: "合成提示词", workingDirectory: root.path, reportRoot: root, timeoutSeconds: 0.1,
                openTerminal: { _, _, _, opened in opened(nil) }, completion: { continuation.resume(returning: $0) })
        }
        return error?.localizedDescription.contains("超时") == true
            && (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true
    }

    private static func open(script: String, root: URL, input: String = "\n", inputReady: URL? = nil, inputConsumed: URL? = nil) throws -> Process {
        let file = root.appendingPathComponent(UUID().uuidString + ".command")
        try Data(script.utf8).write(to: file)
        let process = Process(); process.executableURL = URL(fileURLWithPath: inputReady != nil ? "/usr/bin/script" : "/bin/sh")
        process.arguments = inputReady != nil ? ["-q", "-e", "/dev/null", "/bin/sh", file.path] : [file.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe(); process.standardInput = pipe; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        if inputReady != nil {
            let output = root.appendingPathComponent("terminal.txt"); try Data().write(to: output)
            process.standardOutput = try FileHandle(forWritingTo: output); process.standardError = process.standardOutput
        }
        try process.run()
        if let inputReady {
            // 伪终端初始化会清空早到的输入，等合成 CLI 确认可读后再送用户输入。
            Task { @MainActor in
                do {
                    for _ in 0..<100 where !FileManager.default.fileExists(atPath: inputReady.path) { try await Task.sleep(nanoseconds: 20_000_000) }
                    try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    if let inputConsumed {
                        for _ in 0..<100 where !FileManager.default.fileExists(atPath: inputConsumed.path) { try await Task.sleep(nanoseconds: 20_000_000) }
                    }
                    try pipe.fileHandleForWriting.close()
                } catch { print("伪终端输入失败：\(error)") }
            }
        } else { try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try pipe.fileHandleForWriting.close() }
        return process
    }
}
