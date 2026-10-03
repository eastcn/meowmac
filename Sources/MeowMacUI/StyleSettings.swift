import AppKit
import MeowMacCore
import os

@MainActor
public final class StyleSettingsModel {
    public let saved: StyleSettings
    public private(set) var draft: StyleSettings { didSet { onContentChange() } }
    public private(set) var error: String? { didSet { onContentChange() } }
    public var onClose: () -> Void = {}
    public var onContentChange: () -> Void = {}
    private let state: PanelState
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "style-settings")
    public init(state: PanelState) {
        self.state = state
        saved = state.style; draft = saved; error = state.styleRecoveryReason
    }
    public var isDirty: Bool { draft != saved }
    public var emailExample: String { "账号邮箱示例：" + (draft.email.display("name@example.com") ?? "（不显示）") }
    public func setBasis(_ value: QuotaBasis) { draft.quotaBasis = value }
    public func setEmail(_ value: EmailDisplay) { draft.email = value }
    public func setChartMinutes(_ value: Int) { draft.chartMinutes = value }
    public func setColor(_ value: ThemeColor, for provider: QuotaProvider) { draft.colors[provider.rawValue] = value }
    public func restoreDefault() { draft = .default; error = state.styleRecoveryReason }
    public func cancel() { onClose() }
    public func save() {
        guard isDirty else { return }
        do { try state.saveStyle(draft); onClose() }
        catch {
            logger.error("样式保存失败：\(error.localizedDescription, privacy: .private)")
            self.error = error.localizedDescription
        }
    }
}

@MainActor
private final class StyleSwatch: NSButton {
    let provider: QuotaProvider
    let color: ThemeColor
    init(provider: QuotaProvider, color: ThemeColor) {
        self.provider = provider; self.color = color
        super.init(frame: .zero)
        title = ""; isBordered = false
        setAccessibilityLabel(provider.displayName + " " + color.title)
        setAccessibilityIdentifier("style.color." + provider.rawValue + "." + color.rawValue)
        toolTip = color.title
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        var style = StyleSettings.default; style.colors[provider.rawValue] = color
        let fill = QuotaPalette.color(provider, style: style)
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
        fill.setFill(); circle.fill()
        if color == .default {
            NSColor.controlBackgroundColor.setStroke(); circle.lineWidth = 3; circle.stroke()
        }
        if state == .on {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2; ring.stroke()
        }
    }
}

