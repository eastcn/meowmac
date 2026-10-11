import AppKit
import SwiftUI
import MeowMacCore
import os

@MainActor
public final class AlertRuleSettingsModel: ObservableObject {
    public let state: PanelState
    public let configURL: URL
    @Published public var expandedID: String?
    @Published public var draft: AlertRule?
    @Published public var draftNotify = true
    @Published public var error: String?
    @Published public var status = "更改立即生效"
    @Published public var confirmation: Confirmation?
    public enum Confirmation: Equatable { case delete(String), defaults }
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "alert-rules")
    public init(state: PanelState, configURL: URL = ConfigStore.defaultURL) { self.state = state; self.configURL = configURL }
    public var config: LocalConfig { state.configResult.config }
    public var custom: [AlertRule] { config.alertRules.custom }
    public var canAdd: Bool { custom.count < 32 }
    public func value(_ rule: BuiltinAlertRule) -> AlertRuleOverride { config.alertRules.effective(rule, config: config) }
    public func isEnabled(_ id: String) -> Bool {
        if let rule = BuiltinAlertRule(rawValue: id) { return value(rule).enabled != false }
        return custom.first { $0.id == id }?.enabled == true
    }
    public func notify(_ id: String) -> Bool { state.notificationSettings.rules[id] ?? NotificationSettings.defaultRules[id] ?? true }
    public func setNotify(_ id: String, _ enabled: Bool) {
        guard state.notificationSettings.enabled, isEnabled(id), id != BuiltinAlertRule.cooling.id else { return }
        var next = state.notificationSettings; next.rules[id] = enabled
        state.onSetNotificationSettings(next)
    }
    public func setNotifications(_ enabled: Bool) { ImmediateSettingsActions(state: state).setNotifications(enabled) }
    public func setEnabled(_ id: String, _ enabled: Bool) {
        var rules = config.alertRules
        if let rule = BuiltinAlertRule(rawValue: id) {
            var override = value(rule); override.enabled = enabled; rules.builtin[id] = override
            save(rules, changed: [rule])
        } else if let index = rules.custom.firstIndex(where: { $0.id == id }) {
            rules.custom[index].enabled = enabled; save(rules)
        }
    }
    public func quotaEnabled(_ rule: BuiltinAlertRule, provider: QuotaProvider) -> Bool {
        config.alertRules.quotaProviders[provider.rawValue]?.enabled(rule) != false
    }
    public func setQuotaEnabled(_ rule: BuiltinAlertRule, provider: QuotaProvider, enabled: Bool) {
        guard [.quotaLow, .pace, .balance].contains(rule) else { return }
        var rules = config.alertRules
        var value = rules.quotaProviders[provider.rawValue] ?? .init()
        value.setEnabled(rule, enabled); rules.quotaProviders[provider.rawValue] = value
        save(rules)
    }
    public func quotaThresholdText(_ provider: QuotaProvider) -> String {
        config.alertRules.quotaProviders[provider.rawValue]?.remainingThreshold.map(alertNumber) ?? ""
    }
    @discardableResult public func setQuotaThreshold(_ provider: QuotaProvider, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = Double(trimmed)
        guard trimmed.isEmpty || number.map({ $0.isFinite && (1...90).contains($0) }) == true else {
            error = "范围 1～90%，留空沿用默认阈值，已保留原值"; return false
        }
        var rules = config.alertRules
        var value = rules.quotaProviders[provider.rawValue] ?? .init()
        value.remainingThreshold = number; rules.quotaProviders[provider.rawValue] = value
        return save(rules)
    }
    public func quotaStateText(_ rule: BuiltinAlertRule, provider: QuotaProvider) -> String {
        guard config.alertRules.quotaEnabled(rule, provider: provider, config: config) else { return "已停用" }
        let matching = state.allReminders.filter { ruleID(for: $0) == rule.id && $0.provider == provider }
        if matching.contains(where: { state.projectedReminders.isSnoozed($0, now: state.now()) }) { return "已暂缓" }
        if matching.contains(where: { !$0.confirmed }) { return "读不到" }
        if !matching.isEmpty { return "触发中" }
        guard let snapshot = state.quotas[provider], snapshot.updatedAt <= state.now(), state.failures["quota", default: 0] == 0,
              state.failures["quota." + provider.rawValue, default: 0] == 0 else { return "读不到" }
        if rule == .balance { return snapshot.balance?.value == nil ? "无余额数据" : "正常" }
        guard !snapshot.windows.isEmpty else { return "无窗口数据" }
        return snapshot.windows.contains { window in
            window.usedPercent.isFinite && (window.resetsAt.map { $0 > state.now() } ?? true)
                && (rule != .pace || QuotaPace.calculate(window: window, now: state.now()) != nil)
        } ? "正常" : "读不到"
    }
    public enum Field: String { case threshold, durationSeconds, fairThermalSeconds, fanHighSeconds }
    @discardableResult public func setField(_ rule: BuiltinAlertRule, field: Field, text: String) -> Bool {
        guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { error = "请输入有限数值，已保留原值"; return false }
        var rules = config.alertRules, override = value(rule)
        let range: ClosedRange<Double>?
        switch field {
        case .threshold: range = rule.thresholdRange
        case .durationSeconds: range = override.durationSeconds == nil ? nil : 1...1440
        case .fairThermalSeconds, .fanHighSeconds: range = rule == .cooling ? 1...120 : nil
        }
        guard let range, range.contains(number), rule != .source || number.rounded() == number else {
            error = "范围 \(range.map { alertNumber($0.lowerBound) + "～" + alertNumber($0.upperBound) } ?? "只读") \(field == .threshold ? (rule == .source ? "次" : "%") : "分钟")，已保留原值"; return false
        }
        switch field {
        case .threshold: override.threshold = number
        case .durationSeconds: override.durationSeconds = number * 60
        case .fairThermalSeconds: override.fairThermalSeconds = number * 60
        case .fanHighSeconds: override.fanHighSeconds = number * 60
        }
        rules.builtin[rule.id] = override
        return save(rules, changed: [rule])
    }
    @discardableResult public func setCustomField(_ id: String, duration: Bool, text: String) -> Bool {
        guard let number = Double(text), number.isFinite, !duration || (0...1440).contains(number) else {
            error = duration ? "范围 0～1440 分钟，已保留原值" : "请输入有限数值，已保留原值"; return false
        }
        var rules = config.alertRules
        guard let index = rules.custom.firstIndex(where: { $0.id == id }) else { return false }
        if duration { rules.custom[index].durationSeconds = number * 60 } else { rules.custom[index].threshold = number }
        return save(rules)
    }
    public func beginNew() {
        guard canAdd else { return }
        draft = .init(id: "u-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased(), name: "", metric: "swap.used", threshold: 4, durationSeconds: 300)
        draftNotify = true; error = nil
    }
    public func beginEdit(_ rule: AlertRule) { draft = rule; draftNotify = notify(rule.id); error = nil }
    public var canSaveDraft: Bool { draft.flatMap { try? $0.validated() } != nil }
    @discardableResult public func saveDraft() -> Bool {
        guard let draft else { return false }
        do {
            let valid = try draft.validated()
            var rules = config.alertRules
            if let index = rules.custom.firstIndex(where: { $0.id == valid.id }) { rules.custom[index] = valid }
            else { guard canAdd else { throw AlertRuleError.invalid("最多 32 条自定义规则") }; rules.custom.append(valid) }
            _ = try ConfigStore.prepareAlertRules(rules, to: configURL)
            // 先保存通知开关，再让规则参与评估，避免新建“不开通知”的规则先发出一条通知。
            var notifications = state.notificationSettings; notifications.rules[valid.id] = draftNotify
            state.onSetNotificationSettings(notifications)
            if state.notificationSettings.rules[valid.id] != draftNotify {
                error = "通知开关保存失败，规则未保存，请重试"; return false
            }
            guard save(rules) else { return false }
            self.draft = nil; return true
        } catch { fail(error); return false }
    }
    public func confirm() {
        guard let confirmation else { return }
        switch confirmation {
        case .delete(let id):
            var rules = config.alertRules; rules.custom.removeAll { $0.id == id }
            if save(rules) { self.confirmation = nil; expandedID = nil }
        case .defaults:
            do { _ = try ConfigStore.prepareAlertRules(config.alertRules, restoringDefaults: true, to: configURL) }
            catch { fail(error); return }
            var notifications = state.notificationSettings
            for (id, value) in NotificationSettings.defaultRules { notifications.rules[id] = value }
            state.onSetNotificationSettings(notifications)
            guard NotificationSettings.defaultRules.allSatisfy({ state.notificationSettings.rules[$0.key] == $0.value }) else {
                error = "通知开关保存失败，规则未恢复，请重试"; return
            }
            if save(config.alertRules, restoring: true) { self.confirmation = nil }
        }
    }
    @discardableResult private func save(_ rules: AlertRuleSet, changed: Set<BuiltinAlertRule> = [], restoring: Bool = false) -> Bool {
        do {
            guard state.configResult.error == nil else { throw AlertRuleError.invalid("配置文件无效，未覆盖原文件") }
            try ConfigStore.saveAlertRules(rules, changedBuiltin: changed, restoringDefaults: restoring, to: configURL)
            let loaded = ConfigStore.load(from: configURL)
            guard loaded.error == nil else { throw AlertRuleError.invalid(loaded.error!) }
            if restoring { state.pendingAlertRuleResets = Set(BuiltinAlertRule.allCases.map(\.id)) }
            state.configResult = loaded
            status = "已保存 · 更改立即生效"; error = nil; return true
        } catch { fail(error); return false }
    }
    private func fail(_ failure: Error) { error = failure.localizedDescription; logger.error("提醒规则保存失败：\(failure.localizedDescription, privacy: .private)") }
    public func currentValue(_ rule: AlertRule) -> String {
        guard let metric = AlertMetric(rawValue: rule.metric) else { return "指标不可用" }
        let readings = metric.read(state.ruleInputs).filter { rule.scope?.contains($0) ?? true }
        return readings.isEmpty ? "读不到" : readings.map { ($0.subject.map { $0 + "：" } ?? "") + alertNumber($0.value) + " " + metric.unit }.joined(separator: "；")
    }
    public func currentHint(_ rule: AlertRule) -> String {
        guard let metric = AlertMetric(rawValue: rule.metric) else { return "：指标不可用，规则不会触发" }
        let readings = metric.read(state.ruleInputs).filter { rule.scope?.contains($0) ?? true }
        if readings.isEmpty { return "：本机读不到这个指标，规则不会触发" }
        return readings.contains { rule.comparison.matches($0.value, threshold: rule.threshold) } ? "，按这个阈值现在就会触发" : ""
    }
    public func stateText(_ id: String) -> String {
        guard isEnabled(id) else { return "已停用" }
        let matching = state.allReminders.filter { ruleID(for: $0) == id || (id == BuiltinAlertRule.cooling.id && $0.kind == .cooling) }
        if matching.contains(where: { state.projectedReminders.isSnoozed($0, now: state.now()) }) { return "已暂缓" }
        if matching.contains(where: { !$0.confirmed }) { return "读不到" }
        if matching.contains(where: { $0.level == .severe }) { return "严重" }
        if !matching.isEmpty { return "触发中" }
        if let custom = custom.first(where: { $0.id == id }) { return currentValue(custom) == "读不到" || !custom.available ? "读不到" : "正常" }
        guard let builtin = BuiltinAlertRule(rawValue: id) else { return "读不到" }
        switch builtin {
        case .memory: return AlertMetric.memoryPressure.read(state.ruleInputs).isEmpty ? "读不到" : "正常"
        case .disk: return AlertMetric.diskFree.read(state.ruleInputs).isEmpty ? "读不到" : "正常"
        case .process: return state.energy == nil || state.failures["energy", default: 0] > 0 ? "读不到" : "正常"
        case .thermal, .cooling: return state.snapshot?.thermal == nil || state.snapshot?.thermal == .unavailable ? "读不到" : "正常"
        case .quotaLow, .pace: return AlertMetric.quotaRemaining.read(state.ruleInputs).isEmpty ? "读不到" : "正常"
        case .balance: return state.quotas.values.contains { $0.balance?.value != nil && state.failures["quota." + $0.provider.rawValue, default: 0] == 0 } ? "正常" : "读不到"
        case .network: return state.networkTone == .gray ? "读不到" : "正常"
        case .egress: return state.networkModel?.egressState.history.isEmpty == false ? "正常" : "读不到"
        case .source: return state.failures.isEmpty ? "读不到" : "正常"
        }
    }
    public func summary(_ rule: BuiltinAlertRule) -> String {
        let v = value(rule)
        switch rule {
        case .memory: return "压力 ≥ \(alertNumber(v.threshold!))%，持续 \(alertNumber(v.durationSeconds! / 60)) 分钟"
        case .disk: return "剩余 < \(alertNumber(v.threshold!))%"
        case .process: return "单个进程 ≥ \(alertNumber(v.threshold!))%，持续 \(alertNumber(v.durationSeconds! / 60)) 分钟"
        case .thermal: return "thermalState 达到 serious 或以上"
        case .cooling: return "fair 持续 \(alertNumber(v.fairThermalSeconds! / 60)) 分钟，或风扇 ≥ \(alertNumber(v.threshold!))% 持续 \(alertNumber(v.fanHighSeconds! / 60)) 分钟"
        case .quotaLow: return "默认窗口剩余 < \(alertNumber(v.threshold!))%" + quotaOverrideSummary(rule)
        case .balance: return "每个渠道单独设阈值" + quotaOverrideSummary(rule)
        case .pace: return "按当前速度会在重置前用完" + quotaOverrideSummary(rule)
        case .network: return "DNS 泄漏、TUN 失效、站点探测失败等"
        case .egress: return "只通知，不进提醒列表"
        case .source: return "连续 \(alertNumber(v.threshold!)) 次采集失败"
        }
    }
    private func quotaOverrideSummary(_ rule: BuiltinAlertRule) -> String {
        let count = state.quotaProviders.filter { provider in
            guard let value = config.alertRules.quotaProviders[provider.rawValue] else { return false }
            return value.enabled(rule) == false || (rule == .quotaLow && value.remainingThreshold != nil)
        }.count
        return count == 0 ? "" : " · \(count) 个渠道已单独设置"
    }
    public func summary(_ rule: AlertRule) -> String {
        guard let metric = AlertMetric(rawValue: rule.metric) else { return "指标不可用（\(rule.metric)）" }
        let scope = metric.hasObjects ? (rule.scope?.provider ?? "任一渠道") + " " + (rule.scope?.window ?? "任一窗口") + "，" : ""
        return scope + metric.name + " " + rule.comparison.symbol + " " + alertNumber(rule.threshold) + " " + metric.unit
            + (rule.durationSeconds > 0 ? "，持续 \(alertNumber(rule.durationSeconds / 60)) 分钟" : "")
    }
}

