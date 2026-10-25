import AppKit
import Combine
import SwiftUI

@MainActor
public final class AppearanceSettingsModel: ObservableObject, SettingsDraftSession {
    public let style: StyleSettingsModel
    @Published public private(set) var layout: LayoutSettingsModel?
    @Published private var saveStatus: String?
    /// 每次加 1 表示要滚动到“桌面猫”分组（右键菜单的“桌面猫设置…”）。
    @Published public var desktopCatFocus = 0
    private let state: PanelState
    private var observations: Set<AnyCancellable> = []

    public init(state: PanelState) {
        self.state = state
        style = StyleSettingsModel(state: state)
        layout = LayoutSettingsModel(state: state)
        observeDrafts()
    }

    public var isDirty: Bool { style.isDirty || layout?.isDirty == true }
    public var canSave: Bool { isDirty }
    public var isBusy: Bool { false }
    public var statusText: String {
        saveStatus ?? style.error ?? layout?.error ?? (isDirty ? "有未保存的更改" : "尚未修改")
    }

    public func catDidChange() {
        guard layout?.catID != state.selectedCat?.id else { return }
        layout = LayoutSettingsModel(state: state)
        saveStatus = nil
        observeDrafts()
    }

    public func discard() {
        style.discard()
        layout?.discard()
        saveStatus = nil
    }

    public func save() async -> Bool {
        let styleChanged = style.isDirty
        let layoutChanged = layout?.isDirty == true
        let styleSaved = style.save()
        let layoutSaved = layout?.save() ?? true
        if styleSaved && layoutSaved {
            saveStatus = "已保存"
            return true
        }
        var messages: [String] = []
        if !styleSaved { messages.append("样式保存失败：" + (style.error ?? "未知错误")) }
        else if styleChanged { messages.append("样式已保存") }
        if !layoutSaved { messages.append("布局保存失败：" + (layout?.error ?? "未知错误")) }
        else if layoutChanged { messages.append("布局已保存") }
        saveStatus = messages.joined(separator: "；")
        return false
    }

    private func observeDrafts() {
        observations.removeAll()
        style.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        layout?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        style.$draft.dropFirst().sink { [weak self] _ in self?.saveStatus = nil }.store(in: &observations)
        layout?.$draft.dropFirst().sink { [weak self] _ in self?.saveStatus = nil }.store(in: &observations)
    }
}

@MainActor
public struct AppearanceSettingsView: View {
    @ObservedObject private var model: AppearanceSettingsModel
    @ObservedObject private var state: PanelState
    public init(model: AppearanceSettingsModel, state: PanelState) { self.model = model; self.state = state }

    public var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("样式").font(.headline)
                    Spacer()
                    AppearanceResetButton(model: model)
                }
                StyleSettingsForm(model: model.style, state: state)
                Divider()
                Text("布局与显示").font(.headline)
                if let layout = model.layout {
                    LayoutSettingsView(model: layout, state: state)
                } else {
                    Text("当前没有可用的猫配置").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("appearance.no-cat")
                }
                Divider()
                // 即时生效，不参与上面的草稿和“恢复默认…”（D6）。
                DesktopCatSettingsView(state: state).id(Self.desktopCatAnchor)
            }.padding(24)
        }
        .onAppear { if model.desktopCatFocus > 0 { proxy.scrollTo(Self.desktopCatAnchor, anchor: .top) } }
        .onChange(of: model.desktopCatFocus) { _, _ in proxy.scrollTo(Self.desktopCatAnchor, anchor: .top) }
        }
    }
    static let desktopCatAnchor = "appearance.desktop-cat"
}

@MainActor
private struct AppearanceResetButton: NSViewRepresentable {
    @ObservedObject var model: AppearanceSettingsModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "恢复默认…", target: context.coordinator, action: #selector(Coordinator.showMenu(_:)))
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("appearance.reset")
        button.menu = context.coordinator.makeMenu()
        return button
    }
    func updateNSView(_ nsView: NSButton, context: Context) { nsView.menu = context.coordinator.makeMenu() }
    @MainActor final class Coordinator: NSObject {
        let model: AppearanceSettingsModel
        init(model: AppearanceSettingsModel) { self.model = model }
        @objc func showMenu(_ sender: NSButton) {
            sender.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
        }
        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            let style = menu.addItem(withTitle: "恢复默认样式", action: #selector(resetStyle), keyEquivalent: "")
            style.target = self
            let layout = menu.addItem(withTitle: "恢复默认布局", action: #selector(resetLayout), keyEquivalent: "")
            layout.target = self; layout.isEnabled = model.layout != nil
            menu.autoenablesItems = false
            return menu
        }
        @objc func resetStyle() { model.style.restoreDefault() }
        @objc func resetLayout() { model.layout?.restoreDefault() }
    }
}