@MainActor
public final class StyleSettingsController: NSObject, NSWindowDelegate {
    public private(set) var window: NSWindow?
    public private(set) var model: StyleSettingsModel?
    private let state: PanelState
    private var openedCatID: String?
    private var basis: NSSegmentedControl!
    private var email: NSSegmentedControl!
    private var range: NSSegmentedControl!
    private var example: NSTextField!
    private var status: NSTextField!
    private var saveButton: NSButton!
    private var swatches: [StyleSwatch] = []
    public init(state: PanelState) { self.state = state }
    public func present() {
        if let window { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); return }
        let model = StyleSettingsModel(state: state)
        self.model = model; openedCatID = state.selectedCat?.id
        model.onClose = { [weak self] in self?.window?.close() }
        model.onContentChange = { [weak self] in self?.refresh() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "样式"; window.isReleasedWhenClosed = false; window.delegate = self
        self.window = window
        buildContent(window)
        window.setContentSize(NSSize(width: 520, height: min(700, (NSScreen.main?.visibleFrame.height ?? 800) - 40)))
        refresh(); window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    public func catDidChange() {
        if window != nil && openedCatID != state.selectedCat?.id { window?.close() }
    }
    private func text(_ title: String, small: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: small ? 11 : 13)
        label.textColor = small ? .secondaryLabelColor : .labelColor
        return label
    }
    private func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 8) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = vertical ? .vertical : .horizontal
        result.alignment = vertical ? .leading : .centerY
        result.spacing = spacing
        return result
    }
    private func group(_ rows: [NSView]) -> NSBox {
        let box = NSBox(); box.boxType = .custom; box.title = ""
        box.borderType = .lineBorder; box.borderWidth = 1; box.cornerRadius = 8
        box.borderColor = .separatorColor; box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        var elements: [NSView] = []
        for row in rows {
            if !elements.isEmpty { let rule = NSBox(); rule.boxType = .separator; elements.append(rule) }
            elements.append(row)
        }
        let body = stack(elements, vertical: true, spacing: 8)
        body.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 8),
            body.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -8)
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        return box
    }
    private func segment(_ labels: [String], id: String, action: Selector) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
        control.setAccessibilityIdentifier(id)
        return control
    }
    private func buildContent(_ window: NSWindow) {
        let content = NSView(); window.contentView = content
        basis = segment(["剩余", "已用"], id: "style.basis", action: #selector(changeBasis))
        email = segment(["完整", "部分遮罩", "隐藏"], id: "style.email", action: #selector(changeEmail))
        range = segment(["15 分钟", "1 小时"], id: "style.range", action: #selector(changeRange))
        let heading = text("本机设置"); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let rows = [("额度数字显示", basis!), ("账号邮箱", email!), ("系统趋势默认范围", range!)]
        let settingsRows = rows.map { title, control -> NSView in
            let row = stack([text(title), NSView(), control]); row.heightAnchor.constraint(equalToConstant: 40).isActive = true
            return row
        }
        example = text("", small: true); example.setAccessibilityIdentifier("style.emailExample")
        let colors = text("渠道颜色"); colors.font = .systemFont(ofSize: 13, weight: .semibold)
        var colorRows: [NSView] = []
        for provider in [QuotaProvider.claude, .codex, .deepseek, .opencodego] {
            let picks = ThemeColor.allCases.map { color -> StyleSwatch in
                let button = StyleSwatch(provider: provider, color: color)
                button.target = self; button.action = #selector(changeColor(_:))
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
                button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                swatches.append(button); return button
            }
            colorRows.append(stack([text(provider.displayName), stack(picks)], vertical: true, spacing: 6))
        }
        let form = stack([heading, text("所有猫共用 · 总览条在“布局与显示…”里调", small: true),
            group(settingsRows), example, colors, text("用于进度条、趋势线和渠道标记", small: true), group(colorRows)],
            vertical: true, spacing: 10)
        form.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.documentView = form; scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        let reset = NSButton(title: "恢复默认样式", target: self, action: #selector(resetDraft))
        reset.setAccessibilityIdentifier("style.reset")
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelDraft))
        cancel.setAccessibilityIdentifier("style.cancel")
        saveButton = NSButton(title: "保存", target: self, action: #selector(saveDraft))
        saveButton.keyEquivalent = "\r"; saveButton.setAccessibilityIdentifier("style.save")
        for button in [reset, cancel, saveButton!] { button.bezelStyle = .rounded }
        status = text("", small: true); status.setAccessibilityIdentifier("style.status")
        let footer = stack([stack([reset, NSView(), cancel, saveButton]), status], vertical: true, spacing: 8)
        footer.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(footer)
        let divider = NSBox(); divider.boxType = .separator; divider.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(divider)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scroll.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -14),
            form.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            form.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            form.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor), divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            status.widthAnchor.constraint(equalTo: footer.widthAnchor)
        ])
        for box in form.arrangedSubviews.compactMap({ $0 as? NSBox }) { box.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        if let buttons = footer.arrangedSubviews.first { buttons.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true }
    }
    private func refresh() {
        guard let model, window != nil else { return }
        basis.selectedSegment = model.draft.quotaBasis == .remaining ? 0 : 1
        email.selectedSegment = EmailDisplay.allCases.firstIndex(of: model.draft.email) ?? 0
        range.selectedSegment = model.draft.chartMinutes == 15 ? 0 : 1
        example.stringValue = model.emailExample
        status.stringValue = model.error ?? (model.isDirty ? "有未保存的更改" : "尚未修改")
        status.textColor = model.error == nil ? .secondaryLabelColor : .systemOrange
        saveButton.isEnabled = model.isDirty
        for button in swatches {
            button.state = model.draft.color(for: button.provider) == button.color ? .on : .off
            button.needsDisplay = true
        }
    }
    @objc private func changeBasis() { model?.setBasis(basis.selectedSegment == 0 ? .remaining : .used) }
    @objc private func changeEmail() { model?.setEmail(EmailDisplay.allCases[email.selectedSegment]) }
    @objc private func changeRange() { model?.setChartMinutes(range.selectedSegment == 0 ? 15 : 60) }
    @objc private func changeColor(_ sender: StyleSwatch) { model?.setColor(sender.color, for: sender.provider) }
    @objc private func resetDraft() { model?.restoreDefault() }
    @objc private func cancelDraft() { model?.cancel() }
    @objc private func saveDraft() { model?.save() }
    public func windowWillClose(_ notification: Notification) {
        window?.delegate = nil; window = nil; model = nil; openedCatID = nil; swatches.removeAll()
    }
}
