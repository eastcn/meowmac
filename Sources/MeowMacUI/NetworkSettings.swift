import AppKit
import Combine
import SwiftUI
import TunCanaryCore
import TunCanaryUI

public enum NetworkSettingsTab: String, CaseIterable {
    case sites = "站点", egress = "出口 IP", proxy = "代理与 DNS", frequency = "检测频率"
}

@MainActor
public final class NetworkSettingsModel: ObservableObject {
    public let network: AppModel
    @Published public var tab: NetworkSettingsTab = .sites
    @Published public private(set) var savedAt: Date?
    @Published public private(set) var completedAt: Date?
    private var expected: AppSettings?
    private var started = false
    private var progress: CheckProgress?
    private var checkedAt: Date?
    private var subscriptions: Set<AnyCancellable> = []
    public var onClose: () -> Void = {}

    public init(network: AppModel) {
        self.network = network
        network.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        network.$lastCheckedAt.dropFirst().sink { [weak self] in self?.checkedAt = $0 }.store(in: &subscriptions)
        network.$checkProgress.dropFirst().sink { [weak self] value in
            guard let self, let savedAt, expected == network.settings, completedAt == nil else { return }
            if let value {
                if value.kind != .local { started = true; progress = value }
            } else if started, let progress, progress.completed == progress.total,
                      let checkedAt, checkedAt >= savedAt, network.graceEndsAt == nil {
                completedAt = checkedAt
            }
        }.store(in: &subscriptions)
    }
    public var errorTabs: Set<NetworkSettingsTab> {
        let v = network.settingsValidation
        var result: Set<NetworkSettingsTab> = []
        if v.intranetURLError != nil || v.tailnetTargetError != nil || v.siteCountError != nil || !v.siteErrors.isEmpty || !v.checkPageErrors.isEmpty { result.insert(.sites) }
        if v.egressMonitoringError != nil || !v.egressHostErrors.isEmpty { result.insert(.egress) }
        if v.expectedDNSError != nil || v.manualFakeIPRangeError != nil || v.manualDNSPortError != nil || v.manualProcessNameError != nil || v.canaryHostError != nil { result.insert(.proxy) }
        if v.localCheckIntervalError != nil || v.lightProbeIntervalError != nil { result.insert(.frequency) }
        return result
    }
    public func open() {
        network.openSettings(); tab = .sites
        savedAt = nil; completedAt = nil; expected = nil; started = false; progress = nil; checkedAt = nil
    }
    public func cancel() {
        network.settingsDraft = SettingsDraft(settings: network.settings)
        network.route = .main; onClose()
    }
    @discardableResult public func save() -> Bool {
        guard network.canSaveSettings, let value = network.settingsValidation.settings else { return false }
        savedAt = network.now(); completedAt = nil; expected = value
        started = false; progress = nil; checkedAt = nil
        return network.saveSettings()
    }
    public var statusText: String {
        guard savedAt != nil else { return "保存后立即重新检测；取消会丢弃未保存的修改。" }
        let main = completedAt.map { "本机与站点检测已按新设置完成（\(time($0))）" } ?? "已保存，正在重新检测…"
        return main + "\n" + Self.egressStatus(settings: network.settings, state: network.egressState, now: network.now(), timeZone: network.timeZone, graceEndsAt: network.graceEndsAt)
    }
    private func time(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"; formatter.timeZone = network.timeZone
        return formatter.string(from: date)
    }
    public static func egressStatus(settings: AppSettings, state: EgressMonitorState, now: Date, timeZone: TimeZone, graceEndsAt: Date? = nil) -> String {
        guard settings.egressMonitoring.automatic else { return "出口自动检测已关闭" }
        if let graceEndsAt, graceEndsAt > now { return "出口检测等待网络切换宽限期结束" }
        let targets = settings.effectiveEgressTargets
        let active = targets.filter { state.controls[$0.rawValue]?.suspended != true }
        guard !active.isEmpty else { return "出口目标因拒绝访问或验证页面暂停检测" }
        let times = active.map { target in
            max(now, max(state.controls[target.rawValue]?.nextAttempt ?? .distantPast,
                (state.controls[target.rawValue]?.lastAttempt ?? .distantPast).addingTimeInterval(settings.egressMonitoring.effectiveInterval)))
        }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"; formatter.timeZone = timeZone
        let next = formatter.string(from: times.min() ?? now)
        let cooling = active.contains { (state.manualCooldownUntil($0) ?? .distantPast) > now }
        let paused = active.count < targets.count ? "；部分目标已暂停" : ""
        return "出口检测按间隔进行，下次约 \(next)" + (cooling ? "（服务限流冷却中）" : "") + paused
    }
}

