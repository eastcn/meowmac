import Foundation
import MeowMacCore
import MeowMacQuota
import MeowMacUI
import TunCanaryCore
import TunCanaryUI
import AppKit

@MainActor
enum QuotaProxyProtectionTests {
    static let root = URL(fileURLWithPath: "build/acceptance/quota-proxy-protection/tests", isDirectory: true)
    static func prepare(_ providers: [QuotaProvider], network: AppModel? = nil,
                        check: @escaping @Sendable () async -> QuotaProxyStatus) throws -> (PanelState, QuotaCoordinator, Calls) {
        let store = QuotaSourceStore(root: root)
        try store.save(QuotaSourceList(providers: providers))
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        state.networkModel = network
        let calls = Calls()
        let client = CodexBarClient(path: "/synthetic/cli", environment: ["CODEXBAR_CONFIG": root.appendingPathComponent("cli.json").path], executor: { _, args, _, _ in
            calls.add(args)
            if args.contains("providers") {
                return CLIOutput(stdout: Data(#"[{"provider":"codex","displayName":"Codex","enabled":true},{"provider":"claude","displayName":"Claude","enabled":true},{"provider":"openrouter","displayName":"OpenRouter","enabled":true}]"#.utf8))
            }
            return QuotaSourceSettingsTests.output(args)
        })
        let coordinator = QuotaCoordinator(state: state, config: LocalConfig(), history: QuotaHistoryStore(directory: root.appendingPathComponent("history")),
            importSource: root.appendingPathComponent("import"), scanner: AgentActivityScanner(home: root), client: client, sourceStore: store, proxyCheck: check)
        return (state, coordinator, calls)
    }
    static func statuses() -> Bool {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard var local = PanelPreviewRenderer.networkModel(failure: false, now: now).local else { return false }
        guard QuotaProxyProtection.status(nil, at: now) == .checking,
              QuotaProxyProtection.status(local, at: now) == .ready else { return false }
        for (tun, expected) in [(TunState.off, QuotaProxyStatus.off), (.inactive, .inactive), (.unknown, .unknown)] {
            local.tunState = tun
            guard QuotaProxyProtection.status(local, at: now) == expected else { return false }
        }
        local.tunState = .running(interface: "示例隧道")
        guard QuotaProxyProtection.status(local, at: now.addingTimeInterval(31)) == .stale,
              QuotaProxyProtection.status(local, at: now.addingTimeInterval(-1)) == .stale else { return false }
        local.isInGracePeriod = true
        let config = QuotaProxyProtection.localConfiguration(paths: KnownPaths(homeDirectory: root.path), source: ProxySource())
        return QuotaProxyProtection.status(local, at: now) == .switching
            && !config.resolvesCanary && !config.probesMihomoDNS && config.dnsGuardPaths == nil
    }

    static func blockedStates() async -> Bool {
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            for status in [QuotaProxyStatus.checking, .off, .inactive, .unknown, .switching, .stale] {
                let (state, coordinator, calls) = try prepare([.codex, .claude], check: { status })
                state.quotaProxyStatus = .ready // 旧绿灯不能覆盖本次检查。
                coordinator.requestRefresh([.codex, .claude])
                guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage.isEmpty,
                      coordinator.lastActualCalls.isEmpty, state.quotaAttempts.isEmpty,
                      state.quotaErrors.isEmpty, state.quotaProxyStatus == status else { return false }
            }
            return true
        } catch { return false }
    }

    static func otherProvidersAndCache() async -> Bool {
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let router = QuotaSourceTests.router
            let (state, coordinator, calls) = try prepare([.codex, .claude, router], check: { .inactive })
            let cached = try CodexBarParser.usage(QuotaSourceTests.fixture(.claude), at: state.now().addingTimeInterval(-600))
            state.quotas[.claude] = cached
            var config = state.configResult.config
            config.alertRules.builtin[BuiltinAlertRule.network.id] = AlertRuleOverride(enabled: false)
            config.alertRules.builtin[BuiltinAlertRule.source.id] = AlertRuleOverride(enabled: false)
            state.configResult = ConfigLoadResult(config: config, error: nil)
            coordinator.requestRefresh([.codex, .claude, router])
            guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage == ["openrouter"],
                  state.quotas[.claude]?.updatedAt == cached.updatedAt, state.quotaAttempts[.claude] == nil,
                  state.failures["quota.claude"] == nil, state.quotas[router] != nil,
                  state.quotaPauseMessage(.claude)?.contains("当前显示缓存") == true,
                  state.quotaPauseMessage(router) == nil, state.quotaProxyWarning != nil else { return false }
            return !FileManager.default.fileExists(atPath: root.appendingPathComponent("history/claude.jsonl").path)
        } catch { return false }
    }

