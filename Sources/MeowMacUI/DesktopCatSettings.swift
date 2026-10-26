import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MeowMacCore

/// 设置 › 外观 › 桌面猫（D6）。所有修改即时写配置，不进外观栏的“取消 / 保存”草稿。
@MainActor
public struct DesktopCatSettingsActions {
    public let state: PanelState
    public var screens: () -> [DesktopCatScreen] = { DesktopCatController.systemScreens() }
    public var screenNames: () -> [String: String] = {
        Dictionary(NSScreen.screens.compactMap { screen in DesktopCatController.displayID(screen).map { ($0, screen.localizedName) } },
                   uniquingKeysWith: { first, _ in first })
    }
    public init(state: PanelState) { self.state = state }

    public struct Row: Equatable, Identifiable {
        public let id: String, title: String, value: String
        public let canRemove: Bool
    }
    public var rows: [Row] {
        let inputs = state.desktopCatInputs
        let items = DesktopCatCatalog.items(selected: state.desktopCat.metrics, inputs: inputs)
        let canRemove = state.desktopCat.metrics.count > 1
        return items.map { item in
            let value = item.missing ? "—" : item.note.map { item.value + " " + $0 } ?? item.value
            return Row(id: item.id, title: DesktopCatCatalog.title(for: item.id, inputs: inputs), value: value, canRemove: canRemove)
        }
    }
    public var canAdd: Bool { state.desktopCat.metrics.count < DesktopCatConfig.maxMetrics }
    public var countText: String { "已选 \(state.desktopCat.metrics.count) / \(DesktopCatConfig.maxMetrics) · 拖动调整顺序" }

    public func setEnabled(_ enabled: Bool) { state.updateDesktopCat { $0.with(enabled: enabled) } }
    public func remove(_ id: String) { state.updateDesktopCat { try $0.removing(id) } }
    public func add(_ id: String) { state.updateDesktopCat { try $0.adding(id) } }
    /// 拖到目标行：往下拖时放在目标之后，往上拖时放在目标之前。
    public func move(_ id: String, onto target: String) {
        let metrics = state.desktopCat.metrics
        guard id != target, let from = metrics.firstIndex(of: id), let to = metrics.firstIndex(of: target) else { return }
        let remaining = metrics.filter { $0 != id }
        guard let index = remaining.firstIndex(of: target) else { return }
        state.updateDesktopCat { try $0.moving(id, to: from < to ? index + 1 : index) }
    }
    public func move(_ id: String, offset: Int) {
        guard let index = state.desktopCat.metrics.firstIndex(of: id) else { return }
        state.updateDesktopCat { try $0.moving(id, to: index + offset) }
    }
    /// 形象选项：第一项“跟随当前猫”，其余是 `$CODEX_HOME/pets` 里清单有效的宠物（plan P1）。
    /// 已选的宠物不在列表里时仍列出，标“不可用”，方便换回。
    public struct PetOption: Equatable, Identifiable {
        public let id: String, title: String
        public let pet: String?
    }
    public static let followCatTitle = "跟随当前猫"
    public var petOptions: [PetOption] {
        var options = [PetOption(id: "", title: Self.followCatTitle, pet: nil)]
        let pets = CodexPetLibrary.list(root: state.codexPetsRoot)
        options += pets.map { PetOption(id: $0.id, title: $0.name == $0.id ? $0.name : "\($0.name)（\($0.id)）", pet: $0.id) }
        if let current = state.desktopCat.pet, !pets.contains(where: { $0.id == current }) {
            options.append(PetOption(id: current, title: "\(current)（不可用）", pet: current))
        }
        return options
    }
    public func setPet(_ id: String?) { state.updateDesktopCat { $0.with(pet: id) } }

    /// 大小（plan D15）：滑块 36～104 pt，松手写入；“恢复默认大小”回到 52 pt。
    public var catHeight: Double { Double(DesktopCatSize.rendered(state.desktopCat.catHeight)) }
    public var isDefaultSize: Bool { catHeight == Double(DesktopCatSize.defaultHeight) }
    public func setCatHeight(_ height: Double) { state.updateDesktopCatHeight(height) }
    public func resetSize() { setCatHeight(Double(DesktopCatSize.defaultHeight)) }
    public static func sizeText(_ height: Double) -> String { "\(Int(DesktopCatSize.resolved(CGFloat(height)))) pt" }

