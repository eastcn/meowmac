import AppKit
import MeowMacCore
import MeowMacSystem

@MainActor
public enum CleaningAlerts {
    public static func missingMole() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "未找到 Mole"
        alert.informativeText = "清理需要 Mole。安装后可重试；已经安装在其他位置时，可修改配置中的 moPath。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "打开配置文件…")
        alert.addButton(withTitle: "安装说明")
        return alert
    }

    public static func launchFailed(terminal: CleanTerminal, command: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = terminal == .automatic ? "没有可用的终端" : "无法打开 " + terminal.name
        alert.informativeText = "清理命令尚未确认启动。你可以更换终端，或复制命令手动运行。\n\n" + command
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "复制命令")
        alert.addButton(withTitle: "选择终端…")
        return alert
    }
}

@MainActor
public enum CleanTerminalLauncher {
    public static func configuration(terminal: CleanTerminal, script: URL) -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if terminal == .ghostty {
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["-e", "/bin/sh", script.path]
        }
        return configuration
    }

    public static func launch(terminal: CleanTerminal, application: URL, script: String,
                              completion: @escaping (Error?) -> Void) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeowMac/tmp", isDirectory: true)
        let file = directory.appendingPathComponent("clean-" + UUID().uuidString + ".command")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch { completion(error); return }
        let configuration = configuration(terminal: terminal, script: file)
        let finished: (NSRunningApplication?, Error?) -> Void = { _, error in
            Task { @MainActor in
                // 成功后由脚本退出时删除自己；启动失败只删除本次生成的脚本。
                if error != nil { try? FileManager.default.removeItem(at: file) }
                completion(error)
            }
        }
        if terminal == .ghostty {
            NSWorkspace.shared.openApplication(at: application, configuration: configuration, completionHandler: finished)
        } else {
            NSWorkspace.shared.open([file], withApplicationAt: application, configuration: configuration, completionHandler: finished)
        }
    }
}

/// UI 协调层负责检查、保存和反馈；离线验证可替换外部启动与提示框。
@MainActor
public final class CleaningController {
    public typealias Launcher = (CleanTerminal, URL, String, @escaping (Error?) -> Void) -> Void
    private let state: PanelState
    private let configURL: URL
    private let findApplication: (CleanTerminal) -> URL?
    private let resolveExecutable: (String) -> String?
    private let launch: Launcher
    private let present: (NSAlert) -> NSApplication.ModalResponse
    private let openConfig: () -> Void
    private let openInstructions: () -> Void
    private let copyCommand: (String) -> Void
    private let chooseTerminal: () -> Void
    private let now: () -> Date
    private var launching = false
    private var nextLaunchAt = Date.distantPast

    public init(state: PanelState, configURL: URL = ConfigStore.defaultURL,
                findApplication: @escaping (CleanTerminal) -> URL? = { terminal in
                    terminal.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                }, resolveExecutable: @escaping (String) -> String? = { MoExecutable.resolve(configuredPath: $0) },
                launch: Launcher? = nil,
                present: @escaping (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() },
                openConfig: @escaping () -> Void,
                openInstructions: @escaping () -> Void = { NSWorkspace.shared.open(URL(string: "https://github.com/tw93/Mole")!) },
                copyCommand: @escaping (String) -> Void = {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string)
                }, chooseTerminal: @escaping () -> Void = {}, now: @escaping () -> Date = Date.init) {
        self.state = state; self.configURL = configURL; self.findApplication = findApplication
        self.resolveExecutable = resolveExecutable
        self.launch = launch ?? { CleanTerminalLauncher.launch(terminal: $0, application: $1, script: $2, completion: $3) }
        self.present = present
        self.openConfig = openConfig; self.openInstructions = openInstructions
        self.copyCommand = copyCommand; self.chooseTerminal = chooseTerminal; self.now = now
        refreshTerminals()
    }

    public func refreshTerminals() {
        state.availableCleanTerminals = Set(CleanTerminal.allCases.filter { $0 != .automatic && findApplication($0) != nil })
    }

    public func select(_ preference: CleanTerminal) {
        do {
            try ConfigStore.saveCleanTerminal(preference, to: configURL)
            state.cleanTerminalPreference = preference
        } catch {
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "清理终端未保存"
            alert.informativeText = "配置文件无法写入。请检查配置文件，原来的终端选择仍然有效。"
            alert.addButton(withTitle: "好")
            _ = present(alert)
        }
    }

    public func clean() {
        guard !launching, now() >= nextLaunchAt else { return }
        let loaded = ConfigStore.load(from: configURL)
        guard loaded.error == nil else {
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "无法读取清理配置"
            alert.informativeText = "请检查配置文件后重试。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "打开配置文件…")
            if present(alert) == .alertSecondButtonReturn { openConfig() }
            return
        }
        state.cleanTerminalPreference = loaded.config.cleanTerminal
        guard let executable = resolveExecutable(loaded.config.moPath) else {
            state.cleaningHistoryMessage = "未找到 Mole · 清理需要先安装"
            switch present(CleaningAlerts.missingMole()) {
            case .alertSecondButtonReturn: openConfig()
            case .alertThirdButtonReturn: openInstructions()
            default: break
            }
            return
        }
        refreshTerminals()
        let preference = state.cleanTerminalPreference
        let command = CleaningCommand.command(executable: executable)
        guard let terminal = preference.resolved(available: state.availableCleanTerminals),
              let application = findApplication(terminal) else {
            reportFailure(terminal: preference, command: command)
            return
        }
        state.cleaningHistoryMessage = nil
        launching = true; state.cleanLaunching = true
        nextLaunchAt = now().addingTimeInterval(2)
        launch(terminal, application, CleaningCommand.script(executable: executable)) { [weak self] error in
            guard let self else { return }
            self.launching = false; self.state.cleanLaunching = false
            if error != nil { self.reportFailure(terminal: terminal, command: command) }
        }
    }

    private func reportFailure(terminal: CleanTerminal, command: String) {
        switch present(CleaningAlerts.launchFailed(terminal: terminal, command: command)) {
        case .alertSecondButtonReturn: copyCommand(command)
        case .alertThirdButtonReturn: chooseTerminal()
        default: break
        }
    }
}
