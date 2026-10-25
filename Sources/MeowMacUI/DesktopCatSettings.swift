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
            Text("“添加指标…”弹出与右键菜单相同的分组目录。只剩 1 项时减号变灰。用哪只猫跟随“猫”栏的当前选择。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
