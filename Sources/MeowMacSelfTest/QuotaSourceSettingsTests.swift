import AppKit
import Foundation
import MeowMacCore
import MeowMacQuota
import MeowMacUI

@MainActor
enum QuotaSourceSettingsTests {
    static let root = URL(fileURLWithPath: "build/acceptance/config-entries/settings-tests")
    static let environment = ["CODEXBAR_CONFIG": root.appendingPathComponent("cli.json").path]
    static let all = QuotaCatalog.usageNames.keys.sorted().compactMap { QuotaCatalog.entry(QuotaProvider(rawValue: $0)!) }
    static func prepare(executor: @escaping CodexBarClient.Executor) throws -> (PanelState, QuotaCoordinator, QuotaSourceSettingsModel, SettingsWindowController) {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        let state = PanelPreviewRenderer.syntheticState()
        let client = CodexBarClient(path: "/synthetic/cli", environment: environment, executor: executor)
        let coordinator = QuotaCoordinator(state: state, config: LocalConfig(), history: QuotaHistoryStore(directory: root.appendingPathComponent("history")), client: client, sourceStore: QuotaSourceStore(root: root), proxyCheck: { .ready })
        let controller = SettingsWindowController(state: state, quotaCoordinator: coordinator, quotaCatalog: all)
        controller.open(section: .quotaSources, load: false)
        guard let model = controller.quotaSources else { throw QuotaSourceError.invalid }
        return (state, coordinator, model, controller)
    }
    nonisolated static func output(_ args: [String]) -> CLIOutput {
        if args.first == "cost" { return CLIOutput(stdout: Data(#"[{"daily":[]}]"#.utf8)) }
        let name = args.count > 2 ? args[2] : "openrouter"
        let provider = QuotaCatalog.provider(forUsageName: name) ?? QuotaSourceTests.router
        return CLIOutput(stdout: QuotaSourceTests.fixture(provider))
    }
    static func wait(_ coordinator: QuotaCoordinator) async -> Bool {
        for _ in 0..<100 where coordinator.isRefreshing { try? await Task.sleep(nanoseconds: 10_000_000) }
        return !coordinator.isRefreshing
    }
    static func commands() async -> Bool {
        do {
            var calls: [([String], Data?)] = []; var leaks = 0
            let secret = UUID().uuidString
            let (state, coordinator, model, controller) = try prepare { _, args, env, input in
                guard env["CODEXBAR_CONFIG"]?.contains("/meowmac/build/") == true else { throw QuotaSourceError.invalid }
                calls.append((args, input)); return output(args)
            }
            defer { controller.closeWithoutConfirmation(); try? FileManager.default.removeItem(at: root) }
            let provider = QuotaSourceTests.router
            model.add(provider); model.setKey(secret, provider: provider)
            guard model.rowDirty(provider), !model.canTest(provider) else { return false }
            model.setEnabled(false, provider: .codex)
            guard await model.save(), !model.isDirty else { return false }
            _ = await wait(coordinator)
            let writes = calls.filter { $0.0.first == "config" }.map(\.0)
            guard writes == [["config", "disable", "--provider", "codex", "--json"],
                             ["config", "set-api-key", "--provider", "openrouter", "--stdin", "--no-enable", "--json"],
                             ["config", "enable", "--provider", "openrouter", "--json"]],
                  calls.first(where: { $0.0.contains("set-api-key") })?.1 == Data((secret + "\n").utf8),
                  !calls.flatMap(\.0).contains(where: { $0.contains(secret) }), model.key(provider).isEmpty,
                  state.quotaProviders.contains(provider), model.canTest(provider) else { return false }
            let rawClient = CodexBarClient(path: "/synthetic/cli", environment: environment, executor: { _, _, _, _ in CLIOutput(stdout: Data(secret.utf8), stderr: Data(secret.utf8)) }, rawOutput: { _, _, _ in leaks += 1 })
            try rawClient.setAPIKey(secret, provider: provider)
            let before = calls.count
            model.remove(provider)
            guard await model.save() else { return false }
            guard calls.count == before, !state.quotaProviders.contains(provider), leaks == 0 else { return false }
            model.setEnabled(true, provider: .codex)
            guard model.isDirty else { return false }
            model.discard()
            return !model.isDirty && model.draft == model.saved
                && model.draft.first(where: { $0.provider == .codex })?.enabled == false
                && controller.window != nil
        } catch { print("额度设置命令测试失败：\(error)"); return false }
    }
    static func partialFailure() async -> Bool {
        do {
            let (_, coordinator, model, controller) = try prepare { _, args, _, _ in
                if args.contains("openrouter"), args.first == "config" { return CLIOutput(status: 1) }
                return output(args)
            }
            defer { controller.closeWithoutConfirmation(); try? FileManager.default.removeItem(at: root) }
            model.add(QuotaSourceTests.router)
            model.setEnabled(false, provider: .codex)
            guard !(await model.save()) else { return false }
            guard model.saved.first(where: { $0.provider == .codex })?.enabled == false,
                  model.saved.allSatisfy({ $0.provider != QuotaSourceTests.router }),
                  model.draft.contains(where: { $0.provider == QuotaSourceTests.router }),
                  model.errors[QuotaSourceTests.router] != nil, model.isDirty,
                  coordinator.sourceEnabled[.codex] == false else { return false }
            model.discard()
            return !model.isDirty && model.errors.isEmpty && model.draft == model.saved
                && model.draft.first(where: { $0.provider == .codex })?.enabled == false
        } catch { return false }
    }
    static func disabledRestart() async -> Bool {
        do {
            var enabled = true, usages: [String] = [], events: [String] = []
            let (state, first, _, controller) = try prepare { _, args, _, _ in
                if args.contains("disable") { enabled = false }
                if args.contains("providers") {
                    events.append("providers")
                    return CLIOutput(stdout: Data("[{\"provider\":\"claude\",\"displayName\":\"Claude\",\"enabled\":\(enabled)},{\"provider\":\"openrouter\",\"displayName\":\"OpenRouter\",\"enabled\":true}]".utf8))
                }
                if args.first == "usage" { usages.append(args[2]); events.append("usage") }
                return output(args)
            }
            defer { controller.closeWithoutConfirmation(); try? FileManager.default.removeItem(at: root) }
            try first.replaceSources(QuotaSourceList(providers: [.claude, QuotaSourceTests.router]))
            controller.closeWithoutConfirmation()
            let settings = SettingsWindowController(state: state, quotaCoordinator: first, quotaCatalog: all)
            settings.open(section: .quotaSources, load: false)
            defer { settings.closeWithoutConfirmation() }
            guard let model = settings.quotaSources else { return false }
            model.setEnabled(false, provider: .claude); await model.save()
            guard await wait(first), !enabled else { return false }
            usages = []; events = []
            let restarted = QuotaCoordinator(state: PanelState(), config: LocalConfig(), history: QuotaHistoryStore(directory: root.appendingPathComponent("history")), client: first.client, sourceStore: first.sourceStore, proxyCheck: { .ready })
            restarted.start(); defer { restarted.stop() }
            guard await wait(restarted) else { return false }
            return restarted.sourceEnabled[.claude] == false && usages == ["openrouter"] && events.first == "providers"
        } catch { return false }
    }
    static func startupStatusFailure() async -> Bool {
        do {
            var calls = 0
            let (_, first, _, controller) = try prepare { _, args, _, _ in
                if args.contains("providers") { return CLIOutput(status: 1) }
                if args.first == "usage" { calls += 1 }
                return output(args)
            }
            defer { controller.closeWithoutConfirmation(); try? FileManager.default.removeItem(at: root) }
            try first.replaceSources(QuotaSourceList(providers: [QuotaSourceTests.router]))
            let state = PanelState()
            let restarted = QuotaCoordinator(state: state, config: LocalConfig(), history: QuotaHistoryStore(directory: root.appendingPathComponent("history")), client: first.client, sourceStore: first.sourceStore, proxyCheck: { .ready })
            restarted.start(); defer { restarted.stop() }
            return await wait(restarted) && calls == 0 && restarted.lastActualCalls.isEmpty
                && state.quotaErrors[QuotaSourceTests.router]?.contains("启停状态") == true
        } catch { return false }
    }
    static func throttles(_ mode: Int) async -> Bool {
        do {
            var now = Date(timeIntervalSince1970: 1_000_000), claudeCalls = 0
            let (state, coordinator, model, controller) = try prepare { _, args, _, _ in
                if args.first == "usage", args.contains("claude") { claudeCalls += 1 }
                return output(args)
            }
            state.now = { now }
            defer { controller.closeWithoutConfirmation(); try? FileManager.default.removeItem(at: root) }
            if mode == 0 {
                coordinator.requestRefresh([.claude]); guard await wait(coordinator), claudeCalls == 1 else { return false }
                now = now.addingTimeInterval(60); model.test(.claude)
                return claudeCalls == 1 && model.testing[.claude]?.contains("240 秒") == true
            }
            if mode == 1 {
                model.setEnabled(false, provider: .claude); await model.save()
                guard await wait(coordinator), claudeCalls == 1 else { return false }
                model.test(.claude)
                return claudeCalls == 1 && model.testing[.claude]?.contains("300 秒") == true
            }
            model.test(.claude); guard await wait(coordinator), claudeCalls == 1 else { return false }
            now = now.addingTimeInterval(120)
            model.setEnabled(false, provider: .claude); await model.save()
            guard claudeCalls == 1, model.statusText.contains("180 秒") else { return false }
            now = now.addingTimeInterval(180); coordinator.drain()
            return await wait(coordinator) && claudeCalls == 2
        } catch { print("Claude 限频测试失败：\(error)"); return false }
    }
    static func credentials() async -> Bool {
        do {
            let (state, _, model, controller) = try prepare { _, args, _, _ in
                if args.contains("providers") {
                    return CLIOutput(stdout: Data(#"[{"provider":"opencodego","displayName":"OpenCode Go","enabled":true},{"provider":"openrouter","displayName":"OpenRouter","enabled":true}]"#.utf8))
                }
                return CLIOutput(stdout: Data(#"{"providers":[{"id":"opencodego","apiKey":"[REDACTED]"},{"id":"openrouter"}]}"#.utf8))
            }
            defer { controller.closeWithoutConfirmation(); try? FileManager.default.removeItem(at: root) }
            await model.load()
            guard model.credentialText(.opencodego) == "已配置" else { return false }
            state.quotaAttempts[.opencodego] = QuotaAttempt(at: state.now(), success: true, message: "成功")
            guard model.collectionText(.opencodego).contains("采集成功") else { return false }
            state.quotaAttempts[.opencodego] = QuotaAttempt(at: state.now(), success: false, message: "合成失败")
            guard model.collectionText(.opencodego).contains("采集失败"), model.credentialText(.opencodego) == "已配置",
                  model.credentialText(QuotaSourceTests.router) == "未配置",
                  model.collectionText(QuotaSourceTests.router) == "尚未采集",
                  model.credentialText(.claude) == "登录凭据由 CodexBar 管理", !model.canEditKey(.claude) else { return false }
            return true
        } catch { return false }
    }
    static func liveConfig() async -> Bool {
        let directory = URL(fileURLWithPath: "build/acceptance/config-entries/live-config-" + UUID().uuidString)
        let file = directory.appendingPathComponent("cli.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let client = CodexBarClient(path: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI", environment: ["CODEXBAR_CONFIG": file.path])
            let store = QuotaSourceStore(root: directory)
            let provider = QuotaSourceTests.router
            // 假 key 在内存中生成，只让 CLI 写入此临时配置；不打印、不提交。
            try client.setAPIKey(UUID().uuidString, provider: provider)
            try client.setEnabled(true, provider: provider)
            try store.save(QuotaSourceList(providers: [provider]))
            guard try client.providers().first(where: { $0.provider == provider })?.enabled == true,
                  try client.configStatus()[provider] == true else { return false }
            try client.setEnabled(false, provider: provider)
            try store.save(QuotaSourceList(providers: []))
            guard try client.providers().first(where: { $0.provider == provider })?.enabled == false,
                  try client.configStatus()[provider] == true, store.load().list.providers.isEmpty else { return false }
            return true
        } catch { print("临时 CodexBar 配置集成失败：\(error)"); return false }
    }
    /// 余额提醒阈值：只写本机清单，不调用 CLI 写命令，不触发刷新；非法值不能保存。
    static func balanceWarn() async -> Bool {
        do {
            var calls: [[String]] = []
            let (state, coordinator, model, controller) = try prepare { _, args, _, _ in calls.append(args); return output(args) }
            defer { controller.closeWithoutConfirmation(); try? FileManager.default.removeItem(at: root) }
            guard model.showsBalanceWarn(.deepseek), !model.showsBalanceWarn(.claude), model.balanceWarnText(.deepseek) == "10",
                  model.balanceCurrency(.deepseek) == "¥" else { print("阈值初始显示不符"); return false }
            model.setBalanceWarn("abc", provider: .deepseek)
            guard model.isDirty, model.hasInvalidBalanceWarn, !model.canSave else { print("非法阈值仍可保存"); return false }
            model.setBalanceWarn("25", provider: .deepseek)
            guard model.canSave else { return false }
            _ = await model.save(); _ = await wait(coordinator)
            guard state.quotaSources.balanceThreshold(.deepseek) == 25, !model.isDirty,
                  !calls.contains(where: { $0.first == "config" || $0.first == "usage" }) else { print("阈值保存调用了 CLI 或未写入：\(calls)"); return false }
            let stored = QuotaSourceStore(root: root).load().list
            guard stored.balanceThreshold(.deepseek) == 25 else { print("阈值未落盘"); return false }
            model.setBalanceWarn("", provider: .deepseek); _ = await model.save()
            guard state.quotaSources.balanceThreshold(.deepseek) == 0, model.balanceWarnText(.deepseek).isEmpty else { print("清空后未关闭提醒"); return false }
            // 其他保存（停用渠道）不得把阈值冲回默认值。
            model.setEnabled(false, provider: .codex); _ = await model.save(); _ = await wait(coordinator)
            return state.quotaSources.balanceThreshold(.deepseek) == 0
        } catch { print("余额阈值测试失败：\(error)"); return false }
    }
    /// 用户反馈：移除 DeepSeek 并保存后，“添加渠道…”点不动；列表里还有已添加的渠道；不能搜索。
    static func addAfterRemoveAndSearch() async -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: all.map { ["provider": $0.id, "displayName": $0.displayName, "enabled": true] as [String: Any] })
            let (state, coordinator, model, controller) = try prepare { _, args, _, _ in
                if args.contains("providers") { return CLIOutput(stdout: data) }
                if args.contains("dump") { return CLIOutput(stdout: Data(#"{"providers":[]}"#.utf8)) }
                return output(args)
            }
            defer { controller.closeWithoutConfirmation(); try? FileManager.default.removeItem(at: root) }
            guard let window = controller.window else { return false }
            await model.load()
            let added = Set(model.draft.map(\.provider))
            guard !model.available.contains(where: { added.contains($0.provider) }) else { print("可添加列表含已添加渠道"); return false }
            model.remove(.deepseek); await model.save(); _ = await wait(coordinator)
            SettingsControlTestSupport.settle(window)
            // SwiftUI 按钮不在测试进程的辅助功能树里，窗口内点击由用户实机确认；这里断言按钮依赖的状态。
            guard !model.busy, !model.isDirty, !state.quotaProviders.contains(.deepseek),
                  model.available.contains(where: { $0.provider == .deepseek }) else { print("保存后 DeepSeek 未回到可添加列表"); return false }
            model.add(.deepseek)
            guard model.draft.contains(where: { $0.provider == .deepseek }), !model.available.contains(where: { $0.provider == .deepseek }) else { print("再次添加 DeepSeek 失败或仍可重复添加"); return false }
            model.add(.deepseek)
            guard model.draft.filter({ $0.provider == .deepseek }).count == 1 else { print("同一渠道被添加两次"); return false }
            // DeepSeek 已在草稿里，搜 deep 只剩其他同名前缀的渠道。
            guard !model.available(matching: "deep").isEmpty, !model.available(matching: "deep").contains(where: { $0.provider == .deepseek }),
                  model.available(matching: "OPENR").map(\.provider) == [QuotaSourceTests.router],
                  model.available(matching: "  ").count == model.available.count,
                  model.available(matching: "不存在的渠道").isEmpty else { print("搜索结果不符"); return false }
            model.cancel()
            return true
        } catch { print("添加渠道回归测试失败：\(error)"); return false }
    }
    static func controlsAndPreviews() async -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: all.map { ["provider": $0.id, "displayName": $0.displayName, "enabled": true] as [String: Any] })
            let (state, _, model, controller) = try prepare { _, args, _, _ in
                if args.contains("providers") { return CLIOutput(stdout: data) }
                if args.contains("dump") { return CLIOutput(stdout: Data(#"{"providers":[]}"#.utf8)) }
                if args.contains("openrouter"), args.first == "config" { return CLIOutput(status: 1) }
                return output(args)
            }
            defer { controller.closeWithoutConfirmation(); try? FileManager.default.removeItem(at: root) }
            guard let window = controller.window else { return false }
            await model.load()
            controller.open(section: .quotaSources, load: false)
            guard controller.window === window else { return false }
            func capture(_ name: String) throws {
                guard let path = ProcessInfo.processInfo.environment["MEOWMAC_CONFIG_RENDER_DIR"] else { return }
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for dark in [false, true] {
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    SettingsControlTestSupport.settle(window)
                    // 原生普通背景，缓存图走实际 NSWindow 的内容与布局。
                    guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
                }
            }
            try capture("quota-settings-default")
            model.add(QuotaSourceTests.router); model.editingKeys.insert(QuotaSourceTests.router)
            SettingsControlTestSupport.settle(window)
            guard let field = SettingsControlTestSupport.element(window, id: "quota-source.key.openrouter") as? NSSecureTextField else { return false }
            let secret = UUID().uuidString
            field.stringValue = secret
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            guard model.key(QuotaSourceTests.router) == secret, !model.canTest(QuotaSourceTests.router) else { return false }
            try capture("quota-settings-key")
            await model.save(); SettingsControlTestSupport.settle(window)
            guard model.errors[QuotaSourceTests.router] != nil, model.key(QuotaSourceTests.router).isEmpty, field.stringValue.isEmpty else { return false }
            try capture("quota-settings-error")
            guard !controller.navigation.request(.section(.general)),
                  controller.navigation.pending == .section(.general),
                  controller.navigation.section == .quotaSources else { return false }
            await controller.navigation.resolve(.keepEditing)
            guard controller.navigation.section == .quotaSources, model.isDirty,
                  controller.navigation.pending == nil else { return false }
            guard !controller.navigation.request(.section(.general)) else { return false }
            await controller.navigation.resolve(.save)
            guard controller.navigation.section == .quotaSources, model.isDirty,
                  controller.navigation.pending == nil else { return false }
            guard NetworkSettingsTests.click(window, id: "quota-source.cancel") else { return false }
            guard controller.window === window && !model.isDirty && model.editingKeys.isEmpty,
                  model.draft == model.saved && state.quotaProviders == [.claude, .codex, .deepseek, .opencodego] else { return false }
            model.add(QuotaSourceTests.router)
            guard !controller.navigation.request(.section(.general)) else { return false }
            await controller.navigation.resolve(.discard)
            return controller.navigation.section == .general && controller.window === window
                && !model.isDirty && model.draft == model.saved
        } catch { print("额度设置真实控件失败：\(error)"); return false }
    }
}
