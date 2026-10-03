import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MeowMacCore

@MainActor
public final class LayoutSettingsModel: ObservableObject {
    public let catID: String
    public let catName: String
    public let packageDefault: PanelLayout
    public let saved: PanelLayout
    @Published public private(set) var draft: PanelLayout
    @Published public var selectedTab: PanelTab = .system
    @Published public private(set) var error: String? { didSet { onContentChange() } }
    public var onClose: () -> Void = {}
    public var onContentChange: () -> Void = {}
    private let state: PanelState

    public init?(state: PanelState) {
        guard let cat = state.selectedCat else { return nil }
        self.state = state
        catID = cat.id; catName = cat.name
        packageDefault = cat.package.panel
        saved = state.panelLayout
        draft = saved
        error = state.layoutRecoveryReason
    }

    public var isDirty: Bool { draft != saved }
    public var overviewPreview: [OverviewMetric] { state.overviewMetrics(for: draft.overview) }
    public func moveOverview(_ source: OverviewItem, to target: OverviewItem) {
        guard let from = draft.overview.order.firstIndex(of: source),
              let to = draft.overview.order.firstIndex(of: target), from != to else { return }
        draft.overview.order.remove(at: from)
        draft.overview.order.insert(source, at: to)
    }
    public func moveOverview(_ item: OverviewItem, offset: Int) {
        guard let index = draft.overview.order.firstIndex(of: item),
              draft.overview.order.indices.contains(index + offset) else { return }
        moveOverview(item, to: draft.overview.order[index + offset])
    }
    public func setOverviewVisible(_ visible: Bool, item: OverviewItem) {
        if visible { draft.overview.hidden.removeAll { $0 == item } }
        else if draft.overview.visible.count > 1 && !draft.overview.hidden.contains(item) { draft.overview.hidden.append(item) }
    }
    public func setOverviewProvider(_ provider: QuotaProvider) {
        guard provider != draft.overview.quota.provider else { return }
        draft.overview.quota = OverviewQuota(provider: provider, window: "auto")
    }
    public func setOverviewWindow(_ selector: String) { draft.overview.quota.window = selector }
    public var quotaWindowOptions: [(selector: String, title: String)] {
        let windows = state.quotas[draft.overview.quota.provider]?.windows ?? []
        var options: [(String, String)] = [("auto", "自动")]
        options += windows.map { (OverviewQuota.selector(for: $0, among: windows), $0.displayName) }
        let selected = draft.overview.quota.window
        if !options.contains(where: { $0.0 == selected }) { options.append((selected, "已保存 · " + selected)) }
        return options
    }
    public func moveTab(_ source: PanelTab, to target: PanelTab) {
        guard let from = draft.tabs.firstIndex(of: source), let to = draft.tabs.firstIndex(of: target), from != to else { return }
        draft.tabs.remove(at: from); draft.tabs.insert(source, at: to)
    }
    public func moveTab(_ tab: PanelTab, offset: Int) {
        guard let index = draft.tabs.firstIndex(of: tab), draft.tabs.indices.contains(index + offset) else { return }
        moveTab(tab, to: draft.tabs[index + offset])
    }
    public func moveCard(_ source: String, to target: String, in tab: PanelTab) {
        var items = draft.placements(for: tab)
        guard let from = items.firstIndex(where: { $0.id == source }),
              let to = items.firstIndex(where: { $0.id == target }), from != to else { return }
        items.remove(at: from); items.insert(PanelCardPlacement(id: source, visible: draft.placements(for: tab)[from].visible), at: to)
        draft.cards[tab.rawValue] = items
    }
    public func moveCard(_ id: String, offset: Int, in tab: PanelTab) {
        let items = draft.placements(for: tab)
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + offset) else { return }
        moveCard(id, to: items[index + offset].id, in: tab)
    }
    public func setVisible(_ visible: Bool, id: String, in tab: PanelTab) {
        guard let definition = PanelLayoutCatalog.definitions[tab]?.first(where: { $0.id == id }),
              definition.canHide, let index = draft.cards[tab.rawValue]?.firstIndex(where: { $0.id == id }) else { return }
        draft.cards[tab.rawValue]?[index].visible = visible
    }
    public func restoreDefault() { draft = packageDefault; error = state.layoutRecoveryReason }
    public func cancel() { onClose() }
    public func save() {
        guard isDirty else { return }
        do {
            try state.saveLayout(draft, for: catID)
            onClose()
        } catch { self.error = error.localizedDescription }
    }
    public func acceptDrop(_ providers: [NSItemProvider], kind: String, target: String) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let source = object as? String else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if kind == "overview", source.hasPrefix("overview:"),
                   let from = OverviewItem(rawValue: String(source.dropFirst(9))),
                   let to = OverviewItem(rawValue: target) {
                    self.moveOverview(from, to: to)
                } else if kind == "tab", source.hasPrefix("tab:"),
                   let from = PanelTab(rawValue: String(source.dropFirst(4))), let to = PanelTab(rawValue: target) {
                    self.moveTab(from, to: to)
                } else if kind == "card", source.hasPrefix("card:") {
                    self.moveCard(String(source.dropFirst(5)), to: target, in: self.selectedTab)
                }
            }
        }
        return true
    }
}

