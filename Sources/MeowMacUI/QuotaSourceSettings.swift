import AppKit
import Combine
import Foundation
import SwiftUI
import MeowMacCore
import MeowMacQuota
import os

public struct QuotaSourceDraft: Equatable, Identifiable {
    public let provider: QuotaProvider
    public var enabled: Bool
    /// 余额提醒阈值的输入文本；留空表示不提醒。
    public var balanceWarn: String
    public var id: String { provider.rawValue }
    public init(provider: QuotaProvider, enabled: Bool, balanceWarn: String = MetricFormat.money(QuotaSourceList.defaultBalanceWarn)) {
        self.provider = provider; self.enabled = enabled; self.balanceWarn = balanceWarn
    }
    /// 解析阈值：空 = 0（不提醒），非法返回 nil。
    public var balanceWarnValue: Double? {
        let text = balanceWarn.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard let value = Double(text), value.isFinite, value >= 0, value <= 1_000_000 else { return nil }
        return value
    }
}

@MainActor
public final class QuotaSourceSettingsModel: ObservableObject, SettingsDraftSession {
    @Published public private(set) var saved: [QuotaSourceDraft]
    @Published public private(set) var draft: [QuotaSourceDraft]
    @Published public private(set) var catalog: [QuotaCatalogEntry]
    @Published public private(set) var credentials: [QuotaProvider: Bool] = [:]
    @Published public private(set) var errors: [QuotaProvider: String] = [:]
    @Published public private(set) var testing: [QuotaProvider: String] = [:]
    @Published public var editingKeys = Set<QuotaProvider>()
    @Published private var keys: [QuotaProvider: String] = [:]
    @Published private var failedKeys = Set<QuotaProvider>()
    @Published public private(set) var busy = false
    @Published public private(set) var status = "尚未修改"
    private let state: PanelState
    private let coordinator: QuotaCoordinator
    private var refreshSince: Date?
    private var refreshedProviders: [QuotaProvider] = []
    private var unsupportedKeys = Set<QuotaProvider>()
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "quota-source-settings")

    public init(state: PanelState, coordinator: QuotaCoordinator, catalog: [QuotaCatalogEntry] = []) {
        self.state = state; self.coordinator = coordinator; self.catalog = catalog
        let initial = state.quotaProviders.map { QuotaSourceDraft(provider: $0, enabled: coordinator.sourceEnabled[$0] ?? true, balanceWarn: Self.warnText(state, $0)) }
        saved = initial; draft = initial
        if let reason = state.quotaSourceRecoveryReason { status = reason }
    }
    public var available: [QuotaCatalogEntry] { catalog.filter { entry in !draft.contains { $0.provider == entry.provider } } }
    /// 按名称或 id 搜索可添加的渠道，忽略大小写；空关键词返回全部。
    public func available(matching query: String) -> [QuotaCatalogEntry] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = available.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        guard !keyword.isEmpty else { return list }
        return list.filter { $0.displayName.localizedCaseInsensitiveContains(keyword) || $0.provider.rawValue.localizedCaseInsensitiveContains(keyword) }
    }
    public var isDirty: Bool { draft != saved || !keys.isEmpty || !failedKeys.isEmpty }
    public var canSave: Bool { isDirty && !busy && state.quotaSourceRecoveryReason == nil && !hasInvalidBalanceWarn }
    public var hasInvalidBalanceWarn: Bool { draft.contains { showsBalanceWarn($0.provider) && $0.balanceWarnValue == nil } }
    /// 余额型渠道：已采到余额，或 DeepSeek（还没采集过也显示）。
    public func showsBalanceWarn(_ provider: QuotaProvider) -> Bool { provider == .deepseek || state.quotas[provider]?.balance != nil }
    public func balanceCurrency(_ provider: QuotaProvider) -> String { state.quotas[provider]?.balance?.currency ?? (provider == .deepseek ? "¥" : "") }
    public func balanceWarnText(_ provider: QuotaProvider) -> String { draft.first { $0.provider == provider }?.balanceWarn ?? "" }
    public func setBalanceWarn(_ value: String, provider: QuotaProvider) {
        guard !busy, let index = draft.firstIndex(where: { $0.provider == provider }) else { return }
        draft[index].balanceWarn = value
    }
    static func warnText(_ state: PanelState, _ provider: QuotaProvider) -> String {
        let value = state.quotaSources.balanceThreshold(provider)
        return value > 0 ? MetricFormat.money(value) : ""
    }
    /// 保存清单时带上这些渠道的余额阈值，避免覆盖成默认值。
    private func sourceList(_ rows: [QuotaSourceDraft]) -> QuotaSourceList {
        var list = QuotaSourceList(providers: rows.map(\.provider))
        for row in rows where showsBalanceWarn(row.provider) { if let value = row.balanceWarnValue { list.balanceWarn[row.provider.rawValue] = value } }
        return list
    }
    public var isBusy: Bool { busy }
    public func rowDirty(_ provider: QuotaProvider) -> Bool {
        draft.first { $0.provider == provider } != saved.first { $0.provider == provider } || keys[provider] != nil || failedKeys.contains(provider)
    }
    public func canTest(_ provider: QuotaProvider) -> Bool { !busy && !rowDirty(provider) && saved.contains { $0.provider == provider } }
    public func entry(_ provider: QuotaProvider) -> QuotaCatalogEntry? { catalog.first { $0.provider == provider } ?? QuotaCatalog.entry(provider) }
    public func canEditKey(_ provider: QuotaProvider) -> Bool { entry(provider)?.supportsAPIKey == true && !unsupportedKeys.contains(provider) }
    public func key(_ provider: QuotaProvider) -> String { keys[provider] ?? "" }
    public func setKey(_ value: String, provider: QuotaProvider) {
        guard canEditKey(provider), !busy else { return }
        if value.isEmpty { keys.removeValue(forKey: provider) } else { keys[provider] = value }
        failedKeys.remove(provider)
    }
    public func add(_ provider: QuotaProvider) {
        guard !busy, available.contains(where: { $0.provider == provider }) else { return }
        draft.append(QuotaSourceDraft(provider: provider, enabled: true, balanceWarn: Self.warnText(state, provider)))
    }
    public func remove(_ provider: QuotaProvider) {
        guard !busy else { return }
        draft.removeAll { $0.provider == provider }; keys.removeValue(forKey: provider)
        failedKeys.remove(provider); editingKeys.remove(provider); errors.removeValue(forKey: provider)
    }
    public func setEnabled(_ value: Bool, provider: QuotaProvider) {
        guard !busy, let index = draft.firstIndex(where: { $0.provider == provider }) else { return }
        draft[index].enabled = value
    }
    public func cancelKey(_ provider: QuotaProvider) { keys.removeValue(forKey: provider); editingKeys.remove(provider); failedKeys.remove(provider) }
    public func discard() {
        guard !busy else { return }
        keys.removeAll(); failedKeys.removeAll(); editingKeys.removeAll(); errors.removeAll()
        draft = saved; status = state.quotaSourceRecoveryReason ?? "尚未修改"
    }
    public func cancel() { discard() }
    public func close() { keys.removeAll(); editingKeys.removeAll() }

    public func load() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let client = coordinator.client
        do {
            let (entries, states) = try await Task.detached { (try client.providers(), try client.configStatus()) }.value
            catalog = entries; credentials = states
            if !isDirty {
                saved = state.quotaProviders.map { provider in QuotaSourceDraft(provider: provider, enabled: entries.first { $0.provider == provider }?.enabled ?? false, balanceWarn: Self.warnText(state, provider)) }
                draft = saved
            }
            for entry in entries { coordinator.sourceEnabled[entry.provider] = entry.enabled }
        } catch {
            status = "渠道目录读取失败：" + error.localizedDescription
            logger.error("额度渠道目录读取失败，未修改配置")
        }
    }

    public func credentialText(_ provider: QuotaProvider) -> String {
        if canEditKey(provider) { return keys[provider] != nil ? "新 key 待保存" : credentials[provider] == true ? "已配置" : "未配置" }
        if provider == .deepseek { return credentials[provider] == true ? "已配置 · 由 CodexBar 管理" : "未配置 · 由 CodexBar 管理" }
        return "登录凭据由 CodexBar 管理"
    }
    public func collectionText(_ provider: QuotaProvider) -> String {
        if let pause = state.quotaPauseMessage(provider) { return pause }
        if let attempt = state.quotaAttempts[provider] {
            return (attempt.success ? "最近采集成功 " : "最近采集失败 ") + DisplayDate.format(attempt.at, pattern: "HH:mm") + (attempt.success ? "" : "：" + attempt.message)
        }
        if let snapshot = state.quotas[provider] { return "最近采集成功 " + DisplayDate.format(snapshot.updatedAt, pattern: "HH:mm") }
        return "尚未采集"
    }
    public func sourceText(_ provider: QuotaProvider) -> String {
        if canEditKey(provider) { return "API key" }
        if provider == .deepseek { return "token 账号（由 CodexBar 管理）" }
        return "使用本机登录（OAuth / 浏览器 cookie / CLI）"
    }
    public func test(_ provider: QuotaProvider) {
        guard canTest(provider) else { testing[provider] = "先保存再测试"; return }
        testing[provider] = coordinator.test(provider)
    }
    public var statusText: String {
        guard let since = refreshSince, !refreshedProviders.isEmpty else { return isDirty && status == "尚未修改" ? "有未保存的修改" : status }
        let completed = refreshedProviders.compactMap { state.quotaAttempts[$0] }.filter { $0.at >= since }
        if completed.count == refreshedProviders.count {
            return "已保存，刷新完成：\(completed.filter(\.success).count) 个成功，\(completed.filter { !$0.success }.count) 个失败"
        }
        if refreshedProviders.contains(where: { state.quotaPauseMessage($0) != nil }) { return "已保存，GPT/Codex 和 Claude 刷新等待代理保护就绪" }
        let remaining = refreshedProviders.map(coordinator.cooldownRemaining).max() ?? 0
        return "已保存，正在刷新 \(refreshedProviders.count) 个渠道…" + (remaining > 0 ? "（合并请求，约 \(Int(ceil(remaining))) 秒后继续）" : "")
    }

    @discardableResult public func save() async -> Bool {
        guard canSave else { return !busy && !isDirty && state.quotaSourceRecoveryReason == nil }
        busy = true; refreshSince = nil
        defer { keys.removeAll(); busy = false }
        let desired = draft
        let removed = saved.filter { row in !desired.contains { $0.provider == row.provider } }
        var changed: [QuotaProvider] = []
        do {
            if !removed.isEmpty {
                let retained = saved.filter { row in !removed.contains { $0.provider == row.provider } }
                try coordinator.replaceSources(sourceList(retained))
                saved = retained
            }
        } catch { status = error.localizedDescription; logger.error("额度渠道清单保存失败"); return false }
        let client = coordinator.client
        for row in desired where rowDirty(row.provider) {
            let provider = row.provider
            // 只改了余额阈值：写本机清单即可，不调用 CLI、不刷新。
            let previous = saved.first { $0.provider == provider }
            let warnOnly = previous.map { var other = $0; other.balanceWarn = row.balanceWarn; return other == row } == true && keys[provider] == nil && !failedKeys.contains(provider)
            do {
                if failedKeys.contains(provider), keys[provider] == nil {
                    errors[provider] = "API key 保存失败，请重新填写"; continue
                }
                if let key = keys[provider] {
                    do {
                        try await Task.detached { try client.setAPIKey(key, provider: provider) }.value
                        keys.removeValue(forKey: provider); editingKeys.remove(provider); credentials[provider] = true
                    } catch {
                        keys.removeValue(forKey: provider); failedKeys.insert(provider)
                        if case CodexBarError.apiKeyUnsupported = error { unsupportedKeys.insert(provider) }
                        throw error
                    }
                }
                if saved.first(where: { $0.provider == provider })?.enabled != row.enabled {
                    try await Task.detached { try client.setEnabled(row.enabled, provider: provider) }.value
                }
                var successful = saved.filter { $0.provider != provider }; successful.append(row)
                // 其他行沿用已保存的值，避免把同批尚未保存成功的草稿（例如阈值）提前写盘。
                let ordered = desired.filter { item in successful.contains { $0.provider == item.provider } }
                    .map { item in item.provider == provider ? row : (saved.first { $0.provider == item.provider } ?? item) }
                try coordinator.replaceSources(sourceList(ordered))
                saved = ordered; coordinator.sourceEnabled[provider] = row.enabled
                failedKeys.remove(provider); errors.removeValue(forKey: provider)
                if !warnOnly { changed.append(provider) }
            } catch {
                errors[provider] = error.localizedDescription
                logger.error("额度源保存失败：\(provider.rawValue, privacy: .public)，未记录凭据")
            }
        }
        if errors.isEmpty {
            status = "已保存"
            refreshedProviders = changed; refreshSince = state.now()
            coordinator.requestRefresh(changed, includeDisabled: true)
        } else { status = "部分保存失败：成功项已生效，请修正标红的项" }
        return errors.isEmpty && !isDirty
    }
}

