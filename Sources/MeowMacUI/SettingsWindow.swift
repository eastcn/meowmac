import AppKit
import Combine
import SwiftUI
import MeowMacCore
import MeowMacQuota
import TunCanaryUI

public enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, cats, network, quotaSources, notifications
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .cats: return "猫"
        case .network: return "网络"
        case .quotaSources: return "额度源"
        case .notifications: return "通知"
        }
    }
    public var subtitle: String {
        switch self {
        case .general: return "更改立即生效"
        case .appearance: return "样式所有猫共用；布局与显示属于当前猫"
        case .cats: return "选择后立即切换菜单栏的猫"
        case .network: return "检测引擎：TunCanary。保存后立即重新检测"
        case .quotaSources: return "数据来源：CodexBarCLI。启用状态与 CodexBar 共用"
        case .notifications: return "由 MeowMac 统一发送，更改立即生效"
        }
    }
    public var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "circle.lefthalf.filled"
        case .cats: return "pawprint.fill"
        case .network: return "network"
        case .quotaSources: return "chart.bar.fill"
        case .notifications: return "bell.fill"
        }
    }
    var color: Color {
        switch self {
        case .general: return .gray
        case .appearance: return .indigo
        case .cats: return .orange
        case .network: return .cyan
        case .quotaSources: return .green
        case .notifications: return .red
        }
    }
}

@MainActor
public protocol SettingsDraftSession: AnyObject {
    var isDirty: Bool { get }
    var canSave: Bool { get }
    var isBusy: Bool { get }
    var statusText: String { get }
    func save() async -> Bool
    func discard()
}

/// 窗口和 sheet 共用此离开流程，保存失败始终留在当前栏目。
@MainActor
public final class SettingsNavigation: ObservableObject {
    public enum Destination: Equatable { case section(SettingsSection), close }
    public enum Choice { case save, discard, keepEditing }
    @Published public private(set) var section: SettingsSection = .general
    @Published public private(set) var pending: Destination?
    @Published public private(set) var saving = false
    public var sessions: [SettingsSection: any SettingsDraftSession] = [:]
    public var onClose: () -> Void = {}
    public var onEnter: (SettingsSection) -> Void = { _ in }
    public var onLeave: (SettingsSection) -> Void = { _ in }
    public init() {}
    public var current: (any SettingsDraftSession)? { sessions[section] }
    @discardableResult public func request(_ destination: Destination) -> Bool {
        guard !saving, current?.isBusy != true, pending == nil else { return false }
        if destination == .section(section) { return true }
        if current?.isDirty == true { pending = destination; return false }
        proceed(destination); return true
    }
    public func resolve(_ choice: Choice) async {
        guard let destination = pending, !saving else { return }
        switch choice {
        case .keepEditing: pending = nil
        case .discard: current?.discard(); pending = nil; proceed(destination)
        case .save:
            saving = true
            let success = await current?.save() ?? true
            saving = false; pending = nil
            if success { proceed(destination) }
        }
        objectWillChange.send()
    }
    public func saveCurrent() async -> Bool {
        guard !saving, current?.isBusy != true, let current else { return false }
        saving = true
        let success = await current.save()
        saving = false; objectWillChange.send()
        return success
    }
    public func discardCurrent() { guard !saving, current?.isBusy != true else { return }; current?.discard(); objectWillChange.send() }
    private func proceed(_ destination: Destination) {
        onLeave(section)
        switch destination {
        case .section(let next): section = next; onEnter(next)
        case .close: onClose()
        }
    }
}

public enum SettingsShortcut {
    public static func matches(characters: String?, modifiers: NSEvent.ModifierFlags, appActive: Bool, ownsWindow: Bool) -> Bool {
        appActive && ownsWindow && characters == "," && modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad]) == .command
    }
}

