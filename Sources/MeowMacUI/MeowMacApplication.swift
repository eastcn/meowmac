import AppKit
import MeowMacCore
import MeowMacSystem
import SwiftUI
import os
import TunCanaryUI
import TunCanaryCore

@MainActor
public final class MeowMacApplication: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var networkBridge: NetworkBridge?
    private var quotaCoordinator: QuotaCoordinator?
    private let panelState = PanelState()
    private let logger = Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "app")
    private let collector = SystemCollector()
    private var energyTracker = EnergyTracker()
    private var snapshot: SystemSnapshot?
    private var hasSystemBaseline = false
    private var motion = CatMotion()
    private var frame = 0
    private var frameInterval = 0.5
    private var sampleTimer: Timer?
    private var energyTimer: Timer?
    private var frameTimer: Timer?
    private var screenSleeping = false
    private var observers: [NSObjectProtocol] = []
    private let configResult = ConfigStore.load()
    private let loginItem = MainAppLoginItemController()

    public static func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = MeowMacApplication()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = CatRenderer.image(frame: 0, level: displayLevel)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PanelView(state: panelState))
        self.popover = popover
        let bridge = NetworkBridge { [weak panelState] tone in panelState?.networkTone = tone }
        networkBridge = bridge
        panelState.networkModel = bridge.model
        bridge.start()
        let quota = QuotaCoordinator(state: panelState, config: configResult.config)
        quotaCoordinator = quota
        quota.start()
        panelState.onRefresh = { [weak self] in
            self?.sample(); self?.sampleEnergy(); self?.networkBridge?.recheck(); self?.quotaCoordinator?.manualRefresh()
        }
        panelState.onClean = { [weak self] in self?.openCleanCommand() }
        panelState.onOpenConfig = { [weak self] in self?.openConfig() }
        panelState.onShowConfigFolder = { [weak self] in self?.showConfigFolder() }
        panelState.onQuit = { NSApplication.shared.terminate(nil) }
        panelState.loginEnabled = loginItem.status == .enabled
        panelState.onToggleLogin = { [weak self] enabled in
            guard let self else { return }
            do {
                try self.loginItem.setEnabled(enabled)
                self.panelState.loginEnabled = self.loginItem.status == .enabled
            } catch { self.logger.error("开机启动设置失败：\(error.localizedDescription, privacy: .private)") }
        }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        energyTimer = Timer.scheduledTimer(withTimeInterval: configResult.config.processSampleSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleEnergy() }
        }
        sample()
        updateCleaningHistory()
        sampleEnergy()
        scheduleFrame()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screenSleeping = true }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screenSleeping = false }
        })
    }

    private var displayLevel: HealthLevel {
        switch ProcessInfo.processInfo.environment["MEOWMAC_FORCE_LEVEL"] {
        case "warn": return .warn
        case "severe": return .severe
        case "normal": return .normal
        default: return panelState.health.level
        }
    }

    private func sample() {
        let latest = collector.sample()
        snapshot = latest
        panelState.snapshot = latest
        if hasSystemBaseline {
            for (source, failed) in [("CPU", latest.cpuUsage == nil),
                                     ("内存压力", latest.memoryPressure == .unavailable),
                                     ("磁盘", latest.diskAvailableBytes == nil),
                                     ("电池", latest.battery.temperatureCelsius == nil)] {
                panelState.failures[source] = failed ? (panelState.failures[source] ?? 0) + 1 : 0
                if panelState.failures[source] == configResult.config.sourceFailureCount {
                    logger.error("系统数据源连续采集失败：\(source, privacy: .public)")
                }
            }
        }
        hasSystemBaseline = true
        panelState.chartHistory.append(latest)
        panelState.lastRefreshedAt = latest.timestamp
        if latest.thermal == .fair {
            if panelState.fairSince == nil { panelState.fairSince = latest.timestamp }
        } else { panelState.fairSince = nil }
        frameInterval = motion.update(cpu: latest.cpuUsage ?? 0, pressure: latest.memoryPressure,
                                      config: configResult.config)
    }

    private func sampleEnergy() {
        Task.detached { [weak self] in
            do {
                let processes = try EnergySampler.processes()
                let assertions = try EnergySampler.assertions()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.panelState.energy = self.energyTracker.evaluate(processes: processes, assertions: assertions,
                        pressure: self.snapshot?.memoryPressure ?? .unavailable, now: Date(), config: self.configResult.config)
                    self.panelState.failures["energy"] = 0
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.panelState.failures["energy", default: 0] += 1
                    self.logger.error("能耗采样失败：\(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            panelState.open()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openCleanCommand() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeowMac/tmp", isDirectory: true)
        let file = directory.appendingPathComponent("clean.command")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("mo clean\n".utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            if !NSWorkspace.shared.open(file) { logger.error("终端未打开清理脚本") }
        } catch { logger.error("清理入口打开失败：\(error.localizedDescription, privacy: .private)") }
    }

    private func updateCleaningHistory() {
        do { panelState.lastCleaning = try MoHistoryReader.latest(executable: configResult.config.moPath) }
        catch { logger.error("清理历史读取失败：\(error.localizedDescription, privacy: .private)") }
    }

    private func openConfig() {
        let file = ConfigStore.defaultURL
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(configResult.config).write(to: file, options: .atomic)
            }
            if !NSWorkspace.shared.open(file) { logger.error("配置文件未打开") }
        } catch { logger.error("配置文件打开失败：\(error.localizedDescription, privacy: .private)") }
    }

    private func showConfigFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.defaultURL.deletingLastPathComponent()])
    }

    private func scheduleFrame() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.screenSleeping && self.displayLevel != .severe {
                    self.frame = (self.frame + 1) % 5
                }
                self.statusItem?.button?.image = CatRenderer.image(frame: self.frame, level: self.displayLevel)
                self.scheduleFrame()
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        sampleTimer?.invalidate()
        energyTimer?.invalidate()
        networkBridge?.stop()
        quotaCoordinator?.stop()
        frameTimer?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
