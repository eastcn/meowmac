import AppKit
import Foundation
import MeowMacCore
import MeowMacQuota
import os

@MainActor
public final class QuotaCoordinator {
    public let client: CodexBarClient
    private let history: QuotaHistoryStore
    private let importSource: URL
    private let config: LocalConfig
    private let state: PanelState
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "quota-schedule")
    private let scanner: AgentActivityScanner
    private var schedule = QuotaSchedule()
    private var sessionPoller = SessionPoller()
    private var refreshTimer: Timer?
    private var sessionTimer: Timer?
    private var lastPrunedAt: Date?
    private var refreshing = false
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []

    public init(state: PanelState, config: LocalConfig, history: QuotaHistoryStore = QuotaHistoryStore(),
                importSource: URL = CodexBarHistoryImport.defaultSource, scanner: AgentActivityScanner = AgentActivityScanner(),
                client: CodexBarClient? = nil, sourceStore: QuotaSourceStore = QuotaSourceStore()) {
        self.state = state; self.config = config; self.history = history; self.importSource = importSource
        self.scanner = scanner
        self.client = client ?? CodexBarClient(path: config.codexBarCLIPath)
        self.sourceStore = sourceStore
        let loaded = sourceStore.load()
        state.applyQuotaSources(loaded.list); state.quotaSourceRecoveryReason = loaded.recoveryReason
    }

    public func start() {
        state.showsCodexBarImport = !codexBarImportDone
        do { try history.prune(before: Date().addingTimeInterval(Double(-config.quotaHistoryDays) * 86400)); lastPrunedAt = Date() }
        catch { logger.error("额度历史清理失败：\(error.localizedDescription, privacy: .private)") }
        for provider in state.quotaProviders {
            do { state.quotaHistory[provider] = try history.read(provider) }
            catch { logger.error("额度历史读取失败：\(error.localizedDescription, privacy: .private)") }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        sessionTimer = Timer.scheduledTimer(withTimeInterval: config.sessionPollSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollSessions() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sleeping = true; self?.schedule.sleep() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sleeping = false
                if self.schedule.wake(at: Date(), config: self.config) { self.refreshAll() }
            }
        })
        refreshAll()
        pollSessions()
    }

    public func stop() {
        refreshTimer?.invalidate(); sessionTimer?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    /// 一次性导入 CodexBar 额度历史。在主 Actor 上执行，与定时追加串行。
    public var codexBarImportDone: Bool {
        FileManager.default.fileExists(atPath: CodexBarHistoryImport(source: importSource, store: history).marker.path)
    }

    public func importCodexBarHistory(now: Date = Date()) throws -> CodexBarImportReport {
        let report = try CodexBarHistoryImport(source: importSource, store: history)
            .run(now: now, retentionDays: config.quotaHistoryDays)
        state.showsCodexBarImport = !codexBarImportDone
        if report.totalImported > 0 {
            for provider in state.quotaProviders {
                do { state.quotaHistory[provider] = try history.read(provider) }
                catch { logger.error("额度历史读取失败：\(error.localizedDescription, privacy: .private)") }
            }
        }
        return report
    }

    public func manualRefresh() {
        guard schedule.manualRefresh(at: Date(), config: config) else { return }
        refreshAll()
    }

    private func tick() {
        guard !sleeping else { return }
        if lastPrunedAt.map({ Date().timeIntervalSince($0) >= 86400 }) ?? true {
            do {
                try history.prune(before: Date().addingTimeInterval(Double(-config.quotaHistoryDays) * 86400))
                lastPrunedAt = Date()
            } catch { logger.error("额度历史每日清理失败：\(error.localizedDescription, privacy: .private)") }
        }
        if schedule.dueFullRefresh(at: Date(), config: config) { refreshAll() }
        for provider in schedule.dueFinishRefresh(at: state.now()) { refresh(provider) }
        drain()
    }

    public var isRefreshing: Bool { refreshing }
    public private(set) var lastActualCalls: [QuotaProvider: Date] = [:]
    private var explicitRequests = Set<QuotaProvider>()
    private var pending: [QuotaProvider: Date] = [:]
    private var generations: [QuotaProvider: Int] = [:]
    public var sourceEnabled: [QuotaProvider: Bool] = [:]
    public let sourceStore: QuotaSourceStore

    public func cooldownRemaining(_ provider: QuotaProvider) -> TimeInterval {
        guard let last = lastActualCalls[provider] else { return 0 }
        return max(0, (provider == .claude ? 300 : 60) - state.now().timeIntervalSince(last))
    }

    /// 测试不排队等待冷却；定时、补刷和保存后刷新共用实际调用时间。
    @discardableResult
    public func test(_ provider: QuotaProvider) -> String {
        guard state.quotaProviders.contains(provider) else { return "渠道已移除" }
        let remaining = cooldownRemaining(provider)
        guard remaining == 0 else { return "距上次调用不足 \(provider == .claude ? 5 : 1) 分钟，约 \(Int(ceil(remaining))) 秒后再试" }
        requestRefresh([provider], includeDisabled: true); return "正在测试…"
    }

    public func replaceSources(_ list: QuotaSourceList) throws {
        try sourceStore.save(list)
        let removed = state.quotaProviders.filter { !list.providers.contains($0) }
        for provider in removed { generations[provider, default: 0] += 1; pending.removeValue(forKey: provider); explicitRequests.remove(provider) }
        state.applyQuotaSources(list)
    }

    public func requestRefresh(_ providers: [QuotaProvider], includeDisabled: Bool = false) {
        for provider in providers where state.quotaProviders.contains(provider) && (sourceEnabled[provider] != false || includeDisabled) {
            if includeDisabled { explicitRequests.insert(provider) }
            pending[provider] = state.now().addingTimeInterval(cooldownRemaining(provider))
        }
        drain()
    }

    private func refreshAll() {
        guard !sleeping else { return }
        schedule.markFullRefresh(at: state.now())
        requestRefresh(state.quotaProviders)
    }

    private func refresh(_ provider: QuotaProvider) { requestRefresh([provider]) }

    /// 按真实调用串行刷新，防止多个入口绕过 Claude 的限频或覆盖移除后的缓存。
    public func drain() {
        guard !sleeping, !refreshing else { return }
        guard let provider = state.quotaProviders.first(where: { (pending[$0].map { $0 <= state.now() } ?? false) && (sourceEnabled[$0] != false || explicitRequests.contains($0)) }) else { return }
        let remaining = cooldownRemaining(provider)
        if remaining > 0 { pending[provider] = state.now().addingTimeInterval(remaining); return }
        pending.removeValue(forKey: provider)
        explicitRequests.remove(provider)
        refreshing = true
        lastActualCalls[provider] = state.now()
        let generation = generations[provider, default: 0]
        let client = self.client
        Task { [weak self] in
            let result = await Task.detached { () -> Result<QuotaSnapshot, Error> in
                Result { try client.usage(provider) }
            }.value
            guard let self else { return }
            if self.state.quotaProviders.contains(provider), self.generations[provider, default: 0] == generation {
                self.apply(result, provider: provider)
                if [.claude, .codex].contains(provider) {
                    let costs = await Task.detached { Result { try client.cost(provider) } }.value
                    if self.state.quotaProviders.contains(provider), self.generations[provider, default: 0] == generation {
                        switch costs {
                        case .success(let days): self.state.costs[provider] = days
                        case .failure: self.logger.error("花费采集失败：\(provider.rawValue, privacy: .public)")
                        }
                    }
                }
            }
            self.refreshing = false
            self.drain()
        }
    }

    private func apply(_ result: Result<QuotaSnapshot, Error>, provider: QuotaProvider) {
        let now = state.now()
        switch result {
        case .success(let snapshot):
            state.quotas[provider] = snapshot
            state.quotaErrors.removeValue(forKey: provider)
            state.failures["quota." + provider.rawValue] = 0
            state.quotaAttempts[provider] = QuotaAttempt(at: now, success: true, message: "采集成功")
            do { try history.append(snapshot); state.quotaHistory[provider] = try history.read(provider) }
            catch { logger.error("额度历史存取失败：\(error.localizedDescription, privacy: .private)") }
        case .failure(let error):
            state.quotaErrors[provider] = error.localizedDescription
            state.failures["quota." + provider.rawValue, default: 0] += 1
            state.quotaAttempts[provider] = QuotaAttempt(at: now, success: false, message: error.localizedDescription)
            logger.error("额度采集失败：\(provider.rawValue, privacy: .public)")
        }
        state.failures["quota"] = state.quotaProviders.isEmpty || state.quotaProviders.contains(where: { state.quotas[$0] != nil }) ? 0 : (state.failures["quota"] ?? 0) + 1
        state.lastRefreshedAt = now
    }

    /// 会话活跃检测（D8）：本地扫描 transcript 的修改时间，不调用 CLI。
    /// 只有某个渠道的目录读不了时，才对它退回 `sessions`，且间隔不少于 5 分钟。
    private func pollSessions() {
        guard !sleeping else { return }
        let scanner = self.scanner
        Task.detached { [weak self] in
            let scan = scanner.scan(now: Date())
            await MainActor.run { [weak self] in self?.applySessionScan(scan) }
        }
    }

    private func applySessionScan(_ scan: [QuotaProvider: AgentActivity]) {
        guard !sleeping else { return }
        let now = Date()
        let plan = sessionPoller.plan(scan, at: now)
        for (provider, active) in plan.updates where state.quotaProviders.contains(provider) {
            schedule.sessionUpdate(provider: provider, active: active, at: now, config: config)
        }
        let fallback = plan.fallback.filter { state.quotaProviders.contains($0) }
        guard !fallback.isEmpty else { return }
        logger.warning("会话扫描不可用，退回 CLI：\(fallback.map(\.rawValue).joined(separator: ","), privacy: .public)")
        let client = self.client
        Task.detached { [weak self] in
            do {
                let sessions = try client.sessions()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for (provider, active) in SessionPoller.states(for: fallback, from: sessions) {
                        self.schedule.sessionUpdate(provider: provider, active: active, at: Date(), config: self.config)
                    }
                }
            } catch {
                // 失败时保留上一次的状态，不当作 idle。
                await MainActor.run { [weak self] in
                    self?.logger.error("会话轮询失败：\(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }
}
