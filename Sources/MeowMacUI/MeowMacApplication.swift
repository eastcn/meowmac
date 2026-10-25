import AppKit
import Combine
import MeowMacCore
import MeowMacSystem
import SwiftUI
import os
import TunCanaryUI
import TunCanaryCore

@MainActor
public final class MeowMacApplication: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var networkBridge: NetworkBridge?
    private var proxyTrafficCoordinator: ProxyTrafficCoordinator?
    private var networkRecorder: NetworkHistoryRecorder?
    private var batteryRecorder: BatteryHistoryRecorder?
    private var siteHistorySubscription: AnyCancellable?
    private var quotaCoordinator: QuotaCoordinator?
    private var resetCoordinator: CodexResetCoordinator?
    private let panelState = PanelState()
    private let catStore = CatStore()
    private lazy var cleaningController = CleaningController(state: panelState,
        openConfig: { [weak self] in self?.openConfig() },
        chooseTerminal: { [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            self.popover?.performClose(nil)
            SettingsMenu.presentCleanTerminals(state: self.panelState, anchor: button)
        })
    private lazy var aiAgentController = AIAgentController(state: panelState)
    private lazy var aiDiagnosisWindow = AIDiagnosisWindowController(controller: aiAgentController)
    private var settingsWindow: SettingsWindowController?
    private let logger = Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "app")
    private let collector = SystemCollector()
    private var energyTracker = EnergyTracker()
    private var snapshot: SystemSnapshot?
    private var hasSystemBaseline = false
    private var energyLoop: EnergyLoopControl?
    private let menuBarImage = MenuBarCatImage()
    private lazy var desktopCat = DesktopCatController(state: panelState, onOpenPanel: { [weak self] in self?.showPanel() })
    private lazy var cadence = ApplicationCadence(
        display: { [weak self] in self?.panelState.catDisplay() ?? PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil)).catDisplay() },
        updateImage: { [weak self] _ in self?.updateCatImage() },
        sample: { [weak self] in self?.sample() })
    private var observers: [NSObjectProtocol] = []
    private let configResult = ConfigStore.load()
    private let loginItem = MainAppLoginItemController()
    private let notifier = MeowMacNotifier()
    private var notificationCoordinator: NotificationCoordinator?

    public static func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = MeowMacApplication()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        for reason in configResult.config.alertRules.diagnostics { logger.error("提醒规则读取：\(reason, privacy: .public)") }
        for reason in configResult.config.desktopCat.diagnostics { logger.error("桌面猫配置读取：\(reason, privacy: .public)") }
        CatRuntime.initialize(state: panelState, store: catStore)
        startNotifications()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button { menuBarImage.assign(to: button, cat: panelState.selectedCat, display: panelState.catDisplay(), frame: 0) }
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = PanelHosting.make(state: panelState).controller
        self.popover = popover
        let bridge = NetworkBridge(notifier: notifier, root: catStore.rootURL,
            onTone: { [weak panelState] tone in panelState?.networkTone = tone },
            onEgressAlert: { [weak self] alert in
                guard let self else { return }
                self.notificationCoordinator?.egressRuleEnabled = self.panelState.configResult.config.alertRules.enabled(.egress, config: self.panelState.configResult.config)
                let model = self.panelState.networkModel, redactor = model?.redactor
                self.notificationCoordinator?.process(alert, history: model?.egressState.history ?? [],
                                                      redact: { redactor?.redact($0) ?? $0 })
            })
        networkBridge = bridge
        panelState.networkModel = bridge.model
        let recorder = NetworkHistoryRecorder { [weak panelState] history in panelState?.networkHistory = history }
        networkRecorder = recorder
        siteHistorySubscription = bridge.model.$siteHistory.dropFirst().sink { [weak recorder] history in
            Task { @MainActor in recorder?.record(siteHistory: history, now: Date()) }
        }
        bridge.start()
        batteryRecorder = BatteryHistoryRecorder { [weak panelState] history in panelState?.batteryHistory = history }
        let proxy = ProxyTrafficCoordinator(config: configResult.config) { [weak panelState] value in panelState?.proxyTraffic = value }
        proxyTrafficCoordinator = proxy
        proxy.start()
        let quota = QuotaCoordinator(state: panelState, config: configResult.config)
        quotaCoordinator = quota
        let settings = SettingsWindowController(state: panelState, network: bridge.model, quotaCoordinator: quota)
        settingsWindow = settings
        settings.ownsWindow = { [weak self] window in self?.popover?.contentViewController?.view.window === window }
        settings.installShortcutMonitor()
        panelState.onQuotaSourcesRemoved = { [weak self] providers in self?.notificationCoordinator?.removeProviders(providers) }
        let absent = QuotaCatalog.usageNames.keys.compactMap(QuotaProvider.init(rawValue:)).filter { !panelState.quotaProviders.contains($0) }
        notificationCoordinator?.removeProviders(absent)
        quota.start()
        let reset = CodexResetCoordinator(state: panelState)
        resetCoordinator = reset
        reset.start()
        panelState.onRefresh = { [weak self] in
            self?.sample(); self?.networkBridge?.recheck(); self?.quotaCoordinator?.manualRefresh()
            self?.resetCoordinator?.refresh(manual: true)
        }
        panelState.onShowStorage = { provider in
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".\(provider.rawValue)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        panelState.onClean = { [weak self] in self?.cleaningController.clean() }
        panelState.onSelectCleanTerminal = { [weak self] in self?.cleaningController.select($0) }
        panelState.onPrepareCleanTerminalMenu = { [weak self] in self?.cleaningController.refreshTerminals() }
        _ = cleaningController
        panelState.onSelectAIAgent = { [weak self] in self?.aiAgentController.select($0) }
        panelState.onSetAIDiagnosisEntry = { [weak self] in self?.aiAgentController.setEntry($0) }
        panelState.onDetectAIAgents = { [weak self] in self?.aiAgentController.refresh() }
        _ = aiAgentController
        panelState.onAIDiagnosis = { [weak self] in
            guard let self else { return }
            self.aiDiagnosisWindow.open(prompt: self.panelState.aiDiagnosisPrompt)
            self.popover?.performClose(nil)
        }
        panelState.onOpenConfig = { [weak self] in self?.openConfig() }
        panelState.onShowConfigFolder = { [weak self] in self?.showConfigFolder() }
        panelState.onSelectCat = { [weak self] id in self?.selectCat(id) }
        panelState.onImportCat = { [weak self] in self?.importCat() }
        panelState.onShowCats = { [weak self] in self?.showCats() }
        panelState.onOpenSettings = { [weak self] section in
            self?.settingsWindow?.open(section: section)
            self?.popover?.performClose(nil)
        }
        panelState.onImportCodexBarHistory = { [weak self] in self?.importCodexBarHistory() }
        panelState.onCatChanged = { [weak self] in self?.settingsWindow?.catDidChange() }
        panelState.onQuit = { NSApplication.shared.terminate(nil) }
        panelState.onDesktopCatChanged = { [weak self] _ in self?.desktopCat.apply() }
        panelState.onOpenDesktopCatSettings = { [weak self] in
            self?.settingsWindow?.openDesktopCat()
            self?.popover?.performClose(nil)
        }
        desktopCat.makeMenu = { [weak self] in
            guard let self else { return nil }
            return DesktopCatMenu.make(state: self.panelState, openPanel: { [weak self] in self?.showPanel() })
        }
        panelState.loginEnabled = loginItem.status == .enabled
        panelState.onToggleLogin = { [weak self] enabled in
            guard let self else { return }
            do {
                try self.loginItem.setEnabled(enabled)
                self.panelState.loginEnabled = self.loginItem.status == .enabled
            } catch { self.logger.error("开机启动设置失败：\(error.localizedDescription, privacy: .private)") }
        }
        cadence.startSampling()
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample(thermalChanged: true) }
        })
        sample()
        desktopCat.apply()
        updateCleaningHistory()
        sampleEnergy()
        startEnergyLoop()
        scheduleFrame()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cadence.screenSleeping = true }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cadence.screenSleeping = false
                self?.panelState.refreshReminders()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.panelState.rulesWillSleep(); self?.proxyTrafficCoordinator?.sleep(); self?.batteryRecorder?.sleep() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.batteryRecorder?.wake(); self?.panelState.refreshReminders(); self?.sample(); self?.sampleEnergy(); self?.startEnergyLoop(); self?.proxyTrafficCoordinator?.wake() }
        })
    }

    private func sample(thermalChanged: Bool = false) {
        let latest = collector.sample()
        snapshot = latest
        SystemUpdatePath.apply(latest, state: panelState, hasBaseline: hasSystemBaseline,
            thermalChanged: thermalChanged, sourceFailureCount: configResult.config.sourceFailureCount,
            notifications: notificationCoordinator,
            sourceFailed: { [self] source in logger.error("系统数据源连续采集失败：\(source, privacy: .public)") },
            recordNetwork: { [self] latest in
                networkRecorder?.record(received: latest.networkReceivedBytesPerSecond,
                    sent: latest.networkSentBytesPerSecond, at: latest.timestamp)
            })
        batteryRecorder?.record(latest.battery.status, at: latest.timestamp)
        hasSystemBaseline = true
        cadence.frameInterval = panelState.catDisplay().frameInterval
    }

    /// 立即采样一次，窗口只有 1 秒，只刷新排行，不计入持续时长。
    private func sampleEnergy() {
        Task.detached { [weak self] in
            do {
                let processes = try EnergySampler.processes()
                await MainActor.run { [weak self] in self?.applyEnergy(processes, coverage: 1) }
            } catch {
                await MainActor.run { [weak self] in self?.energyFailed(error) }
            }
        }
    }

    /// 首尾相接地采样：每次 `top` 的窗口就是一个完整的采样间隔，
    /// 所以持续高占用的判定覆盖了整段时间。唤醒后重启，丢弃跨越休眠的那一次。
    /// 用专用线程而不是协作线程池，因为 `top` 一次要阻塞一整个窗口。
    private func startEnergyLoop() {
        energyLoop?.cancel()
        let control = EnergyLoopControl()
        energyLoop = control
        let window = configResult.config.processSampleSeconds
        let thread = Thread { [weak self] in
            while !control.isCancelled {
                do {
                    let processes = try EnergySampler.processes(window: window)
                    Task { @MainActor [weak self] in
                        guard !control.isCancelled else { return }
                        self?.applyEnergy(processes, coverage: window)
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        guard !control.isCancelled else { return }
                        self?.energyFailed(error)
                    }
                    Thread.sleep(forTimeInterval: min(window, 30))
                }
            }
        }
        thread.name = "io.github.eastcn.meowmac.energy"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func applyEnergy(_ processes: [ProcessEnergy], coverage: TimeInterval) {
        let sampledAt = Date()
        panelState.energyUpdatedAt = sampledAt
        panelState.energy = energyTracker.evaluate(processes: processes,
            pressure: snapshot?.memoryPressure ?? .unavailable, now: sampledAt, config: panelState.configResult.config.alertRules.detectorConfig(panelState.configResult.config), coverage: coverage)
        panelState.failures["energy"] = 0
    }

    private func energyFailed(_ error: Error) {
        panelState.failures["energy", default: 0] += 1
        logger.error("能耗采样失败：\(error.localizedDescription, privacy: .private)")
    }

    /// D41：提醒变化时发系统通知；点通知打开面板对应页。
    private func startNotifications() {
        let coordinator = NotificationCoordinator(store: NotificationStore(rootURL: catStore.rootURL)) { [weak self] notice in
            guard let notifier = self?.notifier else { return }
            Task { await notifier.deliver(notice) }
        }
        notificationCoordinator = coordinator
        panelState.notificationSettings = coordinator.settings
        panelState.onSetNotificationSettings = { [weak self] next in
            guard let self, let coordinator = self.notificationCoordinator, coordinator.update(next) else { return }
            self.panelState.notificationSettings = coordinator.settings
        }
        panelState.onPrepareNotificationMenu = { [weak self] in self?.refreshNotificationAuthorization(request: false) }
        panelState.onOpenNotificationSystemSettings = {
            let id = MeowMacCore.AppIdentity.bundleID
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
                NSWorkspace.shared.open(url)
            }
        }
        panelState.onRemindersRefreshed = { [weak self] tracker, batch in
            guard let self, let coordinator = self.notificationCoordinator else { return }
            let redactor = self.panelState.networkModel?.redactor
            coordinator.process(tracker, batch: batch, now: self.panelState.now(), redact: { redactor?.redact($0) ?? $0 })
        }
        notifier.onOpen = { [weak self] tab in self?.openPanel(at: tab) }
        refreshNotificationAuthorization(request: true)
        panelState.refreshReminders()
    }

    private func refreshNotificationAuthorization(request: Bool) {
        Task { @MainActor [weak self] in
            guard let notifier = self?.notifier else { return }
            var status = await notifier.authorizationStatus()
            if request && status == .notDetermined {
                _ = await notifier.requestAuthorization()
                status = await notifier.authorizationStatus()
            }
            self?.panelState.notificationsAuthorized = status == .authorized ? true : status == .denied ? false : nil
        }
    }

    private func openPanel(at tab: PanelTab) {
        showPanel()
        panelState.showingReminders = false
        panelState.select(tab)
    }

    /// 菜单栏猫、通知和桌面猫共用的开面板入口；已打开时不重复打开。
    private func showPanel() {
        guard let button = statusItem?.button, let popover, !popover.isShown else { return }
        proxyTrafficCoordinator?.setPanelVisible(true)
        panelState.open()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover() {
        if popover?.isShown == true { popover?.performClose(nil) } else { showPanel() }
    }

    private func updateCleaningHistory() {
        do {
            switch try MoHistoryReader.read(configuredPath: configResult.config.moPath) {
            case .notInstalled:
                panelState.lastCleaning = nil
                panelState.cleaningHistoryMessage = "未找到 Mole · 清理需要先安装"
            case .available(let record):
                panelState.lastCleaning = record
                panelState.cleaningHistoryMessage = nil
            }
        } catch {
            panelState.cleaningHistoryMessage = "清理记录读取失败"
            logger.error("清理历史读取失败：\(error.localizedDescription, privacy: .private)")
        }
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

    private func importCodexBarHistory() {
        let alert = NSAlert()
        alert.messageText = "导入 CodexBar 历史"
        do {
            guard let quotaCoordinator else { return }
            alert.informativeText = try quotaCoordinator.importCodexBarHistory().message
        } catch {
            logger.error("CodexBar 历史导入失败：\(error.localizedDescription, privacy: .private)")
            alert.alertStyle = .warning
            alert.informativeText = "导入失败，已有数据未改动。"
        }
        alert.runModal()
    }

    private func showCatError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "猫配置"
        alert.informativeText = message
        alert.runModal()
    }

    private func updateCatImage() {
        let display = panelState.catDisplay()
        if let button = statusItem?.button { menuBarImage.assign(to: button, cat: panelState.selectedCat, display: display, frame: cadence.frame) }
        // 桌面猫与菜单栏同一帧号；关闭时控制器没有窗口，直接返回。
        desktopCat.updateFrame(cadence.frame, display: display)
    }

    private func selectCat(_ id: String) {
        do {
            try catStore.select(id, state: panelState)
            cadence.frame = 0
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
            cadence.frame = 0
            updateCatImage()
            scheduleFrame()
        } catch {
            logger.error("导入猫配置失败：\(error.localizedDescription, privacy: .private)")
            showCatError(error.localizedDescription)
        }
    }

    private func scheduleFrame() { cadence.scheduleFrame() }

    public func popoverDidClose(_ notification: Notification) { proxyTrafficCoordinator?.setPanelVisible(false) }

    public func applicationWillTerminate(_ notification: Notification) {
        proxyTrafficCoordinator?.stop()
        settingsWindow?.removeShortcutMonitor()
        cadence.stop()
        desktopCat.hide()
        energyLoop?.cancel()
        networkBridge?.stop()
        quotaCoordinator?.stop()
        resetCoordinator?.stop()
        observers.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
    }
}

private final class EnergyLoopControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