@MainActor
public final class NetworkSettingsController: NSObject, NSWindowDelegate {
    public private(set) var window: NSWindow?
    public let model: NetworkSettingsModel
    public init(network: AppModel) { model = NetworkSettingsModel(network: network); super.init() }
    public func present() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        model.open()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "网络设置"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: NetworkSettingsView(model: model))
        model.onClose = { [weak self] in self?.window?.close() }
        self.window = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    public func windowWillClose(_ notification: Notification) {
        model.network.settingsDraft = SettingsDraft(settings: model.network.settings)
        model.network.route = .main
        window?.delegate = nil; window = nil
    }
}

public struct NetworkSettingsView: View {
    @ObservedObject var model: NetworkSettingsModel
    @ObservedObject var network: AppModel
    public init(model: NetworkSettingsModel) { self.model = model; network = model.network }
    private var validation: SettingsDraft.Validation { network.settingsValidation }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("网络设置").font(.title2.bold())
            Text("管理网络检测目标和预期；保存后按新设置重新检测。").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(NetworkSettingsTab.allCases, id: \.self) { tab in
                    NetworkSettingsButton(title: tab.rawValue, id: "network.tab.\(tab)", error: model.errorTabs.contains(tab), selected: model.tab == tab) { model.tab = tab }
                        .frame(maxWidth: .infinity).frame(height: 26)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.tab {
                    case .sites: sites
                    case .egress: egress
                    case .proxy: proxy
                    case .frequency: frequency
                    }
                }.padding(.trailing, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text(model.statusText).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("network.status")
            HStack {
                if model.tab == .sites { Button("恢复默认站点") { network.settingsDraft.restoreDefaultSites() } }
                Spacer()
                NetworkSettingsButton(title: "取消", id: "network.cancel", key: "\u{1b}") { model.cancel() }.frame(width: 64, height: 26)
                NetworkSettingsButton(title: "保存", id: "network.save", enabled: network.canSaveSettings, key: "\r") { model.save() }.frame(width: 64, height: 26)
            }
        }.padding(20).frame(width: 560, height: 720).background(Color(nsColor: .windowBackgroundColor))
    }
    private func field(_ title: String, _ value: Binding<String>, error: String? = nil, id: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            NetworkSettingsTextField(value: value, placeholder: title, id: id ?? title).frame(height: 24)
            errorText(error)
        }
    }
    @ViewBuilder private func errorText(_ text: String?) -> some View {
        if let text { Text(text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
    }
    private var sites: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("公开站点").font(.headline)
            Text("最多 20 个；后台检测只访问勾选“后台检测”的站点。").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(network.settingsDraft.sites.indices), id: \.self) { i in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("启用", isOn: $network.settingsDraft.sites[i].isEnabled)
                            Toggle("后台检测", isOn: $network.settingsDraft.sites[i].inLightProbe)
                            Button("移除") { network.settingsDraft.sites.remove(at: i) }
                        }
                        HStack {
                            field("名称", $network.settingsDraft.sites[i].name, error: validation.siteErrors[i]?.name)
                            field("分组", $network.settingsDraft.sites[i].groupText, error: validation.siteErrors[i]?.group)
                        }
                        field("URL", $network.settingsDraft.sites[i].url, error: validation.siteErrors[i]?.url)
                        errorText(validation.siteErrors[i]?.id)
                    }.padding(4)
                }
            }
            Button("添加站点") { network.settingsDraft.addSite() }.disabled(network.settingsDraft.sites.count >= 20)
            errorText(validation.siteCountError)
            Divider()
            field("VPN 内网站点（可留空）", $network.settingsDraft.intranetURL, error: validation.intranetURLError)
            field("Tailnet 目标（IPv4:端口，可留空）", $network.settingsDraft.tailnetTarget, error: validation.tailnetTargetError)
        }
    }
    private var egress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("出口监测").font(.headline)
            Toggle("自动检测出口 IP", isOn: $network.settingsDraft.egressAutomatic)
            field("检测间隔（分钟）", $network.settingsDraft.egressIntervalMinutes, error: validation.egressMonitoringError)
            Toggle("出口 IP 变化时通知", isOn: $network.settingsDraft.egressNotifyIPChanges)
            Text("出口目标").font(.headline)
            ForEach(EgressIPTarget.builtIns, id: \.rawValue) { target in
                if target == .cloudflare { Text("Cloudflare（始终检测）").font(.callout) }
                else { Toggle(target.displayName, isOn: Binding(get: { network.settingsDraft.enabledEgressBuiltIns.contains(target) }, set: { network.settingsDraft.setEgressBuiltIn(target, enabled: $0) })) }
            }
            ForEach(Array(network.settingsDraft.customEgressHosts.indices), id: \.self) { i in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("自定义目标 \(i + 1)").font(.callout)
                            Spacer(); Button("移除") { network.settingsDraft.customEgressHosts.remove(at: i) }
                        }
                        Picker("检测方式", selection: $network.settingsDraft.customEgressHosts[i].method) {
                            Text("域名").tag(Optional<EgressEndpoint.Method>.none)
                            Text("响应头").tag(Optional(EgressEndpoint.Method.header))
                            Text("JSON 字段").tag(Optional(EgressEndpoint.Method.json))
                        }
                        field("域名或 HTTPS URL", $network.settingsDraft.customEgressHosts[i].host, error: validation.egressHostErrors[i])
                        if network.settingsDraft.customEgressHosts[i].method != nil {
                            field("名称", $network.settingsDraft.customEgressHosts[i].name)
                            field("响应头或 JSON 字段路径", $network.settingsDraft.customEgressHosts[i].selector)
                        }
                    }.padding(4)
                }
            }
            Button("添加自定义目标") { network.settingsDraft.customEgressHosts.append(.init()) }.disabled(network.settingsDraft.customEgressHosts.count >= EgressIPTarget.maxCustom)
            Divider()
            Text("允许地区").font(.headline)
            Text("空选表示只记录；连续偏离所选地区时提醒。").font(.caption).foregroundStyle(.secondary)
            ForEach(network.settingsDraft.draftEgressTargets, id: \.rawValue) { target in
                HStack {
                    Text(target.displayName).lineLimit(1)
                    Spacer()
                    Menu(regionLabel(target)) {
                        ForEach(EgressRegions.common + EgressRegions.all.filter { !EgressRegions.common.contains($0) }, id: \.self) { code in
                            Toggle(EgressRegions.name(code), isOn: Binding(get: { network.settingsDraft.egressAllowedRegions[target.rawValue, default: []].contains(code) }, set: { selected in
                                if selected { network.settingsDraft.egressAllowedRegions[target.rawValue, default: []].insert(code) }
                                else { network.settingsDraft.egressAllowedRegions[target.rawValue, default: []].remove(code) }
                            }))
                        }
                        Button("清空") { network.settingsDraft.egressAllowedRegions[target.rawValue] = [] }
                    }
                }
            }
        }
    }
    private func regionLabel(_ target: EgressIPTarget) -> String {
        let regions = network.settingsDraft.egressAllowedRegions[target.rawValue, default: []]
        return regions.isEmpty ? "只记录" : regions.sorted().map(EgressRegions.name).joined(separator: "、")
    }
    private var proxy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("代理客户端").font(.headline)
            Picker("客户端", selection: $network.settingsDraft.proxyClient) {
                ForEach(ProxyClientKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if network.settingsDraft.proxyClient == .manual {
                field("fake-ip 网段", $network.settingsDraft.manualFakeIPRange, error: validation.manualFakeIPRangeError)
                field("DNS 端口（可留空）", $network.settingsDraft.manualDNSPort, error: validation.manualDNSPortError)
                field("核心进程名（可留空）", $network.settingsDraft.manualProcessName, error: validation.manualProcessNameError)
            }
            NetworkSettingsButton(title: "站点失败时诊断代理", id: "network.proxyDiagnostics", checked: network.settingsDraft.proxyDiagnosticsEnabled) {
                network.settingsDraft.proxyDiagnosticsEnabled.toggle()
            }.frame(height: 24)
            Divider()
            Text("DNS 规则").font(.headline)
            Picker("VPN 断开时", selection: $network.settingsDraft.disconnectedDNSRule) {
                ForEach(DisconnectedDNSRule.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if network.settingsDraft.disconnectedDNSRule == .equals {
                field("预期 DNS（逗号分隔）", $network.settingsDraft.expectedDNS, error: validation.expectedDNSError)
            } else { errorText(validation.expectedDNSError) }
            Picker("VPN 连接时", selection: $network.settingsDraft.connectedDNSRule) {
                ForEach(ConnectedDNSRule.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("TUN 关闭后提醒 DNS 残留", isOn: $network.settingsDraft.residualDNSWarning)
            field("探针域名", $network.settingsDraft.canaryHost, error: validation.canaryHostError)
            Text("这些设置只改变检测预期，不修改系统 DNS 或代理配置。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var frequency: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("检测频率").font(.headline)
            field("本机检查间隔（秒）", $network.settingsDraft.localCheckInterval, error: validation.localCheckIntervalError, id: "network.localInterval")
            Text("5–3600 秒；检查 TUN、DNS 和连接状态。").font(.caption).foregroundStyle(.secondary)
            field("后台站点检测间隔（秒）", $network.settingsDraft.lightProbeInterval, error: validation.lightProbeIntervalError, id: "network.lightInterval")
            Text("15–86400 秒；只检测勾选后台检测的站点。").font(.caption).foregroundStyle(.secondary)
            Text("出口检测间隔在“出口 IP”页单独设置。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NetworkSettingsButton: NSViewRepresentable {
    var title: String, id: String
    var enabled = true, error = false, selected = false
    var key = ""
    var checked: Bool? = nil
    var action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.invoke))
        button.bezelStyle = .rounded; button.setAccessibilityIdentifier(id)
        if checked != nil { button.setButtonType(.switch) }
        button.keyEquivalent = key
        if key == "\u{1b}" { button.keyEquivalentModifierMask = [] }
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action; button.isEnabled = enabled
        if let checked { button.state = checked ? .on : .off }
        // 选中分页只用强调色粗体文字标出，底色保持普通按钮；底色也用强调色会让标题看不见。
        button.bezelColor = nil
        let color = !enabled ? NSColor.disabledControlTextColor : (selected ? NSColor.controlAccentColor : NSColor.labelColor)
        let text = NSMutableAttributedString(string: title, attributes: [.foregroundColor: color, .font: selected ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)])
        if error { text.append(NSAttributedString(string: " ●", attributes: [.foregroundColor: NSColor.systemRed])) }
        button.attributedTitle = text; button.setAccessibilityLabel(title + (error ? "，此页有错误" : ""))
    }
}

private struct NetworkSettingsTextField: NSViewRepresentable {
    @Binding var value: String
    var placeholder: String, id: String
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var value: Binding<String>
        init(_ value: Binding<String>) { self.value = value }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { value.wrappedValue = field.stringValue }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator($value) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(); field.bezelStyle = .roundedBezel; field.delegate = context.coordinator
        field.placeholderString = placeholder; field.setAccessibilityIdentifier(id); field.setAccessibilityLabel(placeholder)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.value = $value
        if field.stringValue != value { field.stringValue = value }
    }
}
