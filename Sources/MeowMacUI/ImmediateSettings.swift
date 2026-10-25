import AppKit
import SwiftUI
import MeowMacCore

/// 即时设置始终读取 PanelState 的回传值，不在界面中预先假定保存成功。
@MainActor
public struct ImmediateSettingsActions {
    public let state: PanelState
    public init(state: PanelState) { self.state = state }
    public struct CatOption: Identifiable {
        public let id: String, title: String
        public let selected: Bool
    }
    public var cats: [CatOption] {
        let builtin = CatPackageLoader.builtinIDs.compactMap { try? CatPackageLoader.builtin($0) }
        let imported = (state.catStore?.importedCats() ?? []).sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let all = builtin + imported
        let counts = Dictionary(grouping: all, by: \.name).mapValues(\.count)
        return all.map { cat in CatOption(id: cat.id, title: counts[cat.name, default: 0] > 1 ? "\(cat.name)（\(cat.id)）" : cat.name, selected: state.selectedCat?.id == cat.id) }
    }
    public func terminalTitle(_ terminal: CleanTerminal) -> String {
        if terminal == .automatic, let current = terminal.resolved(available: state.availableCleanTerminals) { return "自动（当前：" + current.name + "）" }
        return terminal.name
    }
    public func terminalEnabled(_ terminal: CleanTerminal) -> Bool { terminal == .automatic || state.availableCleanTerminals.contains(terminal) }
    public func selectTerminal(_ terminal: CleanTerminal) { guard terminalEnabled(terminal) else { return }; state.onSelectCleanTerminal(terminal) }
    public var installedAgents: Set<AIAgent> { Set(state.aiAgentInstallations.map(\.agent)) }
    public func agentEnabled(_ agent: AIAgent) -> Bool { agent == .automatic || installedAgents.contains(agent) }
    public func selectAgent(_ agent: AIAgent) { guard agentEnabled(agent) else { return }; state.onSelectAIAgent(agent) }
    public func setAIEntry(_ enabled: Bool) { state.onSetAIDiagnosisEntry(enabled) }
    public func detectAgents() { state.onDetectAIAgents() }
    public func setLogin(_ enabled: Bool) { state.onToggleLogin(enabled) }
    public func selectCat(_ id: String) { state.onSelectCat(id) }
    /// 菜单栏形象选项：与桌面猫相同（默认）、当前猫、本机 Codex 宠物（plan P6）。
    public struct MenuBarPetOption: Identifiable, Equatable {
        public let id: String, title: String
        public let value: MenuBarPetConfig
    }
    public var menuBarPetOptions: [MenuBarPetOption] {
        let pets = CodexPetLibrary.list(root: state.codexPetsRoot)
        func name(_ id: String) -> String { pets.first(where: { $0.id == id })?.name ?? id }
        let shared = state.desktopCat.pet.map { "与桌面猫相同（当前：\(name($0))）" } ?? "与桌面猫相同（当前：猫）"
        var options = [MenuBarPetOption(id: "desktop", title: shared, value: .desktop),
                       MenuBarPetOption(id: "cat", title: "当前猫", value: .cat)]
        options += pets.map { MenuBarPetOption(id: "pet:" + $0.id, title: $0.name == $0.id ? $0.name : "\($0.name)（\($0.id)）", value: .pet($0.id)) }
        if case .pet(let current) = state.menuBarPet, !pets.contains(where: { $0.id == current }) {
            options.append(MenuBarPetOption(id: "pet:" + current, title: "\(current)（不可用）", value: .pet(current)))
        }
        return options
    }
    public var menuBarPetSelection: String {
        switch state.menuBarPet {
        case .desktop: return "desktop"
        case .cat: return "cat"
        case .pet(let id): return "pet:" + id
        }
    }
    public func selectMenuBarPet(_ id: String) {
        guard let option = menuBarPetOptions.first(where: { $0.id == id }) else { return }
        state.updateMenuBarPet(option.value)
    }
    public func importHistory() { guard state.showsCodexBarImport else { return }; state.onImportCodexBarHistory() }
    public func setNotifications(_ enabled: Bool) { var next = state.notificationSettings; next.enabled = enabled; state.onSetNotificationSettings(next) }
    public func setCategory(_ category: NotificationCategory, enabled: Bool) {
        guard state.notificationSettings.enabled else { return }
        var next = state.notificationSettings
        if enabled { next.categories.insert(category) } else { next.categories.remove(category) }
        state.onSetNotificationSettings(next)
    }
}

