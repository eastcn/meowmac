import AppKit
import SwiftUI
import MeowMacCore

/// 原生下拉逐项禁用，并在保存失败后立即回读选择值。
struct AIAgentPicker: NSViewRepresentable {
    let agents: [AIAgent]
    let available: Set<AIAgent>
    let id: String
    @Binding var selection: AIAgent?
    var enabled = true
    @MainActor final class Coordinator: NSObject {
        var parent: AIAgentPicker
        init(_ parent: AIAgentPicker) { self.parent = parent }
        @objc func invoke(_ sender: NSPopUpButton) {
            guard let index = sender.selectedItem?.tag, parent.agents.indices.contains(index) else { return }
            let agent = parent.agents[index]
            if agent == .automatic || parent.available.contains(agent) { parent.selection = agent }
            update(sender)
        }
        func update(_ sender: NSPopUpButton) {
            if let selection = parent.selection, let index = parent.agents.firstIndex(of: selection) { sender.selectItem(at: index) }
            else { sender.select(nil) }
            sender.isEnabled = parent.enabled
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.target = context.coordinator; control.action = #selector(Coordinator.invoke(_:))
        control.setAccessibilityIdentifier(id); control.menu?.autoenablesItems = false
        return control
    }
    func updateNSView(_ control: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        control.removeAllItems()
        for (index, agent) in agents.enumerated() {
            control.addItem(withTitle: agent.name)
            control.lastItem?.tag = index
            control.lastItem?.isEnabled = agent == .automatic || available.contains(agent)
        }
        context.coordinator.update(control)
    }
}
