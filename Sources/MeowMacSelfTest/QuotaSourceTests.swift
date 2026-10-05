import AppKit
import Foundation
import MeowMacCore
import MeowMacQuota
import MeowMacUI

@MainActor
enum QuotaSourceTests {
    nonisolated static let router = QuotaProvider(rawValue: "openrouter")!
    static let root = URL(fileURLWithPath: "build/acceptance/config-entries/source-tests")
    nonisolated static func fixture(_ provider: QuotaProvider = router) -> Data {
        Data("[{\"provider\":\"\(QuotaCatalog.usageNames[provider.rawValue]!)\",\"source\":\"api\",\"usage\":{\"primary\":{\"usedPercent\":91,\"windowMinutes\":300,\"resetsAt\":\"2026-10-05T06:00:00Z\"}}}]".utf8)
    }
    nonisolated static func wait(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 3) == .success }
    static func core() -> Bool {
        do {
            let source = QuotaSourceStore(root: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try source.save(QuotaSourceList(providers: [.codex, router]))
            guard source.load().list.providers == [.codex, router], source.load().recoveryReason == nil else { return false }
            try Data("{".utf8).write(to: source.file)
            guard source.load().list == QuotaSourceList(), source.load().recoveryReason != nil,
                  (try? source.save(QuotaSourceList())) == nil else { return false }
            guard (try? QuotaSourceList(providers: [QuotaProvider(rawValue: "unknown")!]).validated()) == nil else { return false }
            let catalog = try QuotaCatalog.providers(Data(#"[{"provider":"openrouter","displayName":"OpenRouter","enabled":true},{"provider":"unknown","displayName":"未知","enabled":true}]"#.utf8))
            let creds = try QuotaCatalog.credentialStatus(Data(#"{"providers":[{"id":"openrouter","apiKey":"[REDACTED]"},{"id":"openai"},{"id":"deepseek","tokenAccounts":[{"token":"[REDACTED]"}]}]}"#.utf8))
            guard catalog.count == 1, catalog[0].provider == router, catalog[0].supportsAPIKey,
                  creds[router] == true, creds[.deepseek] == true, creds[QuotaProvider(rawValue: "openai")!] == false,
                  QuotaCatalog.entry(.claude)?.supportsAPIKey == false,
                  QuotaCatalog.entry(.deepseek)?.supportsAPIKey == false else { return false }
            let alias = QuotaProvider(rawValue: "azureopenai")!
            guard try CodexBarParser.usage(fixture(alias), at: Date()).provider == alias else { return false }
            let missing = Data(#"[{"provider":"openrouter","usage":{"primary":{"windowMinutes":300}}}]"#.utf8)
            guard (try? CodexBarParser.usage(missing, at: Date())) == nil else { return false }
            var commands: [[String]] = []
            let client = CodexBarClient(path: "/synthetic/cli", environment: ["CODEXBAR_CONFIG": root.appendingPathComponent("cli.json").path], executor: { _, args, _, _ in commands.append(args); return CLIOutput(stdout: fixture(router)) })
            _ = try client.cost(router)
            let failing = CodexBarClient(path: "/synthetic/cli", environment: ["CODEXBAR_CONFIG": root.appendingPathComponent("cli.json").path], executor: { _, _, _, _ in CLIOutput(status: 1, stdout: Data(#"[{"error":{"kind":"args","message":"not supported"}}]"#.utf8)) })
            guard (try? failing.setEnabled(true, provider: router)) == nil else { return false }
            return commands.isEmpty && SessionPoller.providers == [.claude, .codex]
        } catch { print("额度渠道核心测试失败：\(error)"); return false }
    }
    static func display() -> Bool {
        do {
            let state = PanelPreviewRenderer.syntheticState()
            state.applyQuotaSources(QuotaSourceList(providers: state.quotaProviders + [router]))
            let snapshot = try CodexBarParser.usage(fixture(), at: state.now())
            state.quotas[router] = snapshot
            guard state.channelDisplay(router).provider == router, state.displayedWindows(router).count == 1,
                  state.allReminders.contains(where: { $0.provider == router && $0.kind == .quotaLow }),
                  QuotaPalette.color(router) != .systemGray else { return false }
            let notices = NotificationContent.notices(for: state.allReminders.filter { $0.provider == router }, now: state.now())
            guard notices.contains(where: { $0.body.contains("OpenRouter") }) else { return false }
            let history = QuotaHistoryStore(directory: root)
            defer { try? FileManager.default.removeItem(at: root) }
            try history.append(snapshot)
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("openrouter.jsonl").path), try history.read(router).count == 1 else { return false }
            try history.prune(before: Date.distantFuture)
            guard try history.read(router).isEmpty else { return false }
            var style = StyleSettings.default; style.colors[router.rawValue] = .purple
            return try StyleSettings.parse(JSONEncoder().encode(style)) == style
        } catch { print("通用渠道显示测试失败：\(error)"); return false }
    }
    static func empty() -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        state.applyQuotaSources(QuotaSourceList(providers: []))
        return state.quotaProviders.isEmpty && state.quotas.isEmpty && state.quotaHistory.isEmpty
            && state.overviewMetrics.first(where: { $0.item == .quota })?.value == "未添加"
            && !state.allReminders.contains(where: { $0.provider != nil })
            && state.quotaEmptyMessage == "还没有额度渠道，在 设置 → 额度源设置… 中添加"
    }
    static func selectionRemoval() -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        state.selectedProvider = .codex
        state.applyQuotaSources(QuotaSourceList(providers: [.deepseek, .opencodego]))
        return state.selectedProvider == .deepseek && state.quotas[.codex] == nil
    }
    static func overviewRemoval() -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        state.applyQuotaSources(QuotaSourceList(providers: [.codex]))
        return state.overviewMetrics.first(where: { $0.item == .quota })?.title == "Codex"
            && state.overviewMetrics.first(where: { $0.item == .quota })?.numericValue == 60
    }
    static func inFlightRemoval() async -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        let store = QuotaSourceStore(root: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let client = CodexBarClient(path: "/synthetic/cli", environment: ["CODEXBAR_CONFIG": root.appendingPathComponent("cli.json").path], executor: { _, _, _, _ in
            entered.signal(); release.wait(); return CLIOutput(stdout: fixture(router))
        })
        let coordinator = QuotaCoordinator(state: state, config: LocalConfig(), history: QuotaHistoryStore(directory: root.appendingPathComponent("history")), client: client, sourceStore: store)
        do {
            try coordinator.replaceSources(QuotaSourceList(providers: [router]))
            coordinator.requestRefresh([router])
            guard await Task.detached(operation: { wait(entered) }).value else { release.signal(); return false }
            try coordinator.replaceSources(QuotaSourceList(providers: []))
            release.signal()
            for _ in 0..<100 where coordinator.isRefreshing { try await Task.sleep(nanoseconds: 10_000_000) }
            guard !coordinator.isRefreshing else { return false }
            return state.quotas[router] == nil && state.quotaAttempts[router] == nil && state.quotaErrors[router] == nil
                && !FileManager.default.fileExists(atPath: root.appendingPathComponent("history/openrouter.jsonl").path)
                && state.allReminders.allSatisfy { $0.provider != router }
        } catch { release.signal(); return false }
    }
    static func previews() async -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MEOWMAC_CONFIG_RENDER_DIR"] else { return true }
        do {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let state = PanelPreviewRenderer.syntheticState(); state.selectedTab = .quota
            // 当前 CLI 目录有 OpenAI，安装包没有同名图标，走真实首字母回退。
            let noIcon = QuotaProvider(rawValue: "openai")!
            state.applyQuotaSources(QuotaSourceList(providers: state.quotaProviders + [router, noIcon]))
            state.selectedProvider = router
            state.quotas[router] = try CodexBarParser.usage(fixture(), at: state.now())
            let popover = NSPopover(); popover.behavior = .applicationDefined; popover.animates = false
            let host = PanelHosting.make(state: state)
            popover.contentViewController = host.controller
            let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
            let window = NSWindow(contentRect: NSRect(x: 400, y: 500, width: 120, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = anchor; window.orderFront(nil)
            defer { popover.close(); window.orderOut(nil) }
            for empty in [false, true] {
                if empty { state.applyQuotaSources(QuotaSourceList(providers: [])) }
                for dark in [false, true] {
                    popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.controller.view.appearance = popover.appearance
                    if !popover.isShown { popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY) }
                    let size = try await PanelPreviewRenderer.settleLayout(host.controller)
                    guard size.width == 360, size.height <= 820 else { return false }
                    guard let actualWindow = host.controller.view.window else { return false }
                    try await Task.sleep(nanoseconds: 100_000_000)
                    try ConfigPreviewCapture.capture(actualWindow, to: output.appendingPathComponent("quota-" + (empty ? "empty" : "six") + (dark ? "-dark.png" : "-light.png")))
                }
            }
            return true
        } catch { print("渠道真实面板预览失败：\(error)"); return false }
    }
}