struct ImmediateSettingsView: View {
    @ObservedObject var state: PanelState
    let section: SettingsSection
    private var actions: ImmediateSettingsActions { ImmediateSettingsActions(state: state) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch section {
                case .general: general
                case .cats: cats
                case .notifications: notifications
                default: EmptyView()
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("启动").font(.headline)
            GroupBox {
                SettingsImmediateToggle(title: "登录时启动 MeowMac", id: "settings.login", value: Binding(get: { state.loginEnabled }, set: actions.setLogin)).frame(height: 24)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("终端").font(.headline)
            Text("清理和 AI 排查的命令行工具在这里打开").font(.caption).foregroundStyle(.secondary)
            GroupBox {
                Picker("终端", selection: Binding(get: { state.cleanTerminalPreference }, set: actions.selectTerminal)) {
                    ForEach(CleanTerminal.allCases, id: \.self) { terminal in
                        Text(actions.terminalTitle(terminal)).tag(terminal).disabled(!actions.terminalEnabled(terminal))
                    }
                }.accessibilityIdentifier("settings.terminal").padding(8)
            }
            aiDiagnosis
            Text("数据").font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    if state.showsCodexBarImport {
                        HStack { Text("导入 CodexBar 历史"); Spacer(); SettingsActionButton(title: "导入…", id: "settings.history") { actions.importHistory() }.frame(width: 72, height: 28) }
                        Text("一次性导入 CodexBar 已有的额度历史").font(.caption).foregroundStyle(.secondary)
                        Divider()
                    }
                    Text("配置文件").fontWeight(.semibold)
                    Text("阈值等未在界面中提供的配置").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("打开配置文件…", action: state.onOpenConfig).accessibilityIdentifier("settings.config")
                        Button("在访达中显示", action: state.onShowConfigFolder).accessibilityIdentifier("settings.config-folder")
                    }.buttonStyle(.link)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var aiDiagnosis: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 诊断").font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsImmediateToggle(title: "显示‘用 AI 排查’入口", id: "settings.ai-entry", value: Binding(get: { state.aiDiagnosisEntry }, set: actions.setAIEntry)).frame(height: 24)
                    HStack {
                        Text("默认 agent")
                        Spacer()
                        AIAgentPicker(agents: AIAgent.allCases, available: actions.installedAgents, id: "settings.ai-agent",
                            selection: Binding(get: { state.aiAgentPreference }, set: { if let agent = $0 { actions.selectAgent(agent) } }))
                            .frame(width: 260, height: 28)
                    }
                    Divider()
                    HStack {
                        Text("检测结果").fontWeight(.semibold)
                        Spacer()
                        SettingsActionButton(title: "重新检测", id: "settings.ai-detect", action: actions.detectAgents).frame(width: 88, height: 28)
                    }
                    ForEach(AIAgent.agents, id: \.self) { agent in
                        let installed = state.aiAgentInstallations.first { $0.agent == agent }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(agent.name)
                                Spacer(minLength: 8)
                                Text(installed == nil ? "未安装" : "已安装").foregroundStyle(.secondary)
                                Text(agent.launchDescription).foregroundStyle(.secondary).frame(width: 116, alignment: .trailing)
                            }
                            if let directory = installed?.displayDirectory(home: FileManager.default.homeDirectoryForCurrentUser.path) {
                                Text(directory).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }.font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = state.aiSettingsError { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var cats: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("菜单栏的猫").font(.headline)
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(actions.cats) { cat in
                        if cat.id != actions.cats.first?.id { Divider() }
                        Button { actions.selectCat(cat.id) } label: {
                            HStack {
                                Image(systemName: cat.selected ? "checkmark.circle.fill" : "circle").foregroundStyle(cat.selected ? Color.accentColor : Color.secondary)
                                Text(cat.title); Spacer()
                                Text(cat.id.hasPrefix("builtin.") ? "内置" : "导入").font(.caption).foregroundStyle(.secondary)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("settings.cat." + cat.id)
                    }
                }
            }
            HStack {
                Button("导入猫配置…", action: state.onImportCat).accessibilityIdentifier("settings.import-cat")
                Button("在访达中显示猫配置", action: state.onShowCats).buttonStyle(.link).accessibilityIdentifier("settings.show-cats")
            }
            Text("猫包里的布局在“外观 → 布局与显示”中调整。").font(.caption).foregroundStyle(.secondary)
            Text("菜单栏形象").font(.headline).padding(.top, 6)
            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("菜单栏显示")
                        Text("默认与桌面猫的形象相同；也可单独选当前猫或 Codex 宠物").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("菜单栏显示", selection: Binding(get: { actions.menuBarPetSelection }, set: actions.selectMenuBarPet)) {
                        ForEach(actions.menuBarPetOptions) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: 240)
                    .accessibilityIdentifier("settings.menu-bar-pet")
                }.padding(8)
            }
            Text("宠物只读 ~/.codex/pets。菜单栏的宠物照常奔跑，提醒整只变橙，严重变红并停在倒地的一帧。").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = state.menuBarPetSaveError ?? state.menuBarPetError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.menu-bar-pet-error")
            }
        }
    }
    private var notifications: some View {
        VStack(alignment: .leading, spacing: 18) {
            if state.notificationsAuthorized == false {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("系统通知未授权，MeowMac 发不出通知。").foregroundStyle(.orange)
                        Button("打开系统设置…", action: state.onOpenNotificationSystemSettings).buttonStyle(.link).accessibilityIdentifier("settings.notification-permission")
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("settings.notification-banner")
            }
            Text("系统通知").font(.headline)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsImmediateToggle(title: "发送系统通知", id: "settings.notifications", value: Binding(get: { state.notificationSettings.enabled }, set: actions.setNotifications)).frame(height: 24)
                    Text("提醒被确认出现时发送；同一问题持续期间只发一次").font(.caption).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Text("类别").font(.headline); Spacer(); Text("降温提示只保留标记，不通知").font(.caption).foregroundStyle(.secondary) }
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(NotificationCategory.allCases, id: \.self) { category in
                        if category != NotificationCategory.allCases.first { Divider() }
                        SettingsImmediateToggle(title: category.displayName, id: "settings.notification." + category.rawValue, value: Binding(get: { state.notificationSettings.categories.contains(category) }, set: { actions.setCategory(category, enabled: $0) }), enabled: state.notificationSettings.enabled)
                            .frame(height: 24).padding(.vertical, 7)
                    }
                }.padding(.horizontal, 8)
            }
        }
    }
}

struct SettingsImmediateToggle: View {
    let title: String, id: String
    @Binding var value: Bool
    var enabled = true
    var body: some View { HStack { Text(title); Spacer(); NativeSettingsSwitch(id: id, value: $value, enabled: enabled).frame(width: 38, height: 24) } }
}

struct NativeSettingsSwitch: NSViewRepresentable {
    let id: String
    @Binding var value: Bool
    var enabled: Bool
    @MainActor final class Coordinator: NSObject {
        var binding: Binding<Bool>
        init(_ binding: Binding<Bool>) { self.binding = binding }
        @objc func invoke(_ sender: NSSwitch) {
            binding.wrappedValue = sender.state == .on
            // 回调可能拒绝修改，立即恢复到实际回传值。
            sender.state = binding.wrappedValue ? .on : .off
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator($value) }
    func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.target = context.coordinator; control.action = #selector(Coordinator.invoke(_:))
        control.setAccessibilityIdentifier(id)
        return control
    }
    func updateNSView(_ control: NSSwitch, context: Context) { context.coordinator.binding = $value; control.state = value ? .on : .off; control.isEnabled = enabled }
}