struct AlertRuleSettingsView: View {
    @ObservedObject var model: AlertRuleSettingsModel
    @ObservedObject var state: PanelState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if state.configResult.error != nil {
                    GroupBox { VStack(alignment: .leading) {
                        Text("配置文件无效，已按默认规则运行").foregroundStyle(.orange)
                        Button("打开配置文件…", action: state.onOpenConfig).buttonStyle(.link)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                }
                if state.notificationsAuthorized == false {
                    GroupBox { VStack(alignment: .leading, spacing: 8) {
                        Text("系统通知未授权，MeowMac 发不出通知。").foregroundStyle(.orange)
                        Button("打开系统设置…", action: state.onOpenNotificationSystemSettings).buttonStyle(.link).accessibilityIdentifier("settings.notification-permission")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }.accessibilityIdentifier("settings.notification-banner")
                }
                Text("系统通知").font(.headline)
                GroupBox { VStack(alignment: .leading, spacing: 5) {
                    SettingsImmediateToggle(title: "发送系统通知", id: "settings.notifications", value: Binding(get: { state.notificationSettings.enabled }, set: model.setNotifications))
                    Text("只管通知，不影响检测。同一问题持续期间只发一次").font(.caption).foregroundStyle(.secondary)
                }.padding(8) }
                ForEach(["系统", "额度", "网络", "数据源"], id: \.self) { group in
                    HStack { Text(group).font(.headline); Spacer(); Text(group == "系统" ? "2 秒评估一次" : group == "额度" ? "随额度刷新评估" : group == "网络" ? "来自 TunCanary 的判定" : "").font(.caption).foregroundStyle(.secondary) }
                    GroupBox { VStack(spacing: 0) {
                        ForEach(BuiltinAlertRule.allCases.filter { $0.group == group }) { rule in
                            if rule != BuiltinAlertRule.allCases.first(where: { $0.group == group }) { Divider() }
                            builtinRow(rule)
                        }
                    } }
                }
                HStack { Text("自定义").font(.headline); Spacer(); Text("\(model.custom.count) / 32 条").font(.caption).foregroundStyle(.secondary) }
                GroupBox { VStack(spacing: 0) {
                    ForEach(model.custom) { rule in
                        row(id: rule.id, name: rule.name, summary: model.summary(rule), level: rule.level.title, custom: true)
                        if model.expandedID == rule.id {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text("阈值").frame(width: 70, alignment: .leading); AlertNumberField(id: "alerts.custom.threshold." + rule.id, text: alertNumber(rule.threshold)) { model.setCustomField(rule.id, duration: false, text: $0) }.frame(width: 70, height: 24); Text(AlertMetric(rawValue: rule.metric)?.unit ?? "") }
                                HStack { Text("持续").frame(width: 70, alignment: .leading); AlertNumberField(id: "alerts.custom.duration." + rule.id, text: alertNumber(rule.durationSeconds / 60)) { model.setCustomField(rule.id, duration: true, text: $0) }.frame(width: 70, height: 24); Text("分钟") }
                                Text("当前值：" + model.currentValue(rule)).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("编辑全部字段…") { model.beginEdit(rule) }.buttonStyle(.link).accessibilityIdentifier("alerts.edit." + rule.id)
                                    Spacer(); Button("删除", role: .destructive) { model.confirmation = .delete(rule.id) }.buttonStyle(.link).accessibilityIdentifier("alerts.delete." + rule.id)
                                }
                            }.padding(.horizontal, 12).padding(.bottom, 12)
                        }
                        Divider()
                    }
                    SettingsActionButton(title: model.canAdd ? "＋ 新建规则" : "＋ 新建规则（已达上限 32 条）", id: "alerts.add", enabled: model.canAdd, action: model.beginNew).frame(height: 28).padding(8)
                } }
                Text("规则存在 config.json，也可以通过“打开配置文件…”修改；铃铛开关只在这里改。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("alerts.error") }
                ForEach(state.configResult.config.alertRules.diagnostics, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: Binding(get: { model.draft != nil }, set: { if !$0 { model.draft = nil } })) { AlertRuleEditor(model: model, state: state) }
        .alert(model.confirmation == .defaults ? "恢复内置规则的默认设置？" : "删除这条规则？", isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })) {
            Button("取消", role: .cancel) { model.confirmation = nil }
            Button(model.confirmation == .defaults ? "恢复默认" : "删除", role: .destructive, action: model.confirm)
        } message: { Text(model.confirmation == .defaults ? "阈值、持续时长、启用、渠道设置和通知开关回到默认。自定义规则保留。" : "同时清除这条规则的暂缓与已通知记录。") }
    }
    private func row(id: String, name: String, summary: String, level: String, custom: Bool = false) -> some View {
        HStack(spacing: 8) {
            NativeSettingsSwitch(id: "alerts.enabled." + id, value: Binding(get: { model.isEnabled(id) }, set: { model.setEnabled(id, $0) }), enabled: true).frame(width: 38, height: 24)
            Button { model.expandedID = model.expandedID == id ? nil : id } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: model.expandedID == id ? "chevron.down" : "chevron.right").font(.system(size: 8))
                        Text(name).fontWeight(.semibold)
                        Text(level).font(.system(size: 9)).foregroundStyle(level == "严重" ? Color.red : level == "标记" ? Color.secondary : Color.orange).padding(.horizontal, 4).padding(.vertical, 2).background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        if custom { Text("自定义").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("alerts.expand." + id)
            Text(model.stateText(id)).font(.system(size: 10)).foregroundStyle(model.stateText(id) == "严重" ? Color.red : model.stateText(id) == "触发中" ? Color.orange : Color.secondary).fixedSize()
            if id == BuiltinAlertRule.cooling.id { Text("–").foregroundStyle(.tertiary).frame(width: 25) }
            else { AlertBell(id: "alerts.notify." + id, value: Binding(get: { model.notify(id) }, set: { model.setNotify(id, $0) }), enabled: state.notificationSettings.enabled && model.isEnabled(id)).frame(width: 25, height: 24) }
        }.font(.system(size: 12)).padding(.vertical, 10).padding(.horizontal, 8).opacity(model.isEnabled(id) ? 1 : 0.5)
    }
    fileprivate func builtinRow(_ rule: BuiltinAlertRule) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(id: rule.id, name: rule.name, summary: model.summary(rule), level: rule == .network ? "严重" : [.cooling, .egress].contains(rule) ? "标记" : "提醒")
            if model.expandedID == rule.id {
                let v = model.value(rule)
                VStack(alignment: .leading, spacing: 10) {
                    if let threshold = v.threshold {
                        field(rule, .threshold, label: rule == .memory ? "压力 ≥" : rule == .quotaLow ? "默认窗口剩余 <" : rule == .disk ? "剩余 <" : rule == .process ? "单进程 ≥" : rule == .cooling ? "风扇 ≥" : "连续失败", value: threshold, unit: rule == .source ? "次" : rule == .process ? "% 单核" : rule == .cooling ? "% 最大值" : "%")
                    }
                    if let duration = v.durationSeconds { field(rule, .durationSeconds, label: "持续", value: duration / 60, unit: "分钟") }
                    if let duration = v.fairThermalSeconds { field(rule, .fairThermalSeconds, label: "fair 持续", value: duration / 60, unit: "分钟") }
                    if let duration = v.fanHighSeconds { field(rule, .fanHighSeconds, label: "风扇持续", value: duration / 60, unit: "分钟") }
                    if rule == .memory { Text("口径同面板的压力%：100 减 kern.memorystatus_level") }
                    if rule == .thermal { Text("系统判定，没有可调阈值") }
                    if rule == .cooling { Text("只在总览条加标记，不影响猫，不发通知") }
                    if rule == .balance { HStack { Text("阈值在“额度源”栏按渠道修改"); Button("前往“额度源”") { state.onOpenSettings(.quotaSources) }.buttonStyle(.link) } }
                    if rule == .pace {
                        Text("按本轮开始以来的平均用量预测：已用比例超过已过时间比例，就可能在重置前用完。5 小时窗口开始 1 分钟已用 1%，也会触发。")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if [.quotaLow, .pace, .balance].contains(rule) { quotaChannels(rule) }
                    if rule == .network || rule == .egress { Text("由 TunCanary 判定，只能开关") }
                    Text("档位：" + (rule == .cooling || rule == .egress ? "标记" : rule == .network ? "严重或提醒" : "提醒") + ([.memory, .process, .thermal].contains(rule) ? " · 不可暂缓，恢复后消除" : [.network, .cooling, .egress].contains(rule) ? "" : " · 可限时暂缓"))
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
    }
    private func quotaChannels(_ rule: BuiltinAlertRule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("按渠道设置").fontWeight(.semibold)
            Text("关闭后，这个渠道不再产生此类提醒，也不影响猫或发通知；原始用量与风险色保留。总规则关闭时，所有渠道都停用。")
                .fixedSize(horizontal: false, vertical: true)
            if rule == .quotaLow { Text("阈值留空沿用默认 \(alertNumber(model.value(.quotaLow).threshold!))%，范围 1～90%。") }
            ForEach(state.quotaProviders, id: \.self) { provider in
                HStack(spacing: 8) {
                    NativeSettingsSwitch(id: "alerts.channel." + rule.id + "." + provider.rawValue,
                        value: Binding(get: { model.quotaEnabled(rule, provider: provider) }, set: { model.setQuotaEnabled(rule, provider: provider, enabled: $0) }),
                        enabled: model.isEnabled(rule.id)).frame(width: 38, height: 24)
                    Text(provider.displayName)
                    Spacer()
                    if rule == .quotaLow {
                        Text("剩余 <")
                        AlertNumberField(id: "alerts.channel.threshold." + provider.rawValue, text: model.quotaThresholdText(provider)) {
                            model.setQuotaThreshold(provider, text: $0)
                        }.frame(width: 54, height: 24)
                        Text("%")
                    }
                    Text(model.quotaStateText(rule, provider: provider)).frame(width: 60, alignment: .trailing)
                }
            }
        }
    }
    private func field(_ rule: BuiltinAlertRule, _ field: AlertRuleSettingsModel.Field, label: String, value: Double, unit: String) -> some View {
        HStack { Text(label).frame(width: 90, alignment: .leading); AlertNumberField(id: "alerts.field." + rule.id + "." + field.rawValue, text: alertNumber(value)) { model.setField(rule, field: field, text: $0) }.frame(width: 70, height: 24); Text(unit); Spacer() }
    }
}