@MainActor
public final class LayoutSettingsController: NSObject, NSWindowDelegate {
    public private(set) var window: NSWindow?
    public private(set) var model: LayoutSettingsModel?
    private var hostingController: NSHostingController<LayoutSettingsView>?
    private let state: PanelState
    public init(state: PanelState) { self.state = state }

    public func present() {
        if let window { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); return }
        guard let model = LayoutSettingsModel(state: state) else { return }
        model.onClose = { [weak self] in self?.window?.close() }
        model.onContentChange = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.resizeToFit() }
        }
        let controller = NSHostingController(rootView: LayoutSettingsView(model: model, state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "布局与显示"
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 520, height: min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 40)))
        window.contentMinSize = NSSize(width: 520, height: 460)
        window.contentMaxSize = NSSize(width: 520, height: min(900, NSScreen.main?.visibleFrame.height ?? 900))
        window.center()
        window.delegate = self
        self.model = model; self.window = window; hostingController = controller
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func catDidChange() {
        guard let model, model.catID != state.selectedCat?.id else { return }
        window?.close()
    }

    private func resizeToFit() {
        guard let window, let controller = hostingController else { return }
        controller.view.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 520, height: min(760, (NSScreen.main?.visibleFrame.height ?? 800) - 40)))
    }

    public func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil; model = nil; hostingController = nil
    }
}

