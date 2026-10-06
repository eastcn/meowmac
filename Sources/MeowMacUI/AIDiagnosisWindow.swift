import AppKit
import SwiftUI
import MeowMacCore

@MainActor
public final class AIDiagnosisWindowController: NSObject, NSWindowDelegate {
    public private(set) var window: NSWindow?
    public private(set) var session: AIDiagnosisSession?
    private let controller: AIAgentController
    public init(controller: AIAgentController) { self.controller = controller }
    public func open(prompt: String) {
        let session = controller.preview(prompt: prompt)
        self.session = session
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "用 AI 排查"; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentMinSize = NSSize(width: 640, height: 400)
            self.window = window; window.center()
        }
        window?.contentView = NSHostingView(rootView: AIDiagnosisPreview(session: session, copy: { [controller] in controller.copyPrompt(session) },
            cancel: { [weak self] in self?.close() }, launch: { [controller] in controller.launch(session) }))
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    public func close() { window?.close() }
    public func windowWillClose(_ notification: Notification) { window?.delegate = nil; window = nil; session = nil }
}

private struct AIDiagnosisPreview: View {
    @ObservedObject var session: AIDiagnosisSession
    let copy: () -> Void, cancel: () -> Void, launch: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if session.installations.isEmpty {
                Text("到设置 › 通用查看检测结果").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("agent")
                    AIAgentPicker(agents: session.installations.map(\.agent), available: Set(session.installations.map(\.agent)),
                        id: "ai-preview.agent", selection: $session.selected, enabled: !session.launching).frame(width: 300, height: 28)
                    Spacer(minLength: 0)
                }
                Text(session.selected?.launchDescription == "预填" ? "启动后预填提示词" : session.selected.map { [.qoder, .chatGPT, .deepSeekHarness].contains($0) ? "启动时复制提示词，请在 agent 中粘贴" : "启动后作为首条消息发送" } ?? "请选择 agent")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ReadOnlyDiagnosisPrompt(prompt: session.prompt)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            if let message = session.message { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("ai-preview.message") }
            HStack {
                SettingsActionButton(title: "复制提示词", id: "ai-preview.copy", action: copy).frame(width: 110, height: 30)
                Spacer()
                if !session.installations.isEmpty {
                    SettingsActionButton(title: "取消", id: "ai-preview.cancel", enabled: !session.launching, action: cancel).frame(width: 80, height: 30)
                    SettingsActionButton(title: session.launching ? "启动中…" : "启动", id: "ai-preview.launch", enabled: session.selected != nil && !session.launching, action: launch).frame(width: 90, height: 30)
                }
            }
        }.padding(20)
    }
}

/// 可选择文字，但没有编辑或自动复制行为。
private struct ReadOnlyDiagnosisPrompt: NSViewRepresentable {
    let prompt: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 320))
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .systemFont(ofSize: 13); text.textColor = .labelColor; text.backgroundColor = .textBackgroundColor
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 580, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 8, height: 10)
        text.setAccessibilityIdentifier("ai-preview.prompt")
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let text = scroll.documentView as? NSTextView, text.string != prompt { text.string = prompt; text.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
    }
}

public extension PanelState {
    var aiDiagnosisPrompt: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return AIDiagnosisPrompt.make(rows: diagnosisRows, snapshot: snapshot,
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
    }
    var diagnosisHint: String { aiDiagnosisEntry ? "建议用 AI 诊断" : "建议用 AI 诊断：把进程名和数值交给 AI 助手排查" }
    var showsAIDiagnosis: Bool { aiDiagnosisEntry && !diagnosisRows.isEmpty }
    func showsAIDiagnosis(for reminder: Reminder) -> Bool {
        aiDiagnosisEntry && reminder.kind == .thermal && (energy?.runaway.isEmpty ?? true)
    }
}

struct AIDiagnosisEntry: View {
    @ObservedObject var state: PanelState
    let id: String
    var body: some View {
        Button("用 AI 排查…", action: state.onAIDiagnosis)
            .buttonStyle(.plain).font(Design.caption).foregroundStyle(Design.blue).fixedSize()
            .accessibilityIdentifier(id)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PanelInteractionFrameKey.self, value: [id: proxy.frame(in: .named(PanelInteractionFrameKey.space))])
            })
    }
}
