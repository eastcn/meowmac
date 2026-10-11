import AppKit
import Foundation
import Combine
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
    private var starting = false
    private var startupTask: Task<Void, Never>?
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []
    private let proxyCheck: @Sendable () async -> QuotaProxyStatus
    private var proxySubscriptions = Set<AnyCancellable>()
    private var proxyGeneration = 0

    public init(state: PanelState, config: LocalConfig, history: QuotaHistoryStore = QuotaHistoryStore(),
                importSource: URL = CodexBarHistoryImport.defaultSource, scanner: AgentActivityScanner = AgentActivityScanner(),
                client: CodexBarClient? = nil, sourceStore: QuotaSourceStore = QuotaSourceStore(),
                proxyCheck: @escaping @Sendable () async -> QuotaProxyStatus = { await QuotaProxyProtection.check() }) {
        self.state = state; self.config = config; self.history = history; self.importSource = importSource
        self.scanner = scanner
        self.client = client ?? CodexBarClient(path: config.codexBarCLIPath)
        self.sourceStore = sourceStore
        self.proxyCheck = proxyCheck
        let loaded = sourceStore.load()
        state.applyQuotaSources(loaded.list); state.quotaSourceRecoveryReason = loaded.recoveryReason
        if let model = state.networkModel {
            model.$local.sink { [weak self] local in
                self?.proxyEvidenceChanged(QuotaProxyProtection.status(local, at: Date()))
            }.store(in: &proxySubscriptions)
            model.$graceEndsAt.sink { [weak self] end in
                guard let self else { return }
                self.proxyGeneration += 1
                if end != nil { self.setProxyStatus(.switching) }
            }.store(in: &proxySubscriptions)
        }
    }

    public func start() {
        guard startupTask == nil else { return }
        sleeping = false
        starting = true
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
            Task { @MainActor [weak self] in
                self?.sleeping = true; self?.schedule.sleep()
                self?.proxyEvidenceChanged(.checking)
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sleeping = false
                self.proxyEvidenceChanged(.checking)
                self.drain()
                if self.schedule.wake(at: Date(), config: self.config) { self.refreshAll() }
            }
        })
        let client = self.client
        startupTask = Task { [weak self] in
            let result = await Task.detached { Result { try client.providers() } }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let entries):
                self.sourceEnabled = Dictionary(entries.map { ($0.provider, $0.enabled) }, uniquingKeysWith: { _, new in new })
                for provider in self.state.quotaProviders where self.sourceEnabled[provider] == nil { self.sourceEnabled[provider] = false }
            case .failure:
                self.sourceEnabled = Dictionary(uniqueKeysWithValues: self.state.quotaProviders.map { ($0, false) })
                for provider in self.state.quotaProviders {
                    self.state.quotaErrors[provider] = "无法读取渠道启停状态。请打开额度源设置重试，再手动刷新。"
                }
                self.logger.error("启动时读取渠道启停状态失败，未自动采集额度")
            }
            self.starting = false
            self.refreshAll()
            self.pollSessions()
        }
    }

    public func stop() {
        proxyGeneration += 1
        sleeping = true
        startupTask?.cancel(); startupTask = nil; starting = false
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

    public var isRefreshing: Bool { refreshing || starting }
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

    public func replaceSources(_ requested: QuotaSourceList) throws {
        let list = state.sourcesWithWindowFallbacks(requested)
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
        guard !sleeping, !refreshing, !starting else { return }
        guard let provider = state.quotaProviders.first(where: { (pending[$0].map { $0 <= state.now() } ?? false) && (sourceEnabled[$0] != false || explicitRequests.contains($0)) }) else { return }
        let remaining = cooldownRemaining(provider)
        if remaining > 0 { pending[provider] = state.now().addingTimeInterval(remaining); return }
        refreshing = true
        let generation = generations[provider, default: 0]
        let client = self.client
        Task { [weak self] in
            guard let self else { return }
            if QuotaProxyProtection.protects(provider) {
                let version = self.proxyGeneration
                let status = await self.proxyCheck()
                let switched = self.state.networkModel?.graceEndsAt != nil
                let current: QuotaProxyStatus
                if switched { current = .switching }
                else if version != self.proxyGeneration { current = self.state.quotaProxyStatus == .ready ? .checking : self.state.quotaProxyStatus }
                else { current = status }
                self.setProxyStatus(current)
                guard current == .ready else {
                    self.logger.warning("额度查询前代理检查阻断：\(provider.rawValue, privacy: .public)，\(current.reason ?? "状态未确认", privacy: .public)")
                    // 保留每个渠道的一次请求，暂缓重查，继续处理其他渠道。
                    for item in Array(self.pending.keys) where QuotaProxyProtection.protects(item) {
                        self.pending[item] = self.state.now().addingTimeInterval(max(30, self.cooldownRemaining(item)))
                    }
                    self.refreshing = false
                    self.drain()
                    return
                }
            }
            // 检查期间可能休眠、停用或移除渠道；此时不能启动 CLI。
            guard !self.sleeping, self.state.quotaProviders.contains(provider),
                  self.generations[provider, default: 0] == generation,
                  self.sourceEnabled[provider] != false || self.explicitRequests.contains(provider) else {
                self.refreshing = false; self.drain(); return
            }
            self.pending.removeValue(forKey: provider)
            self.explicitRequests.remove(provider)
            if QuotaProxyProtection.protects(provider) {
                self.logger.info("额度查询前代理检查放行：\(provider.rawValue, privacy: .public)，Clash 核心和 TUN 正常")
            }
            self.lastActualCalls[provider] = self.state.now()
            let result = await Task.detached { () -> Result<QuotaSnapshot, Error> in
                Result { try client.usage(provider) }
            }.value
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

    /// 网络检测结果用于立即展示及恢复排队；真正放行仍需调用前重新采集。
    public func proxyEvidenceChanged(_ status: QuotaProxyStatus) {
        if status != .ready { proxyGeneration += 1 }
        let wasBlocked = state.quotaProxyStatus != .ready
        setProxyStatus(status)
        if status == .ready && wasBlocked {
            for provider in Array(pending.keys) where QuotaProxyProtection.protects(provider) {
                pending[provider] = state.now().addingTimeInterval(cooldownRemaining(provider))
            }
            drain()
        }
    }

    private func setProxyStatus(_ status: QuotaProxyStatus) {
        guard state.quotaProxyStatus != status else { return }
        state.quotaProxyStatus = status
        if let reason = status.reason { logger.warning("额度代理保护：\(reason, privacy: .public)，暂停 GPT/Codex 和 Claude 查询") }
        else { logger.info("额度代理保护：TUN 已就绪") }
    }

    private func apply(_ result: Result<QuotaSnapshot, Error>, provider: QuotaProvider) {
        let now = state.now()
        switch result {
        case .success(let snapshot):
            state.quotas[provider] = snapshot
            state.quotaErrors.removeValue(forKey: provider)
            state.failures["quota." + provider.rawValue] = 0
            state.quotaAttempts[provider] = QuotaAttempt(at: now, success: true, message: "采集成功")
            logger.info("额度采集成功：\(provider.rawValue, privacy: .public)")
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