struct LayoutSettingsView: View {
    @ObservedObject var model: LayoutSettingsModel
    @ObservedObject var state: PanelState
    private var definitions: [PanelCardDefinition] { PanelLayoutCatalog.definitions[model.selectedTab] ?? [] }
    private var note: String {
        switch model.selectedTab {
        case .system: return "有问题时，能耗诊断固定在最前。"
        case .quota: return "渠道切换、额度窗口和采集错误提示固定在上方。"
        case .network: return "网络结论固定在上方，隐藏功能不影响健康判定。"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("当前猫").font(.caption).foregroundStyle(.secondary)
                    Text(model.catName).font(.system(size: 15, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("总览条").fontWeight(.semibold); Spacer(); Text("拖动排序 · ⌥↑ / ↓ · 至少显示一格").font(.caption).foregroundStyle(.secondary) }
                    VStack(spacing: 0) {
                        ForEach(Array(model.draft.overview.order.enumerated()), id: \.element) { index, item in
                            if index > 0 { Divider() }
                            HStack(spacing: 8) {
                                Button {} label: { Image(systemName: "line.3.horizontal").frame(width: 30, height: 44) }
                                    .buttonStyle(.plain).focusable()
                                    .accessibilityLabel("排序" + item.title + "格")
                                    .accessibilityIdentifier("overview.move." + item.rawValue)
                                    .onDrag { NSItemProvider(object: NSString(string: "overview:" + item.rawValue)) }
                                    .onKeyPress(keys: [.upArrow, .downArrow]) { event in
                                        guard event.modifiers.contains(.option) else { return .ignored }
                                        model.moveOverview(item, offset: event.key == .upArrow ? -1 : 1)
                                        return .handled
                                    }
                                Text(item.title + "格")
                                    .foregroundStyle(model.draft.overview.hidden.contains(item) ? .secondary : .primary)
                                Spacer()
                                Toggle("显示", isOn: Binding(get: { !model.draft.overview.hidden.contains(item) }, set: {
                                    model.setOverviewVisible($0, item: item)
                                })).toggleStyle(.checkbox)
                                    .disabled(model.draft.overview.visible == [item])
                                    .accessibilityIdentifier("overview.visible." + item.rawValue)
                            }.frame(height: 44).padding(.horizontal, 8)
                                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) {
                                    model.acceptDrop($0, kind: "overview", target: item.rawValue)
                                }
                            if item == .quota {
                                HStack(spacing: 8) {
                                    Picker("额度渠道", selection: Binding(get: { model.draft.overview.quota.provider }, set: { model.setOverviewProvider($0) })) {
                                        ForEach(QuotaProvider.allCases, id: \.self) { provider in
                                            Text(provider.displayName).tag(provider)
                                        }
                                    }
                                    .accessibilityIdentifier("overview.provider")
                                    Picker("额度窗口", selection: Binding(get: { model.draft.overview.quota.window }, set: { model.setOverviewWindow($0) })) {
                                        ForEach(model.quotaWindowOptions.indices, id: \.self) { index in
                                            let option = model.quotaWindowOptions[index]
                                            Text(option.title).tag(option.selector)
                                        }
                                    }
                                    .accessibilityIdentifier("overview.window")
                                }.padding(.leading, 46).padding(.trailing, 12).padding(.bottom, 8)
                            }
                        }
                    }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                    HStack(alignment: .top, spacing: Design.metricGap) {
                        ForEach(model.overviewPreview, id: \.item) { metric in
                            FlatMetric(title: metric.title, value: metric.value, detail: metric.detail,
                                       fraction: metric.fraction, color: metric.item == .cpu ? Design.blue : Design.state(metric.level))
                        }
                    }.padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("overview.preview")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("标签页顺序").fontWeight(.semibold); Spacer(); Text("拖动排序 · ⌥← / →").font(.caption).foregroundStyle(.secondary) }
                    HStack(spacing: 6) {
                        ForEach(model.draft.tabs, id: \.self) { tab in
                            Button { model.selectedTab = tab } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                                    Text(tab.title).fontWeight(model.selectedTab == tab ? .semibold : .regular)
                                }.frame(maxWidth: .infinity).frame(height: 44)
                            }
                            .accessibilityIdentifier("layout.tab." + tab.rawValue)
                            .buttonStyle(.bordered)
                            .focusable()
                            .background(model.selectedTab == tab ? Color.accentColor.opacity(0.14) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(model.selectedTab == tab ? Color.accentColor : Color(nsColor: .separatorColor)))
                            .onDrag { NSItemProvider(object: NSString(string: "tab:" + tab.rawValue)) }
                            .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) {
                                model.acceptDrop($0, kind: "tab", target: tab.rawValue)
                            }
                            .onKeyPress(keys: [.leftArrow, .rightArrow]) { event in
                                guard event.modifiers.contains(.option) else { return .ignored }
                                model.moveTab(tab, offset: event.key == .leftArrow ? -1 : 1)
                                return .handled
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(model.selectedTab.title + "页功能").fontWeight(.semibold); Spacer(); Text("拖动排序 · ⌥↑ / ↓").font(.caption).foregroundStyle(.secondary) }
                    VStack(spacing: 0) {
                        ForEach(Array(model.draft.placements(for: model.selectedTab).enumerated()), id: \.element.id) { index, placement in
                            if index > 0 { Divider() }
                            let definition = definitions.first { $0.id == placement.id }
                            HStack(spacing: 8) {
                                Button {} label: { Image(systemName: "line.3.horizontal").frame(width: 30, height: 44) }
                                    .buttonStyle(.plain)
                                    .focusable()
                                    .accessibilityLabel("排序" + (definition?.title ?? placement.id))
                                    .accessibilityIdentifier("layout.move." + placement.id)
                                    .onDrag { NSItemProvider(object: NSString(string: "card:" + placement.id)) }
                                    .onKeyPress(keys: [.upArrow, .downArrow]) { event in
                                        guard event.modifiers.contains(.option) else { return .ignored }
                                        model.moveCard(placement.id, offset: event.key == .upArrow ? -1 : 1, in: model.selectedTab)
                                        return .handled
                                    }
                                Text(definition?.title ?? placement.id)
                                    .foregroundStyle(placement.visible ? .primary : .secondary)
                                Spacer()
                                if definition?.canHide == false { Text("常驻").font(.caption).foregroundStyle(.secondary) }
                                else {
                                    Toggle("显示", isOn: Binding(get: { placement.visible }, set: {
                                        model.setVisible($0, id: placement.id, in: model.selectedTab)
                                    })).toggleStyle(.checkbox)
                                    .accessibilityIdentifier("layout.visible." + placement.id)
                                }
                            }.frame(height: 52).padding(.horizontal, 8)
                                .onDrop(of: [UTType.plainText.identifier], isTargeted: nil) {
                                    model.acceptDrop($0, kind: "card", target: placement.id)
                                }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(24)
            }
            Divider()
            HStack {
                Button("恢复默认布局") { model.restoreDefault() }.accessibilityIdentifier("layout.reset")
                Spacer()
                Button("取消") { model.cancel() }.accessibilityIdentifier("layout.cancel")
                Button("保存") { model.save() }.accessibilityIdentifier("layout.save").buttonStyle(.borderedProminent).disabled(!model.isDirty)
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Text(model.error ?? (model.isDirty ? "有未保存的更改" : "尚未修改"))
                .font(.caption).foregroundStyle(model.error == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 12)
        }.frame(width: 520).background(Color(nsColor: .windowBackgroundColor))
    }
}