struct QuotaSecureField: NSViewRepresentable {
    @Binding var value: String
    let identifier: String
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var binding: Binding<String>
        init(_ binding: Binding<String>) { self.binding = binding }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSecureTextField { binding.wrappedValue = field.stringValue }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator($value) }
    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = "粘贴 API key"; field.delegate = context.coordinator
        field.setAccessibilityLabel("API key"); field.setAccessibilityIdentifier(identifier)
        return field
    }
    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.binding = $value
        if field.stringValue != value { field.stringValue = value }
    }
    static func dismantleNSView(_ field: NSSecureTextField, coordinator: Coordinator) { field.stringValue = ""; field.delegate = nil }
}

struct QuotaSourceSettingsView: View {
    @ObservedObject var model: QuotaSourceSettingsModel
    @ObservedObject var state: PanelState
    @State private var adding = false
    @State private var query = ""
    private var addPicker: some View {
        let matches = model.available(matching: query)
        return VStack(alignment: .leading, spacing: 8) {
            TextField("搜索渠道", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("quota-source.add.search")
            if matches.isEmpty {
                Text(model.available.isEmpty ? "CodexBarCLI 支持的渠道都已添加" : "没有匹配的渠道").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { entry in
                            Button { model.add(entry.provider); adding = false } label: {
                                HStack(spacing: 8) {
                                    ProviderLogo(provider: entry.provider)
                                    Text(entry.displayName)
                                    Spacer()
                                    Text(QuotaCatalog.entry(entry.provider)?.supportsAPIKey == true ? "API key" : "本机登录").font(.caption).foregroundStyle(.secondary)
                                }.contentShape(Rectangle()).padding(.vertical, 5)
                            }.buttonStyle(.plain).accessibilityIdentifier("quota-source.add." + entry.id)
                        }
                    }
                }.frame(maxHeight: 280)
            }
        }.padding(12).frame(width: 300)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("渠道").fontWeight(.semibold); Spacer(); Text("启用状态与 CodexBar 共用").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal, 24).padding(.top, 18)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 0) {
                        ForEach(model.draft) { row in
                            if row.id != model.draft.first?.id { Divider() }
                            channel(row).id(row.id)
                        }
                    }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                    // 不用 SwiftUI Menu：它在保存、移除后不刷新禁用状态和菜单项。
                    Button("＋ 添加渠道…") { query = ""; adding = true }
                        .buttonStyle(.link).disabled(model.busy || model.available.isEmpty).accessibilityIdentifier("quota-source.add")
                        .popover(isPresented: $adding, arrowEdge: .bottom) { addPicker }
                    Text("数据来源：CodexBarCLI 0.70.0。API key 只写进 CodexBar 配置，MeowMac 不保存、不显示、不记日志。其他渠道复用本机的 OAuth、浏览器 cookie 或 CLI 登录，由 CodexBarCLI 采集时读取。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24)
            }.onChange(of: model.editingKeys) { keys in
                if let provider = keys.sorted(by: { $0.rawValue < $1.rawValue }).first { proxy.scrollTo(provider.rawValue, anchor: .bottom) }
            }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func channel(_ row: QuotaSourceDraft) -> some View {
        let provider = row.provider
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProviderLogo(provider: provider)
                VStack(alignment: .leading, spacing: 3) { Text(provider.displayName).fontWeight(.semibold); Text(model.sourceText(provider)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 8)
                Toggle("启用 " + provider.displayName, isOn: Binding(get: { row.enabled }, set: { model.setEnabled($0, provider: provider) })).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(model.busy).accessibilityIdentifier("quota-source.enabled." + row.id)
            }
            Text(model.credentialText(provider) + " · " + model.collectionText(provider)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.showsBalanceWarn(provider) {
                let invalid = row.balanceWarnValue == nil
                HStack(spacing: 6) {
                    Text("余额低于").font(.caption)
                    Text(model.balanceCurrency(provider)).font(.caption).foregroundStyle(.secondary)
                    TextField("不提醒", text: Binding(get: { model.balanceWarnText(provider) }, set: { model.setBalanceWarn($0, provider: provider) }))
                        .textFieldStyle(.roundedBorder).frame(width: 72).font(.caption).disabled(model.busy)
                        .accessibilityIdentifier("quota-source.balance-warn." + row.id)
                    Text("时提醒，留空不提醒").font(.caption).foregroundStyle(.secondary)
                }
                if invalid { Text("请输入 0～1000000 的数字，或留空").font(.caption).foregroundStyle(.red) }
            }
            HStack(spacing: 14) {
                if model.canEditKey(provider) { Button(model.credentials[provider] == true ? "更换 API key…" : "填写 API key…") { model.editingKeys.insert(provider) } }
                Button("测试") { model.test(provider) }.disabled(!model.canTest(provider)).help(model.rowDirty(provider) ? "先保存再测试" : "立即采集已保存的渠道")
                    .accessibilityIdentifier("quota-source.test." + row.id)
                Button("移除") { model.remove(provider) }.accessibilityIdentifier("quota-source.remove." + row.id)
                if model.rowDirty(provider) { Text("先保存再测试").foregroundStyle(.secondary) }
            }.buttonStyle(.link).font(.caption).disabled(model.busy)
            if model.editingKeys.contains(provider) {
                HStack { QuotaSecureField(value: Binding(get: { model.key(provider) }, set: { model.setKey($0, provider: provider) }), identifier: "quota-source.key." + row.id).frame(height: 24)
                    Button("取消") { model.cancelKey(provider) }
                }.disabled(model.busy)
            }
            if state.quotaPauseMessage(provider) == nil, let message = model.testing[provider], state.quotaAttempts[provider] == nil || message.contains("秒后") { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error = model.errors[provider] { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }.padding(12)
    }
}