@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public private(set) var window: NSWindow?
    public let navigation = SettingsNavigation()
    public let state: PanelState
    public private(set) var appearance: AppearanceSettingsModel
    public private(set) var network: NetworkSettingsModel?
    public private(set) var quotaSources: QuotaSourceSettingsModel?
    private let networkModel: AppModel?
    private let quotaCoordinator: QuotaCoordinator?
    private let quotaCatalog: [QuotaCatalogEntry]
    public var sectionViews: [SettingsSection: () -> AnyView] = [:]
    public var onOpen: (SettingsSection, Bool) -> Void = { _, _ in }
    public var ownsWindow: (NSWindow) -> Bool = { _ in false }
    private var subscriptions: Set<AnyCancellable> = []
    private var shortcutMonitor: Any?
    public init(state: PanelState, network: AppModel? = nil, quotaCoordinator: QuotaCoordinator? = nil, quotaCatalog: [QuotaCatalogEntry] = []) {
        self.state = state
        self.networkModel = network; self.quotaCoordinator = quotaCoordinator; self.quotaCatalog = quotaCatalog
        appearance = AppearanceSettingsModel(state: state)
        self.network = network.map { NetworkSettingsModel(network: $0) }
        quotaSources = quotaCoordinator.map { QuotaSourceSettingsModel(state: state, coordinator: $0, catalog: quotaCatalog) }
        super.init()
        navigation.onClose = { [weak self] in self?.closeWithoutConfirmation() }
        navigation.onEnter = { [weak self] section in self?.prepare(section) }
    }
    public func observe<T: ObservableObject>(_ model: T) where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        model.objectWillChange.sink { [weak navigation] in navigation?.objectWillChange.send() }.store(in: &subscriptions)
    }
    public func installShortcutMonitor() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let owned = event.window.map { $0 === self.window || self.ownsWindow($0) } ?? false
            if SettingsShortcut.matches(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags, appActive: NSApp.isActive, ownsWindow: owned) {
                self.open(); return nil
            }
            return event
        }
    }
    public func removeShortcutMonitor() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }; shortcutMonitor = nil
    }
    public func open(section: SettingsSection? = nil, load: Bool = true) {
        if window == nil {
            resetSessions(load: load)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "设置"; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentMinSize = NSSize(width: 760, height: 460)
            window.contentMaxSize = NSSize(width: 760, height: 1200)
            window.contentView = NSHostingView(rootView: SettingsWindowView(controller: self))
            self.window = window
            window.setContentSize(NSSize(width: 760, height: 620)); window.center()
            onOpen(section ?? navigation.section, load)
            prepare(navigation.section)
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if let section { request(.section(section)) }
    }
    private func resetSessions(load: Bool) {
        subscriptions.removeAll()
        appearance = AppearanceSettingsModel(state: state)
        network = networkModel.map { NetworkSettingsModel(network: $0) }
        network?.open()
        quotaSources = quotaCoordinator.map { QuotaSourceSettingsModel(state: state, coordinator: $0, catalog: quotaCatalog) }
        navigation.sessions = [.appearance: appearance]
        for section in [SettingsSection.general, .cats, .notifications] {
            sectionViews[section] = { [state] in AnyView(ImmediateSettingsView(state: state, section: section)) }
        }
        observe(appearance); observe(state)
        sectionViews[.appearance] = { [weak self] in guard let self else { return AnyView(EmptyView()) }; return AnyView(AppearanceSettingsView(model: self.appearance, state: self.state)) }
        if let network {
            navigation.sessions[.network] = network; observe(network)
            sectionViews[.network] = { AnyView(NetworkSettingsView(model: network)) }
        }
        if let quotaSources {
            navigation.sessions[.quotaSources] = quotaSources; observe(quotaSources)
            sectionViews[.quotaSources] = { [state] in AnyView(QuotaSourceSettingsView(model: quotaSources, state: state)) }
            if load { Task { await quotaSources.load() } }
        }
        navigation.onLeave = { [weak self] section in if section == .quotaSources { self?.quotaSources?.close() } }
    }
    public func catDidChange() { appearance.catDidChange() }
    private func prepare(_ section: SettingsSection) {
        if section == .general { state.onPrepareCleanTerminalMenu() }
        if section == .notifications { state.onPrepareNotificationMenu() }
    }
    public func request(_ destination: SettingsNavigation.Destination) {
        guard !navigation.request(destination), navigation.pending != nil, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "“\(navigation.section.title)”有未保存的修改"
        alert.informativeText = "离开前，要保存这些修改吗？"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "放弃修改"); alert.addButton(withTitle: "继续编辑")
        alert.buttons[0].isEnabled = navigation.current?.canSave == true
        alert.beginSheetModal(for: window) { [weak self] response in
            let choice: SettingsNavigation.Choice = response == .alertFirstButtonReturn ? .save : response == .alertSecondButtonReturn ? .discard : .keepEditing
            Task { @MainActor in await self?.navigation.resolve(choice) }
        }
    }
    public func closeWithoutConfirmation() { window?.close() }
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        request(.close); return false
    }
    public func windowWillClose(_ notification: Notification) { quotaSources?.close(); network?.discard(); network?.network.route = .main; window?.delegate = nil; window = nil }
}

