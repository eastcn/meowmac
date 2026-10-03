import AppKit
import Foundation
import MeowMacCore
import MeowMacQuota
import os

@MainActor
public final class QuotaCoordinator {
    private let client: CodexBarClient
    private let history: QuotaHistoryStore
    private let importSource: URL
    private let config: LocalConfig
    private let state: PanelState
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "quota-schedule")
    private var schedule = QuotaSchedule()
    private var refreshTimer: Timer?
    private var sessionTimer: Timer?
    private var lastPrunedAt: Date?
    private var refreshing = false
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []

    public init(state: PanelState, config: LocalConfig, history: QuotaHistoryStore = QuotaHistoryStore(),
                importSource: URL = CodexBarHistoryImport.defaultSource) {
        self.state = state; self.config = config; self.history = history; self.importSource = importSource
        self.client = CodexBarClient(path: config.codexBarCLIPath)
    }

    public func start() {
        state.showsCodexBarImport = !codexBarImportDone
        do { try history.prune(before: Date().addingTimeInterval(Double(-config.quotaHistoryDays) * 86400)); lastPrunedAt = Date() }
        catch { logger.error("额度历史清理失败：\(error.localizedDescription, privacy: .private)") }
        for provider in QuotaProvider.allCases {
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
            for provider in QuotaProvider.allCases {
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
        for provider in schedule.dueFinishRefresh(at: Date()) { refresh(provider) }
    }

    private func refreshAll() {
        guard !sleeping, !refreshing else { return }
        let now = Date()
        refreshing = true
        schedule.markFullRefresh(at: now)
        let client = self.client
        Task.detached { [weak self] in
            do {
                var snapshots: [QuotaProvider: QuotaSnapshot] = [:]
                var errors: [QuotaProvider: String] = [:]
                for provider in QuotaProvider.allCases {
                    do { snapshots[provider] = try client.usage(provider) }
                    catch {
                        errors[provider] = error.localizedDescription
                        await MainActor.run { [weak self] in self?.logger.error("额度采集失败：\(provider.rawValue, privacy: .public) \(error.localizedDescription, privacy: .private)") }
                    }
                }
                let result = (snapshots: snapshots, errors: errors)
                var costs: [QuotaProvider: [DailyCost]] = [:]
                for provider in [QuotaProvider.claude, .codex] {
                    do { costs[provider] = try client.cost(provider) }
                    catch { await MainActor.run { [weak self] in self?.logger.error("花费采集失败：\(provider.rawValue, privacy: .public) \(error.localizedDescription, privacy: .private)") } }
                }
                let costResults = costs
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.refreshing = false
                    for (provider, snapshot) in result.snapshots {
                        self.state.quotas[provider] = snapshot
                        self.state.quotaErrors.removeValue(forKey: provider)
                        self.state.failures["quota.\(provider.rawValue)"] = 0
                        do { try self.history.append(snapshot) }
                        catch { self.logger.error("额度历史写入失败：\(error.localizedDescription, privacy: .private)") }
                        do { self.state.quotaHistory[provider] = try self.history.read(provider) }
                        catch { self.logger.error("额度历史读取失败：\(error.localizedDescription, privacy: .private)") }
                    }
                    for (provider, error) in result.errors {
                        self.state.quotaErrors[provider] = error
                        self.state.failures["quota.\(provider.rawValue)", default: 0] += 1
                    }
                    self.state.costs.merge(costResults) { _, new in new }
                    self.state.failures["quota"] = result.snapshots.isEmpty ? (self.state.failures["quota"] ?? 0) + 1 : 0
                    self.state.lastRefreshedAt = Date()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.refreshing = false
                    self.state.failures["quota", default: 0] += 1
                    self.logger.error("额度刷新失败：\(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    private func refresh(_ provider: QuotaProvider) {
        let client = self.client
        Task.detached { [weak self] in
            do {
                let snapshot = try client.usage(provider)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.state.quotas[provider] = snapshot
                    self.state.quotaErrors.removeValue(forKey: provider)
                    self.state.failures["quota.\(provider.rawValue)"] = 0
                    do { try self.history.append(snapshot) }
                    catch { self.logger.error("额度历史写入失败：\(error.localizedDescription, privacy: .private)") }
                    do { self.state.quotaHistory[provider] = try self.history.read(provider) }
                    catch { self.logger.error("额度历史读取失败：\(error.localizedDescription, privacy: .private)") }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.state.quotaErrors[provider] = error.localizedDescription
                    self?.state.failures["quota.\(provider.rawValue)", default: 0] += 1
                    self?.logger.error("渠道刷新失败：\(provider.rawValue, privacy: .public) \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }

    private func pollSessions() {
        guard !sleeping else { return }
        let client = self.client
        Task.detached { [weak self] in
            do {
                let sessions = try client.sessions()
                await MainActor.run { [weak self] in
                    self?.schedule.sessionUpdate(sessions, at: Date(), config: self?.config ?? LocalConfig())
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.logger.error("会话轮询失败：\(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }
}