    /// 不透明度（D48）：滑块 20%～100%，拖动时只改桌面猫的显示，松手写配置；“恢复默认”一次把两项设回 100%。
    /// 滑块位置和百分比按四舍五入到 5% 显示；拖动中显示草稿。
    public func opacity(_ part: DesktopCatOpacityPart) -> Double {
        DesktopCatOpacity.sliderValue(state.desktopCatOpacityDraft[part] ?? state.desktopCat.opacity(part))
    }
    public var isDefaultOpacity: Bool {
        DesktopCatOpacityPart.allCases.allSatisfy { DesktopCatOpacity.rendered(state.desktopCat.opacity($0)) == DesktopCatOpacity.defaultValue }
    }
    /// 拖动中：吸附到 5%，只更新草稿，桌面猫跟着变，不写配置。
    public func dragOpacity(_ part: DesktopCatOpacityPart, to value: Double) {
        let next = DesktopCatOpacity.resolved(value)
        if state.desktopCatOpacityDraft[part] != next { state.desktopCatOpacityDraft[part] = next }
    }
    /// 松手：写一次配置并清掉草稿。写入失败时显示原因，滑块和桌面猫回到原值。
    public func commitOpacity(_ part: DesktopCatOpacityPart) {
        guard let value = state.desktopCatOpacityDraft[part] else { return }
        state.updateDesktopCatOpacity([part: value])
        state.desktopCatOpacityDraft[part] = nil
    }
    public func resetOpacity() {
        state.desktopCatOpacityDraft = [:]
        state.updateDesktopCatOpacity(Dictionary(uniqueKeysWithValues: DesktopCatOpacityPart.allCases.map { ($0, DesktopCatOpacity.defaultValue) }))
    }
    public static func opacityText(_ value: Double) -> String { DesktopCatOpacity.percentText(value) }

    public var isDefaultPosition: Bool { state.desktopCat.placement == .default }
    /// 放回主屏右下角。
    public func resetPosition() { state.updateDesktopCat { $0.with(placement: .default) } }

    /// 位置文字，例如“内建显示器 · 右下角”；屏幕不在时写明暂放主屏。
    public var positionText: String {
        Self.positionText(state.desktopCat.placement, screens: screens(), names: screenNames())
    }
    public static func positionText(_ placement: DesktopCatPlacement, screens: [DesktopCatScreen], names: [String: String]) -> String {
        let main = screens.first(where: \.isMain)
        guard let id = placement.display, id != main?.id else {
            return (main.flatMap { names[$0.id] } ?? "主屏幕") + " · " + placement.corner.title
        }
        if screens.contains(where: { $0.id == id }) { return (names[id] ?? "另一块屏幕") + " · " + placement.corner.title }
        return "未连接的显示器 · " + placement.corner.title + "（暂放主屏）"
    }
}

struct DesktopCatSettingsView: View {
    @ObservedObject var state: PanelState
    private var actions: DesktopCatSettingsActions { DesktopCatSettingsActions(state: state) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("桌面猫").font(.headline)
                Text("即时生效").font(.caption).foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("显示桌面猫")
                            Text("当前的猫蹲在屏幕角落，所有桌面空间可见").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        NativeSettingsSwitch(id: "desktop-cat.enabled", value: Binding(get: { state.desktopCat.enabled }, set: actions.setEnabled), enabled: true)
                            .frame(width: 38, height: 24)
                    }.padding(8)
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("形象")
                            Text("可选本机 Codex 宠物，只读 ~/.codex/pets").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("形象", selection: Binding(get: { state.desktopCat.pet ?? "" },
                                                        set: { actions.setPet($0.isEmpty ? nil : $0) })) {
                            ForEach(actions.petOptions) { Text($0.title).tag($0.id) }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(maxWidth: 200)
                        .accessibilityIdentifier("desktop-cat.pet")
                    }.padding(8)
                    Divider()
                    DesktopCatSizeRow(state: state).padding(8)
                    Divider()
                    DesktopCatOpacityRow(state: state, part: .cat).padding(8)
                    Divider()
                    DesktopCatOpacityRow(state: state, part: .bubble).padding(8)
                    Divider()
                    HStack {
                        Text("位置")
                        Text(actions.positionText).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("desktop-cat.position")
                        Spacer()
                        SettingsActionButton(title: "放回右下角", id: "desktop-cat.reset-position", enabled: !actions.isDefaultPosition) { actions.resetPosition() }
                            .frame(width: 100, height: 28)
                    }.padding(8)
                }
            }
            HStack {
                Text("指标").font(.subheadline).fontWeight(.semibold)
                Spacer()
                Text(actions.countText).font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 6)
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(actions.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        HStack(spacing: 8) {
                            Button {} label: { Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).frame(width: 24, height: 32) }
                                .buttonStyle(.plain).focusable()
                                .accessibilityLabel("排序" + row.title)
                                .accessibilityIdentifier("desktop-cat.move." + row.id)
                                .onDrag { NSItemProvider(object: NSString(string: "desktop-cat:" + row.id)) }
                                .onKeyPress(keys: [.upArrow, .downArrow]) { event in
                                    guard event.modifiers.contains(.option) else { return .ignored }
                                    actions.move(row.id, offset: event.key == .upArrow ? -1 : 1)
                                    return .handled
                                }
                            Text(row.title)
                            Spacer()
                            Text(row.value).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Button { actions.remove(row.id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).disabled(!row.canRemove)
                                .help(row.canRemove ? "删除这项指标" : "至少保留 1 项")
                                .accessibilityIdentifier("desktop-cat.remove." + row.id)
                        }
                        .frame(height: 36).padding(.horizontal, 8)
                        .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                            Self.acceptDrop(providers, target: row.id, actions: actions)
                        }
                    }
                    Divider()
                    HStack {
                        DesktopCatAddButton(state: state, enabled: actions.canAdd).frame(width: 96, height: 28)
                        if !actions.canAdd { Text("已满 \(DesktopCatConfig.maxMetrics) 项").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                    }.padding(8)
                }
            }
            Text("“添加指标…”弹出与右键菜单相同的分组目录。只剩 1 项时减号变灰。形象选“跟随当前猫”时，用“猫”栏的当前选择。透明度滑块拖动时只改显示，松手写配置；“恢复默认”把两项都设回 100%。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = state.desktopPetError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("desktop-cat.pet-error")
            }
            if let error = state.desktopCatError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("desktop-cat.error")
            }
        }
    }

    static func acceptDrop(_ providers: [NSItemProvider], target: String, actions: DesktopCatSettingsActions) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let source = object as? String, source.hasPrefix("desktop-cat:") else { return }
            let id = String(source.dropFirst(12))
            Task { @MainActor in actions.move(id, onto: target) }
        }
        return true
    }
}

