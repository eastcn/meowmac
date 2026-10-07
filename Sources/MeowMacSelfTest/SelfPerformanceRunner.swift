import AppKit
import Combine
import Foundation
import MeowMacCore
import MeowMacUI
import MeowMacSystem

@MainActor
final class SelfPerformanceRunner {
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var cadence: ApplicationCadence?
    private var subscription: AnyCancellable?
    private var counters: [String: Int] = [:]
    private var durations: [String: Double] = [:]
    private var state: PanelState?
    private var startedAt: Double = 0
    private var lastImageFrame: Int?
    private var frameChanges = 0
    private var omitImage = false
    private var omitSystem = false
    private var notificationProbe = false
    private var omitNotificationProcess = false
    private var notificationStore: NotificationStore?
    private var notificationCoordinator: NotificationCoordinator?
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let runner = SelfPerformanceRunner()
            try await runner.execute(arguments)
            return 0
        } catch { fputs("性能测量失败：\(error)\n", stderr); return 1 }
    }
    private func execute(_ arguments: [String]) async throws {
        guard let mode = arguments.first else { throw PerformanceError.invalid("缺少模式") }
        func option(_ name: String, _ fallback: String = "") -> String {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return fallback }
            return arguments[index + 1]
        }
        guard let seconds = Double(option("--seconds", "30")), seconds >= 1, seconds <= 600,
              let warmup = Double(option("--warmup", "10")), warmup >= 0, warmup <= 60 else { throw PerformanceError.invalid("测量时长无效") }
        let output = option("--output")
        guard output.hasPrefix("build/acceptance/self-performance/"), !output.contains("..") else { throw PerformanceError.invalid("输出必须在忽略证据目录") }
        var result: [String: Any]
        if mode == "collector" {
            let collector = SystemCollector()
            var values: [Double] = [], cpuValues: [Double] = []
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            repeat {
                let reading = try PerformanceReading.read(getpid())
                let started = ProcessInfo.processInfo.systemUptime
                _ = collector.sample()
                values.append(ProcessInfo.processInfo.systemUptime - started)
                cpuValues.append(try reading.delta(to: PerformanceReading.read(getpid())).cpuSeconds)
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } while ProcessInfo.processInfo.systemUptime < deadline
            result = ["collectorSeconds": values, "collectorCPUSeconds": cpuValues, "count": values.count, "source": "SystemCollector.sample",
                      "scope": "专用进程同步采集窗口的CPU；含读数边界与其他线程的小量开销。第一个样本为冷启动。"]
        } else if mode == "live" {
            guard let pid = Int32(option("--pid")), pid > 0 else { throw PerformanceError.invalid("PID 无效") }
            let start = try PerformanceReading.read(pid)
            let auxiliaryStart = auxiliary(parent: pid)
            var childReadings: [[String: Any]] = []
            let deadline = start.uptime + seconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let current = try PerformanceReading.read(pid)
                _ = try start.delta(to: current)
                childReadings.append(auxiliary(parent: pid, windowServer: false))
            }
            let end = try PerformanceReading.read(pid)
            result = ["main": try json(start.delta(to: end)), "mainStart": try json(start), "mainEnd": try json(end),
                      "auxiliaryStart": auxiliaryStart, "auxiliaryEnd": auxiliary(parent: pid), "childrenObserved": childReadings,
                      "work": NSNull(), "workUnavailableReason": "现有安装版没有注入生产计数", "stateChecks": NSNull(), "actualExecutable": executablePath(pid),
                      "display": NSScreen.screens.map { ["width": $0.frame.width, "height": $0.frame.height, "scale": $0.backingScaleFactor] },
                      "reducedMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion]
        } else if mode == "matrix" || mode == "probe" {
            let scene = option("--scene", "closed-running")
            guard ["closed-running", "open-running", "closed-stopped", "open-stopped", "closed-reduced", "open-high"].contains(scene) else { throw PerformanceError.invalid("场景无效") }
            // 不构造应用委托或任何外部服务。显式配置、无持久化、无真实网络模型。
            notificationProbe = arguments.contains("--notification-probe")
            omitNotificationProcess = arguments.contains("--omit-notification-process")
            let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
            guard state.catStore == nil, state.networkModel == nil, state.layoutStore == nil, state.styleStore == nil else { throw PerformanceError.invalid("隔离失败") }
            state.readLastTab = { .system }; state.writeLastTab = { _ in }
            state.catLevelOverride = scene.hasSuffix("stopped") ? .severe : .normal
            state.selectedCat = try CatPackageLoader.builtin(option("--cat", "builtin.slim"))
            startedAt = ProcessInfo.processInfo.systemUptime
            state.now = { [self] in epoch.addingTimeInterval(ProcessInfo.processInfo.systemUptime - startedAt) }
            let load = scene == "open-high" ? 0.9 : 0.24
            for index in -360...0 { state.chartHistory.append(fixture(at: epoch.addingTimeInterval(Double(index) * 10), load: load)) }
            self.state = state
            let reduced = scene == "closed-reduced"
            let cadence = ApplicationCadence(display: { state.catDisplay(reducedMotion: reduced) },
                updateImage: { [weak self] frame in self?.updateImage(frame: frame, reduced: reduced) },
                sample: { [weak self] in self?.updateSystem(load: load) })
            self.cadence = cadence
            cadence.observe = { [weak self] event in self?.count(event) }
            if notificationProbe {
                let store = NotificationStore(rootURL: URL(fileURLWithPath: output).deletingPathExtension().appendingPathComponent("notification-fixture"))
                store.observeSave = { [weak self] in self?.count("notificationFileReplacement") }
                notificationStore = store
                notificationCoordinator = NotificationCoordinator(store: store, startedAt: epoch.addingTimeInterval(-3600)) { [weak self] _ in self?.count("syntheticNotice") }
            }
            state.onRemindersRefreshed = { [weak self] tracker, batch in
                guard let self else { return }
                self.count("reminderRefresh")
                self.processNotifications(tracker, batch: batch)
            }
            subscription = state.objectWillChange.sink { [weak self] _ in self?.count("statePublication") }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.item = item
            let popover = NSPopover()
            popover.behavior = .transient
            let hosting = PanelHosting.make(state: state)
            popover.contentViewController = hosting.controller
            self.popover = popover
            updateSystem(load: load); updateImage(frame: 0, reduced: reduced)
            if arguments.contains("--omit-image-assignment") {
                // 单变量诊断：定时器和调速保持运行，只省去赋图。不能用作正式基线或验收。
                self.omitImage = true
            }
            if arguments.contains("--omit-system-update") { self.omitSystem = true }
            cadence.startSampling(); cadence.scheduleFrame()
            let opened = scene.hasPrefix("open")
            if opened {
                guard let button = item.button else { throw PerformanceError.invalid("菜单栏按钮不可用") }
                state.open()
                NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(nanoseconds: 500_000_000)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
            defer { cadence.stop(); popover.performClose(nil); NSStatusBar.system.removeStatusItem(item) }
            try await wait(seconds: warmup, opened: opened, stopped: scene.hasSuffix("stopped"), reduced: reduced)
            let auxiliaryStart = auxiliary(parent: getpid())
            let start = try PerformanceReading.read(getpid())
            let countsStart = counters, durationsStart = durations, changesStart = frameChanges
            try await wait(seconds: seconds, opened: opened, stopped: scene.hasSuffix("stopped"), reduced: reduced)
            let end = try PerformanceReading.read(getpid())
            let work = counters.mapValues { $0 } .reduce(into: [String: Int]()) { values, entry in values[entry.key] = entry.value - (countsStart[entry.key] ?? 0) }
            let timing = durations.reduce(into: [String: Double]()) { values, entry in values[entry.key] = entry.value - (durationsStart[entry.key] ?? 0) }
            guard work["sampleTimer", default: 0] >= Int(seconds / 2) - 1,
                  work["frameTimer", default: 0] > 0,
                  omitImage || reduced || scene.hasSuffix("stopped") || frameChanges > changesStart else { throw PerformanceError.invalid("生产定时器或帧没有运行") }
            if arguments.contains("--expect-no-redundant-work"), (scene.hasSuffix("stopped") || reduced), work["imageAssignment", default: 0] > 1 {
                throw PerformanceError.invalid("负控命中：静止帧仍重复设置图像，次数=\(work["imageAssignment", default: 0])")
            }
            let width = hosting.controller.view.bounds.width
            if opened && abs(width - 360) > 0.5 { throw PerformanceError.invalid("原生面板宽度不是360pt：\(width)") }
            let finalDisplay = state.catDisplay(reducedMotion: reduced)
            if scene == "open-high" && !finalDisplay.speedLines { throw PerformanceError.invalid("高负载速度线没有开启") }
            result = ["main": try json(start.delta(to: end)), "mainStart": try json(start), "mainEnd": try json(end), "work": work,
                      "workSeconds": timing, "auxiliaryStart": auxiliaryStart, "auxiliaryEnd": auxiliary(parent: getpid()),
                      "stateChecks": ["panelShown": opened, "width": width, "stopped": scene.hasSuffix("stopped"), "reducedMotion": reduced,
                                      "frameChanges": frameChanges - changesStart, "scale": item.button?.window?.backingScaleFactor ?? 0,
                                      "speedLines": finalDisplay.speedLines, "frameInterval": finalDisplay.frameInterval],
                      "conditions": ["scene": scene, "cat": state.selectedCat!.id, "load": load, "fixture": "self-performance-v1", "warmup": warmup],
                      "experiment": ["omitImageAssignment": omitImage, "omitSystemUpdate": omitSystem,
                                     "notificationProbe": notificationProbe, "omitNotificationProcess": omitNotificationProcess],
                      "isolation": ["applicationDelegate": false, "networkBridge": false, "quotaCLI": false, "notifications": false,
                                    "agent": false, "realCollector": false, "realConfiguration": false, "userPersistence": false]]
        } else { throw PerformanceError.invalid("模式无效") }
        result["version"] = AppIdentity.version
        result["mode"] = mode
        result["recordedAt"] = ISO8601DateFormatter().string(from: Date())
        result["requestedSeconds"] = seconds
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: output).deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: output))
        print("性能记录已写入；状态校验通过。")
    }
    private func count(_ key: String) { counters[key, default: 0] += 1 }
    private func updateImage(frame: Int, reduced: Bool) {
        guard let state else { return }
        if omitImage { count("omittedImageAssignment"); return }
        let started = ProcessInfo.processInfo.systemUptime
        item?.button?.image = CatRenderer.image(cat: state.selectedCat, display: state.catDisplay(reducedMotion: reduced), frame: frame,
            observeDraw: { [weak self] seconds in self?.count("renderDraw"); self?.durations["renderDraw", default: 0] += seconds })
        count("imageAssignment")
        durations["imageAssignment", default: 0] += ProcessInfo.processInfo.systemUptime - started
        if let previous = lastImageFrame, frame != previous { frameChanges += 1 }
        lastImageFrame = frame
    }
    private func updateSystem(load: Double) {
        guard let state, let cadence else { return }
        if omitSystem { count("omittedSystemUpdate"); return }
        let started = ProcessInfo.processInfo.systemUptime
        SystemUpdatePath.apply(fixture(at: state.now(), load: load), state: state, hasBaseline: counters["systemUpdate", default: 0] > 0, notifications: notificationCoordinator)
        cadence.frameInterval = state.catDisplay().frameInterval
        count("systemUpdate")
        durations["systemUpdate", default: 0] += ProcessInfo.processInfo.systemUptime - started
    }
    private func processNotifications(_ tracker: ReminderTracker, batch: ReminderBatch) {
        guard let coordinator = notificationCoordinator, let state else { return }
        count("notificationProcess")
        let before = coordinator.records
        let started = ProcessInfo.processInfo.systemUptime
        let reading = try? PerformanceReading.read(getpid())
        if !omitNotificationProcess { coordinator.process(tracker, batch: batch, now: state.now()) }
        if let reading, let end = try? PerformanceReading.read(getpid()), let delta = try? reading.delta(to: end) {
            durations["notificationProcessCPU", default: 0] += delta.cpuSeconds
        }
        durations["notificationProcess", default: 0] += ProcessInfo.processInfo.systemUptime - started
        if before != coordinator.records {
            count("notificationRecordChange")
            var normalized = before
            for (key, next) in coordinator.records where normalized[key] != nil { normalized[key]?.lastSeenAt = next.lastSeenAt }
            if normalized == coordinator.records { count("notificationOnlyLastSeenChange") }
        }
    }
    private func fixture(at date: Date, load: Double) -> SystemSnapshot {
        SystemSnapshot(timestamp: date, cpuUsage: load, memoryPressure: .normal, swapUsedBytes: 1_000_000_000,
            diskAvailableBytes: notificationProbe ? 20_000_000_000 : 200_000_000_000, diskTotalBytes: 500_000_000_000,
            networkReceivedBytesPerSecond: 128_000, networkSentBytesPerSecond: 32_000,
            battery: BatteryMetrics(temperatureCelsius: 31, systemPowerWatts: 8), thermal: .nominal,
            memoryUsedBytes: 8_000_000_000, memoryTotalBytes: 16_000_000_000, memoryPressurePercent: 40)
    }
    private func wait(seconds: Double, opened: Bool, stopped: Bool, reduced: Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            try await Task.sleep(nanoseconds: 250_000_000)
            guard popover?.isShown == opened, let state, state.catDisplay(reducedMotion: reduced).stopped == stopped,
                  state.catDisplay(reducedMotion: reduced).reducedMotion == reduced,
                  !stopped || cadence?.frame == 0 else { throw PerformanceError.invalid("实际面板或动画状态错误 shown=\(popover?.isShown ?? false)/\(opened) stopped=\(state?.catDisplay(reducedMotion: reduced).stopped ?? false)/\(stopped) frame=\(cadence?.frame ?? -1)") }
        } while ProcessInfo.processInfo.systemUptime < deadline
    }
    private func executablePath(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        return count > 0 ? String(cString: buffer) : "unavailable"
    }
    private func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func auxiliary(parent: Int32, windowServer: Bool = true) -> [String: Any] {
        var values: [String: Any] = [:]
        // 只枚举 PID/PPID/comm，不读命令参数、凭据或进程环境。
        do {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,ppid=,comm="]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe()
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { throw PerformanceError.invalid("辅助进程枚举不可用") }
            let rows = text.split(separator: "\n").compactMap { line -> (Int32, Int32, String)? in
                let parts = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
                return (pid, ppid, String(parts[2]))
            }
            var descendants: Set<Int32> = [parent]
            while true {
                let next = Set(rows.filter { descendants.contains($0.1) }.map { $0.0 })
                let old = descendants.count; descendants.formUnion(next)
                if old == descendants.count { break }
            }
            values["children"] = rows.filter { $0.0 != process.processIdentifier && $0.0 != parent && descendants.contains($0.0) }.map { pid, _, name -> [String: Any] in
                var row: [String: Any] = ["pid": pid, "name": URL(fileURLWithPath: name).lastPathComponent]
                do { row["reading"] = try json(PerformanceReading.read(pid)) }
                catch { row["unavailable"] = String(describing: error) }
                return row
            }
            if windowServer {
                if let pid = rows.first(where: { URL(fileURLWithPath: $0.2).lastPathComponent == "WindowServer" })?.0 {
                    do { values["windowServer"] = try json(PerformanceReading.read(pid)) }
                    catch { values["windowServerUnavailable"] = String(describing: error) }
                } else { values["windowServerUnavailable"] = "未找到进程" }
            }
        } catch { values["enumerationUnavailable"] = String(describing: error) }
        values["coverage"] = "定点/轮询观察；已结束的短命子进程可能遗漏，不作完整成本结论"
        return values
    }
}