    static func recoveryAndCooldown() async -> Bool {
        defer { try? FileManager.default.removeItem(at: root) }
        let control = Control(.off)
        do {
            let (state, coordinator, calls) = try prepare([.claude, .codex], check: { await control.check() })
            var now = Date(timeIntervalSince1970: 1_800_000_000)
            state.now = { now }
            coordinator.requestRefresh([.claude, .codex])
            guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage.isEmpty else { return false }
            coordinator.requestRefresh([.claude, .codex]); coordinator.manualRefresh()
            guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage.isEmpty else { return false }
            await control.set(.ready)
            coordinator.proxyEvidenceChanged(.ready)
            guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage == ["claude", "codex"],
                  coordinator.lastActualCalls.count == 2 else { return false }
            coordinator.proxyEvidenceChanged(.ready)
            guard !coordinator.isRefreshing, calls.usage.count == 2 else { return false }
            now = now.addingTimeInterval(60)
            coordinator.requestRefresh([.claude, .codex])
            guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage == ["claude", "codex", "codex"],
                  coordinator.test(.claude).contains("240 秒") else { return false }
            now = now.addingTimeInterval(240); coordinator.drain()
            return await QuotaSourceSettingsTests.wait(coordinator) && calls.usage == ["claude", "codex", "codex", "claude"]
        } catch { return false }
    }