/// 大小：拖动滑块时只改显示（取整到点，49～55 pt 吸附到 52 pt），松手写配置；“恢复默认大小”立即写入。
/// 不设 `step`：68 档的刻度会画成一排密点，取整在绑定里做。
private struct DesktopCatSizeRow: View {
    @ObservedObject var state: PanelState
    @State private var draft: Double?
    private var actions: DesktopCatSettingsActions { DesktopCatSettingsActions(state: state) }
    var body: some View {
        let value = draft ?? actions.catHeight
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("大小")
                Text("默认 52 pt，也可拖猫身上的把手").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Slider(value: Binding(get: { value }, set: { draft = Double(DesktopCatSize.resolved(CGFloat($0))) }),
                   in: Double(DesktopCatSize.range.lowerBound)...Double(DesktopCatSize.range.upperBound)) { editing in
                guard !editing, let draft else { return }
                actions.setCatHeight(draft)
                self.draft = nil
            }
            .frame(width: 140)
            .accessibilityIdentifier("desktop-cat.size")
            Text(DesktopCatSettingsActions.sizeText(value)).monospacedDigit().frame(width: 52, alignment: .trailing)
            SettingsActionButton(title: "恢复默认大小", id: "desktop-cat.reset-size", enabled: !actions.isDefaultSize) { actions.resetSize() }
                .frame(width: 112, height: 28)
        }
    }
}

/// 不透明度：拖动时只改显示（桌面猫实时跟着变），松手写配置。滑块宽度和右侧列宽与大小一行一致；
/// “恢复默认”只在气泡一行，两项都是 100% 时变灰（D48）。不设 `step`，吸附在绑定里做，避免画刻度。
private struct DesktopCatOpacityRow: View {
    @ObservedObject var state: PanelState
    let part: DesktopCatOpacityPart
    private var actions: DesktopCatSettingsActions { DesktopCatSettingsActions(state: state) }
    var body: some View {
        let value = actions.opacity(part)
        HStack {
            Text(part.title)
            Spacer()
            Slider(value: Binding(get: { value }, set: { actions.dragOpacity(part, to: $0) }),
                   in: DesktopCatOpacity.range) { editing in
                guard !editing else { return }
                actions.commitOpacity(part)
            }
            .frame(width: 140)
            .accessibilityLabel(part.title)
            .accessibilityIdentifier("desktop-cat." + part.rawValue)
            Text(DesktopCatSettingsActions.opacityText(value)).monospacedDigit().frame(width: 52, alignment: .trailing)
                .accessibilityIdentifier("desktop-cat." + part.rawValue + ".text")
            if part == .bubble {
                SettingsActionButton(title: "恢复默认", id: "desktop-cat.reset-opacity", enabled: !actions.isDefaultOpacity) { actions.resetOpacity() }
                    .frame(width: 112, height: 28)
            } else {
                Color.clear.frame(width: 112, height: 28)
            }
        }
    }
}

/// “添加指标…”：弹出与右键菜单相同的分组目录。
private struct DesktopCatAddButton: NSViewRepresentable {
    let state: PanelState
    let enabled: Bool
    @MainActor final class Coordinator: NSObject {
        var state: PanelState
        init(state: PanelState) { self.state = state }
        @objc func show(_ sender: NSButton) {
            DesktopCatMenu.metricsMenu(state: state).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "添加指标…", target: context.coordinator, action: #selector(Coordinator.show(_:)))
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("desktop-cat.add")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.state = state; button.isEnabled = enabled }
}
