import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum CleanTerminalTests {
    private static func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func preferences() -> Bool {
        do {
            let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("config.json")
            let data = Data(#"{"schemaVersion":1,"moPath":"/example/mo","quotaRefreshSeconds":2468,"future":{"keep":true}}"#.utf8)
            try data.write(to: file)
            guard ConfigStore.load(from: file).config.cleanTerminal == .automatic else { return false }
            try ConfigStore.saveCleanTerminal(.ghostty, to: file)
            let reloaded = ConfigStore.load(from: file)
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            guard reloaded.error == nil, reloaded.config.cleanTerminal == .ghostty,
                  reloaded.config.moPath == "/example/mo", reloaded.config.quotaRefreshSeconds == 2468,
                  (raw?["future"] as? [String: Bool])?["keep"] == true else { return false }
            let bad = directory.appendingPathComponent("bad.json")
            try Data("broken".utf8).write(to: bad)
            do { try ConfigStore.saveCleanTerminal(.iterm, to: bad); return false } catch {}
            guard try Data(contentsOf: bad) == Data("broken".utf8) else { return false }
            let blocked = directory.appendingPathComponent("blocked"); try Data().write(to: blocked)
            var alerts = 0
            let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
            let controller = CleaningController(state: state, configURL: blocked.appendingPathComponent("config.json"),
                findApplication: { _ in nil }, present: { _ in alerts += 1; return .alertFirstButtonReturn }, openConfig: {})
            controller.select(.ghostty)
            return state.cleanTerminalPreference == .automatic && alerts == 1
                && CleanTerminal.automatic.resolved(available: [.ghostty, .iterm, .terminal]) == .ghostty
                && CleanTerminal.automatic.resolved(available: [.iterm, .terminal]) == .iterm
                && CleanTerminal.automatic.resolved(available: [.terminal]) == .terminal
                && CleanTerminal.ghostty.resolved(available: [.terminal]) == nil
                && CleanTerminal.automatic.resolved(available: []) == nil
        } catch { print("清理终端配置测试失败：\(error)"); return false }
    }

    static func script() -> Bool {
        do {
            let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
            // 文件名里的引号、空格、替换语法必须作为文字传给 shell。
            let executable = directory.appendingPathComponent("mo ' $(touch injected) `touch injected2`")
            let marker = directory.appendingPathComponent("arguments.txt")
            let fake = "#!/bin/sh\nprintf '%s' \"$1\" > " + CleaningCommand.quote(marker.path) + "\nexit 7\n"
            try Data(fake.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let script = directory.appendingPathComponent("clean.command")
            try Data(CleaningCommand.script(executable: executable.path).utf8).write(to: script)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]; process.currentDirectoryURL = directory
            let input = Pipe(); let output = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run(); try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8)); try input.fileHandleForWriting.close()
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            guard process.terminationStatus == 7, try String(contentsOf: marker) == "clean",
                  text.contains("状态 7"), text.contains("按回车关闭窗口"), !FileManager.default.fileExists(atPath: script.path),
                  !FileManager.default.fileExists(atPath: directory.appendingPathComponent("injected").path),
                  !FileManager.default.fileExists(atPath: directory.appendingPathComponent("injected2").path) else { return false }
            let config = CleanTerminalLauncher.configuration(terminal: .ghostty, script: script)
            return config.createsNewApplicationInstance && config.arguments == ["-e", "/bin/sh", script.path]
                && !CleanTerminalLauncher.configuration(terminal: .terminal, script: script).createsNewApplicationInstance
        } catch { print("清理命令转义测试失败：\(error)"); return false }
    }

    static func controller() -> Bool {
        do {
            let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("config.json")
            var config = LocalConfig(); config.moPath = "/example/custom/mo"
            try JSONEncoder().encode(config).write(to: file)
            let state = PanelState(configResult: ConfigLoadResult(config: config, error: nil))
            var found = false; var available: Set<CleanTerminal> = [.ghostty, .iterm, .terminal]
            var alerts: [String] = []; var response = NSApplication.ModalResponse.alertFirstButtonReturn
            var openedConfig = 0; var instructions = 0; var chosen = 0; var copied = ""
            var launches: [CleanTerminal] = []; var launchedScript = ""
            var finish: ((Error?) -> Void)?; var clock = Date(timeIntervalSince1970: 1234)
            let controller = CleaningController(state: state, configURL: file,
                findApplication: { available.contains($0) ? URL(fileURLWithPath: "/example/" + $0.name + ".app") : nil },
                resolveExecutable: { found && $0 == config.moPath ? $0 : nil },
                launch: { terminal, _, script, completion in launches.append(terminal); launchedScript = script; finish = completion },
                present: { alerts.append($0.messageText); return response },
                openConfig: { openedConfig += 1 }, openInstructions: { instructions += 1 },
                copyCommand: { copied = $0 }, chooseTerminal: { chosen += 1 }, now: { clock })
            response = .alertSecondButtonReturn; controller.clean()
            response = .alertThirdButtonReturn; controller.clean()
            guard launches.isEmpty, openedConfig == 1, instructions == 1, alerts == ["未找到 Mole", "未找到 Mole"] else { return false }
            found = true; response = .alertFirstButtonReturn
            controller.clean(); controller.clean()
            guard launches == [.ghostty], state.cleanLaunching, launchedScript.contains("'/example/custom/mo' clean") else { return false }
            finish?(nil); controller.clean()
            guard launches.count == 1, !state.cleanLaunching else { return false }
            clock = clock.addingTimeInterval(3); response = .alertSecondButtonReturn; controller.clean()
            finish?(CocoaError(.fileReadUnknown))
            guard launches == [.ghostty, .ghostty], copied == "'/example/custom/mo' clean", alerts.last == "无法打开 Ghostty" else { return false }
            controller.select(.ghostty); available = [.terminal]; clock = clock.addingTimeInterval(3)
            response = .alertThirdButtonReturn; controller.clean()
            guard launches.count == 2, chosen == 1, state.cleanTerminalPreference == .ghostty else { return false }
            // 选择只保存，不立即重试；下一次清理才执行。
            controller.select(.terminal)
            guard launches.count == 2, ConfigStore.load(from: file).config.cleanTerminal == .terminal else { return false }
            controller.clean(); finish?(nil)
            try Data("broken".utf8).write(to: file); clock = clock.addingTimeInterval(3); controller.clean()
            return launches == [.ghostty, .ghostty, .terminal] && alerts.last == "无法读取清理配置"
        } catch { print("清理控制器测试失败：\(error)"); return false }
    }

    static func menu() -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        state.availableCleanTerminals = [.ghostty, .terminal]
        var selected: CleanTerminal?
        state.onSelectCleanTerminal = { selected = $0 }
        let settings = SettingsMenu.make(state: state)
        guard let menu = settings.items.first(where: { $0.title == "清理终端" })?.submenu,
              menu.items.map(\.title) == ["自动（当前：Ghostty）", "", "Ghostty", "iTerm2", "系统终端"],
              menu.items[0].state == .on, !menu.items[3].isEnabled, menu.items[2].isEnabled else { return false }
        menu.performActionForItem(at: 2)
        return selected == .ghostty && CleaningAlerts.missingMole().buttons.map(\.title) == ["取消", "打开配置文件…", "安装说明"]
            && CleaningAlerts.launchFailed(terminal: .ghostty, command: "'/example/mo' clean").buttons.map(\.title) == ["取消", "复制命令", "选择终端…"]
    }

    static func nativeLayout() async -> Bool {
        let path = ProcessInfo.processInfo.environment["MEOWMAC_CLEAN_RENDER_DIR"]
        do {
            if let path { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
            for dark in [false, true] {
                let state = PanelPreviewRenderer.syntheticState()
                state.cleaningHistoryMessage = "未找到 Mole · 清理需要先安装"
                var missingAlerts = 0
                let controller = CleaningController(state: state,
                    configURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"),
                    findApplication: { _ in nil }, resolveExecutable: { _ in nil },
                    present: { _ in missingAlerts += 1; return .alertFirstButtonReturn }, openConfig: {})
                state.onClean = { controller.clean() }
                let hosting = PanelHosting.make(state: state)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentViewController = hosting.controller; window.makeKeyAndOrderFront(nil)
                defer { window.contentViewController = nil; window.close() }
                let size = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                guard size.width == 360, size.height <= 820,
                      let diskBottom = hosting.measurements.cardBottoms["system.disk"] else { return false }
                // SwiftUI 玻璃按钮不出现在本进程的辅助功能树里。按真实测量的磁盘底边定位第一行，分发鼠标事件。
                let point = NSPoint(x: 315, y: size.height - (hosting.measurements.headerHeight + diskBottom - 61))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
                    window.sendEvent(event)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                guard missingAlerts == 1 else { print("清理按钮未触发，位置：\(point)，底边：\(diskBottom)"); return false }
                if let path {
                    try capture(hosting.controller.view, at: URL(fileURLWithPath: path).appendingPathComponent("missing-system-" + (dark ? "dark" : "light") + ".png"))
                    for (name, alert) in [("missing", CleaningAlerts.missingMole()), ("failure", CleaningAlerts.launchFailed(terminal: .ghostty, command: "'/example/mo' clean"))] {
                        let dialog = alert.window; dialog.isReleasedWhenClosed = false
                        dialog.appearance = window.appearance; alert.layout(); dialog.orderFront(nil)
                        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                        defer { dialog.close() }
                        if let view = dialog.contentView { try capture(view, at: URL(fileURLWithPath: path).appendingPathComponent(name + "-" + (dark ? "dark" : "light") + ".png")) }
                    }
                }
                print("清理缺失状态容器：\(size.width) × \(size.height)，\(dark ? "深色" : "浅色")")
            }
            return true
        } catch { print("清理原生布局测试失败：\(error)"); return false }
    }

    /// 显式开启时才启动 Ghostty；传入临时假工具，绝不调用真实 Mole。
    static func liveGhostty() async -> Bool {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else {
            print("未安装 Ghostty，无法验证实机启动"); return false
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/acceptance/clean-terminal/live-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let runningBefore = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").count
            for index in 1...2 {
                let marker = directory.appendingPathComponent("invocation-\(index).txt")
                let fake = directory.appendingPathComponent("fake mo ' \(index)")
                let command = "#!/bin/sh\nprintf '%s' \"$1\" > " + CleaningCommand.quote(marker.path)
                    + "\nprintf '%s\\n' 'MeowMac 清理入口测试：只运行假工具，未执行清理。'\n"
                try Data(command.utf8).write(to: fake)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
                let error: Error? = await withCheckedContinuation { continuation in
                    CleanTerminalLauncher.launch(terminal: .ghostty, application: application,
                        script: CleaningCommand.script(executable: fake.path)) { continuation.resume(returning: $0) }
                }
                guard error == nil else { print("Ghostty 启动失败：\(String(describing: error))"); return false }
                // 不结束任何进程。最多等 10 秒，窗口保留假工具输出供用户查看。
                for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard try String(contentsOf: marker) == "clean" else { return false }
            }
            let evidence = "runningBefore=\(runningBefore)\nrunningAfter=\(NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty").count)\nmarkers=clean,clean\n"
            try Data(evidence.utf8).write(to: directory.appendingPathComponent("evidence.txt"))
            print("Ghostty 两次启动均执行假工具；测试窗口保留输出，用户可按回车关闭。")
            return true
        } catch { print("Ghostty 实机测试失败：\(error)"); return false }
    }

    private static func capture(_ view: NSView, at file: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.coderInvalidValue) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard bitmap.representation(using: .png, properties: [:]) != nil else { throw CocoaError(.coderInvalidValue) }
        // 补上窗口自己的背景色，便于查看透明缓存；不能代替真实材质验收。
        guard let flattened = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
            pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: flattened) else { throw CocoaError(.coderInvalidValue) }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh).fill()
        }
        bitmap.draw(in: NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh),
                    from: NSRect(origin: .zero, size: bitmap.size), operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
        context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        guard let flattenedPNG = flattened.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
        try flattenedPNG.write(to: file)
    }
}