struct AlertRuleEditor: View {
    @ObservedObject var model: AlertRuleSettingsModel
    @ObservedObject var state: PanelState
    private var draft: AlertRule { model.draft ?? .init(id: "u-00000000", name: "", metric: "swap.used", threshold: 4) }
    private func binding<T>(_ path: WritableKeyPath<AlertRule, T>) -> Binding<T> { Binding(get: { draft[keyPath: path] }, set: { model.draft?[keyPath: path] = $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.custom.contains(where: { $0.id == draft.id }) ? "编辑规则" : "新建规则").font(.headline)
            Form {
                LabeledContent("名称") { TextField("例如：Swap 偏高", text: binding(\.name)) }.accessibilityIdentifier("alerts.draft.name")
                Picker("指标", selection: binding(\.metric)) {
                    ForEach(["系统", "能耗与温度", "额度"], id: \.self) { group in
                        Section(group) { ForEach(AlertMetric.allCases.filter { $0.group == group }) { Text($0.name + "（" + $0.unit + "）").tag($0.id) } }
                    }
                    if !draft.available { Text("指标不可用（\(draft.metric)）").tag(draft.metric) }
                }.accessibilityIdentifier("alerts.draft.metric").onChange(of: draft.metric) { _, metric in if metric != AlertMetric.quotaRemaining.id { model.draft?.scope = nil } }
                if draft.metric == AlertMetric.quotaRemaining.id {
                    HStack {
                        Picker("渠道", selection: Binding(get: { draft.scope?.provider ?? "" }, set: { model.draft?.scope = AlertScope(provider: $0.isEmpty ? nil : $0, window: draft.scope?.window) })) {
                            Text("任一渠道").tag(""); ForEach(state.quotaProviders, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                        }
                        Picker("窗口", selection: Binding(get: { draft.scope?.window ?? "" }, set: { model.draft?.scope = AlertScope(provider: draft.scope?.provider, window: $0.isEmpty ? nil : $0) })) {
                            Text("任一窗口").tag("")
                            ForEach(Array(Set(state.quotas.values.filter { draft.scope?.provider == nil || $0.provider.rawValue == draft.scope?.provider }.flatMap { $0.windows.map(\.identifier) })).sorted(), id: \.self) { id in
                                Text(state.quotas.values.flatMap(\.windows).first { $0.identifier == id }?.displayName ?? id).tag(id)
                            }
                        }
                    }
                }
                HStack {
                    Picker("条件", selection: binding(\.comparison)) { ForEach(AlertComparison.allCases, id: \.self) { Text($0.symbol).tag($0) } }.frame(width: 160)
                    TextField("阈值", value: binding(\.threshold), format: .number).accessibilityIdentifier("alerts.draft.threshold").frame(width: 90)
                    Text(AlertMetric(rawValue: draft.metric)?.unit ?? "")
                }
                Text("当前值：" + model.currentValue(draft) + model.currentHint(draft)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { Text("持续"); TextField("分钟", value: Binding(get: { draft.durationSeconds / 60 }, set: { model.draft?.durationSeconds = $0 * 60 }), format: .number).frame(width: 90).accessibilityIdentifier("alerts.draft.duration"); Text("分钟（0 表示立即）") }
                Picker("档位", selection: binding(\.level)) {
                    Text("提醒：猫变橙色，可限时暂缓").tag(AlertRuleLevel.warn)
                    Text("严重：猫停下，不可暂缓").tag(AlertRuleLevel.severe)
                }
                Toggle("触发时发系统通知", isOn: $model.draftNotify).accessibilityIdentifier("alerts.draft.notify")
            }
            Text((draft.name.isEmpty ? "未命名规则" : draft.name) + "：" + model.summary(draft)).font(.caption).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { model.draft = nil }; SettingsActionButton(title: model.custom.contains(where: { $0.id == draft.id }) ? "保存" : "添加", id: "alerts.draft.save", enabled: model.canSaveDraft) { _ = model.saveDraft() }.frame(width: 64, height: 28) }
        }.padding(24).frame(width: 480)
    }
}

struct AlertBell: NSViewRepresentable {
    let id: String
    @Binding var value: Bool
    let enabled: Bool
    final class Coordinator: NSObject {
        var binding: Binding<Bool>
        init(_ value: Binding<Bool>) { binding = value }
        @objc func invoke(_ button: NSButton) { binding.wrappedValue.toggle(); button.state = binding.wrappedValue ? .on : .off }
    }
    func makeCoordinator() -> Coordinator { Coordinator($value) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "发系统通知")!, target: context.coordinator, action: #selector(Coordinator.invoke))
        button.isBordered = false; button.setButtonType(.toggle); button.setAccessibilityIdentifier(id)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.binding = $value; button.isEnabled = enabled; button.state = value && enabled ? .on : .off; button.contentTintColor = value && enabled ? .controlAccentColor : .secondaryLabelColor }
}