    static func startupAndTest() async -> Bool {
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let (state, coordinator, calls) = try prepare([.codex, .claude, QuotaSourceTests.router], check: { .unknown })
            coordinator.start(); defer { coordinator.stop() }
            guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage == ["openrouter"],
                  coordinator.lastActualCalls[.claude] == nil else { print("启动拦截结果不符：\(calls.values)，\(state.quotaErrors)"); return false }
            coordinator.sourceEnabled[.claude] = false
            _ = coordinator.test(.claude)
            guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage == ["openrouter"],
                  state.quotaAttempts[.claude] == nil else { print("停用渠道测试拦截不符：\(calls.values)"); return false }
            coordinator.manualRefresh()
            return await QuotaSourceSettingsTests.wait(coordinator) && calls.usage == ["openrouter"]
        } catch { return false }
    }

    static func changedDuringCheck(_ mode: Int) async -> Bool {
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        do {
            let (state, coordinator, calls) = try prepare([.claude], check: { await gate.check() })
            coordinator.requestRefresh([.claude])
            for _ in 0..<100 {
                if await gate.entered { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard await gate.entered else { await gate.release(); return false }
            switch mode {
            case 0: coordinator.proxyEvidenceChanged(.inactive)
            case 1: try coordinator.replaceSources(QuotaSourceList(providers: []))
            case 2: coordinator.sourceEnabled[.claude] = false
            default: coordinator.stop()
            }
            await gate.release()
            return await QuotaSourceSettingsTests.wait(coordinator) && calls.usage.isEmpty
                && coordinator.lastActualCalls.isEmpty && state.quotaAttempts.isEmpty
        } catch { await gate.release(); return false }
    }

    static func sleepAndNetworkSwitch() async -> Bool {
        defer { try? FileManager.default.removeItem(at: root) }
        let control = Control(.ready)
        do {
            let model = PanelPreviewRenderer.networkModel(failure: false, now: Date())
            let (state, coordinator, calls) = try prepare([.claude], network: model, check: { await control.check() })
            var now = Date()
            state.now = { now }
            coordinator.start(); defer { coordinator.stop() }
            guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage == ["claude"] else { return false }
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            try await Task.sleep(nanoseconds: 30_000_000)
            now = now.addingTimeInterval(400)
            coordinator.requestRefresh([.claude])
            guard !coordinator.isRefreshing, calls.usage.count == 1 else { return false }
            await control.set(.off)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await Task.sleep(nanoseconds: 30_000_000)
            guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage.count == 1,
                  state.quotaProxyStatus == .off else { return false }
            await control.set(.ready)
            var local = model.local!
            local.evaluatedAt = Date(); model.local = local
            guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage.count == 2 else { return false }
            model.graceEndsAt = Date().addingTimeInterval(30)
            now = now.addingTimeInterval(400)
            coordinator.requestRefresh([.claude])
            guard await QuotaSourceSettingsTests.wait(coordinator), calls.usage.count == 2,
                  state.quotaProxyStatus == .switching else { return false }
            model.graceEndsAt = nil
            local.evaluatedAt = Date(); model.local = local
            return await QuotaSourceSettingsTests.wait(coordinator) && calls.usage.count == 3
        } catch { print("休眠或网络切换回归失败：\(error)"); return false }
    }

    static func display() -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        state.quotaProxyStatus = .off
        let message = state.quotaProxyWarning
        guard message?.contains("严重") != true, message?.contains("Clash TUN 未开启") == true,
              state.quotaPauseMessage(.claude)?.contains("最后成功") == true else { return false }
        state.quotaProxyStatus = .ready
        return state.quotaProxyWarning == nil && state.quotaPauseMessage(.claude) == nil
    }

    static func snapshotAndPreviews() async -> Bool {
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let (state, coordinator, calls) = try prepare([.codex, .claude, QuotaSourceTests.router], check: { .inactive })
            state.networkModel = PanelPreviewRenderer.networkModel(failure: false, now: state.now())
            await SnapshotCollector.collectQuotas(state: state, client: coordinator.client,
                history: QuotaHistoryStore(directory: root.appendingPathComponent("history")), proxyCheck: { .off })
            guard calls.usage == ["openrouter"], state.quotaErrors[.claude] == nil,
                  state.quotaAttempts[.claude] == nil, state.quotas[.claude] == nil,
                  PanelSnapshot(state: state).network?.quotaProtectionWarning != nil,
                  state.channelDisplay(.claude).pauseMessage != nil else { return false }
            let output = URL(fileURLWithPath: "build/acceptance/quota-proxy-protection/previews", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let preview = PanelPreviewRenderer.syntheticState()
            preview.quotaProxyStatus = .inactive
            for dark in [false, true] {
                for tab in [PanelTab.network, .quota] {
                    preview.selectedTab = tab
                    guard let data = PanelPreviewRenderer.png(state: preview, dark: dark),
                          let image = NSBitmapImageRep(data: data), image.pixelsWide == 720, image.pixelsHigh > 0 else { return false }
                    try data.write(to: output.appendingPathComponent(tab.rawValue + (dark ? "-dark.png" : "-light.png")))
                }
            }
            return true
        } catch { print("额度保护快照或预览失败：\(error)"); return false }
    }
    static func missingEvidence() async -> Bool {
        let root = URL(fileURLWithPath: "build/acceptance/quota-proxy-protection/missing", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = QuotaSourceStore(root: root)
        do { try store.save(QuotaSourceList(providers: [.codex, .claude])) } catch { return false }
        let state = PanelState(configResult: ConfigLoadResult(config: LocalConfig(), error: nil))
        let calls = Calls()
        let client = CodexBarClient(path: "/synthetic/cli", environment: ["CODEXBAR_CONFIG": root.appendingPathComponent("cli.json").path], executor: { _, args, _, _ in
            calls.add(args)
            return QuotaSourceSettingsTests.output(args)
        })
        let coordinator = QuotaCoordinator(state: state, config: LocalConfig(), history: QuotaHistoryStore(directory: root.appendingPathComponent("history")), client: client, sourceStore: store, proxyCheck: { .unknown })
        coordinator.requestRefresh([.codex, .claude])
        _ = await QuotaSourceSettingsTests.wait(coordinator)
        let usage = calls.values.filter { $0.first == "usage" }
        if !usage.isEmpty { print("缺少代理证据时仍启动了额度查询：\(usage.count) 次") }
        return usage.isEmpty && coordinator.lastActualCalls.isEmpty && state.quotaAttempts.isEmpty
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [[String]] = []
        func add(_ command: [String]) { lock.lock(); defer { lock.unlock() }; commands.append(command) }
        var values: [[String]] { lock.lock(); defer { lock.unlock() }; return commands }
        var usage: [String] { values.filter { $0.first == "usage" }.map { $0[2] } }
    }
    actor Control {
        private var status: QuotaProxyStatus
        init(_ status: QuotaProxyStatus) { self.status = status }
        func set(_ status: QuotaProxyStatus) { self.status = status }
        func check() -> QuotaProxyStatus { status }
    }
    actor Gate {
        var entered = false
        private var continuation: CheckedContinuation<QuotaProxyStatus, Never>?
        func check() async -> QuotaProxyStatus {
            entered = true
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(returning: .ready); continuation = nil }
    }
}