public struct SettingsActionButton: NSViewRepresentable {
    public let title: String, id: String
    public var enabled = true
    public var action: () -> Void
    public init(title: String, id: String, enabled: Bool = true, action: @escaping () -> Void) { self.title = title; self.id = id; self.enabled = enabled; self.action = action }
    public final class Coordinator: NSObject {
        var action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
    public func makeCoordinator() -> Coordinator { Coordinator(action) }
    public func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.invoke))
        button.bezelStyle = .rounded; button.setAccessibilityIdentifier(id)
        return button
    }
    public func updateNSView(_ button: NSButton, context: Context) { context.coordinator.action = action; button.title = title; button.isEnabled = enabled }
}

struct SettingsWindowView: View {
    let controller: SettingsWindowController
    @ObservedObject var navigation: SettingsNavigation
    init(controller: SettingsWindowController) { self.controller = controller; navigation = controller.navigation }
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List {
                ForEach(SettingsSection.allCases) { section in
                    Button { controller.request(.section(section)) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: section.symbol).foregroundStyle(.white).frame(width: 22, height: 22).background(section.color, in: RoundedRectangle(cornerRadius: 6))
                            Text(section.title)
                            Spacer()
                            if navigation.sessions[section]?.isDirty == true { Circle().fill(.orange).frame(width: 7, height: 7).accessibilityLabel("有未保存的修改") }
                        }.padding(.vertical, 3).contentShape(Rectangle())
                    }.buttonStyle(.plain).listRowBackground(navigation.section == section ? Color.accentColor.opacity(0.16) : Color.clear)
                        .accessibilityIdentifier("settings.section." + section.rawValue)
                        .accessibilityAddTraits(navigation.section == section ? .isSelected : [])
                }
            }.listStyle(.sidebar).frame(width: 190)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 190, ideal: 190, max: 190)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(navigation.section.title).font(.system(size: 15, weight: .semibold))
                    Text(navigation.section.subtitle).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.vertical, 12)
                Divider()
                if let view = controller.sectionViews[navigation.section] { view().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                else { Spacer() }
                Divider()
                HStack(spacing: 8) {
                    Text(navigation.current?.statusText ?? "更改立即生效").font(.caption).foregroundStyle(navigation.section == .quotaSources && controller.quotaSources?.errors.isEmpty == false ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier(navigation.section == .network ? "network.status" : navigation.section == .quotaSources ? "quota-source.status" : "settings.status")
                    if let session = navigation.current {
                        let prefix = navigation.section == .network ? "network" : navigation.section == .quotaSources ? "quota-source" : "settings"
                        SettingsActionButton(title: "取消", id: prefix + ".cancel", enabled: session.isDirty && !session.isBusy && !navigation.saving) { navigation.discardCurrent() }.frame(width: 64, height: 28)
                        SettingsActionButton(title: "保存", id: prefix + ".save", enabled: session.canSave && !navigation.saving) { Task { await navigation.saveCurrent() } }.frame(width: 64, height: 28)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
        }.navigationSplitViewStyle(.balanced)
    }
}
