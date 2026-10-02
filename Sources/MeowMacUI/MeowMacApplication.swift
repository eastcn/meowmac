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
    private let catStore = CatStore()
    private lazy var layoutSettings = LayoutSettingsController(state: panelState)
    private let logger = Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "app")
    private let collector = SystemCollector()
    private var energyTracker = EnergyTracker()
    private var snapshot: SystemSnapshot?
    private var hasSystemBaseline = false
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
        CatRuntime.initialize(state: panelState, store: catStore)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = CatRenderer.image(cat: panelState.selectedCat, display: panelState.catDisplay(), frame: 0)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = PanelHosting.make(state: panelState).controller
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
        panelState.onShowStorage = { provider in
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".\(provider.rawValue)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        panelState.onClean = { [weak self] in self?.openCleanCommand() }
        panelState.onOpenConfig = { [weak self] in self?.openConfig() }
        panelState.onShowConfigFolder = { [weak self] in self?.showConfigFolder() }
        panelState.onSelectCat = { [weak self] id in self?.selectCat(id) }
        panelState.onImportCat = { [weak self] in self?.importCat() }
        panelState.onShowCats = { [weak self] in self?.showCats() }
        panelState.onShowLayoutSettings = { [weak self] in self?.layoutSettings.present() }
        panelState.onCatChanged = { [weak self] in self?.layoutSettings.catDidChange() }
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
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample(thermalChanged: true) }
        })
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

    private func sample(thermalChanged: Bool = false) {
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
        panelState.chartHistory.append(latest, force: thermalChanged)
        panelState.lastRefreshedAt = latest.timestamp
        if latest.thermal == .fair {
            if panelState.fairSince == nil { panelState.fairSince = latest.timestamp }
        } else { panelState.fairSince = nil }
        frameInterval = panelState.catDisplay().frameInterval
    }

    private func sampleEnergy() {
        Task.detached { [weak self] in
            do {
                let processes = try EnergySampler.processes()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.panelState.energy = self.energyTracker.evaluate(processes: processes,
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

    private func showCats() {
        do {
            if let folder = try catStore.catsDirectoryIfSafe() {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } else { showCatError("尚未导入猫配置。") }
        } catch { showCatError(error.localizedDescription) }
    }

    private func showCatError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "猫配置"
        alert.informativeText = message
        alert.runModal()
    }

    private func updateCatImage() {
        statusItem?.button?.image = CatRenderer.image(cat: panelState.selectedCat, display: panelState.catDisplay(), frame: frame)
    }

    private func selectCat(_ id: String) {
        do {
            try catStore.select(id, state: panelState)
            frame = 0
            updateCatImage()
            scheduleFrame()
        } catch {
            logger.error("切换猫配置失败：\(error.localizedDescription, privacy: .private)")
            showCatError(error.localizedDescription)
        }
    }

    private func importCat() {
        let panel = NSOpenPanel()
        panel.message = "选择一个 .cat 目录包"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            try catStore.importCat(from: source, state: panelState)
            frame = 0
            updateCatImage()
            scheduleFrame()
        } catch {
            logger.error("导入猫配置失败：\(error.localizedDescription, privacy: .private)")
            showCatError(error.localizedDescription)
        }
    }

    private func scheduleFrame() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let display = self.panelState.catDisplay()
                self.frame = display.nextFrame(self.frame, sleeping: self.screenSleeping)
                self.updateCatImage()
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
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
    }
}