struct AlertNumberField: NSViewRepresentable {
    let id: String, text: String
    let commit: (String) -> Bool
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: String
        var commit: (String) -> Bool
        init(text: String, commit: @escaping (String) -> Bool) { self.text = text; self.commit = commit }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if !commit(field.stringValue) { field.stringValue = text }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(text: text, commit: commit) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text); field.delegate = context.coordinator; field.setAccessibilityIdentifier(id); return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = text; context.coordinator.commit = commit
        if field.currentEditor() == nil { field.stringValue = text }
    }
}


@MainActor
public extension PanelPreviewRenderer {
    /// 复用实际展开块检查文案与布局；原生控件和系统材质仍以真实窗口为准。
    static func quotaRulePNG(state: PanelState, rule: BuiltinAlertRule, dark: Bool) -> Data? {
        guard [.quotaLow, .pace, .balance].contains(rule) else { return nil }
        let model = AlertRuleSettingsModel(state: state)
        model.expandedID = rule.id
        let view = AlertRuleSettingsView(model: model, state: state).builtinRow(rule)
            .padding(16).frame(width: 520)
        let measure = NSHostingView(rootView: view)
        let height = ceil(measure.fittingSize.height)
        return renderPNG(view, width: 520, height: height, dark: dark)
    }
}
