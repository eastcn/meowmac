import AppKit

/// 从真实窗口的辅助功能树定位控件，点击仍由窗口分发鼠标事件。
@MainActor
enum SettingsControlTestSupport {
    static func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    }
    static func element(_ root: Any, id: String) -> (any NSAccessibilityProtocol)? {
        guard let node = root as? any NSAccessibilityProtocol else { return nil }
        if node.accessibilityIdentifier() == id { return node }
        let children = node.accessibilityChildren() ?? []
        let views = (root as? NSView)?.subviews ?? ((root as? NSWindow)?.contentView.map { [$0] } ?? [])
        for child in children + views {
            if let found = element(child, id: id) { return found }
        }
        return nil
    }
    static func click(_ window: NSWindow, id: String) -> Bool {
        settle(window)
        guard let node = element(window, id: id) else { print("缺少控件：\(id)"); return false }
        let frame = node.accessibilityFrame()
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        guard let content = window.contentView, content.bounds.contains(content.convert(point, from: nil)) else {
            print("控件不在可视区：\(id)，\(frame)"); return false
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
            window.sendEvent(event)
        }
        settle(window)
        return true
    }
    static func optionArrow(_ window: NSWindow, code: UInt16, character: String) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: code) { window.sendEvent(event) }
        settle(window)
    }
    static func capture(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["MEOWMAC_STYLE_RENDER_DIR"],
              let view = window.contentView else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            settle(window)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw NSError(domain: "SettingsCapture", code: 1)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "SettingsCapture", code: 2)
            }
            try png.write(to: directory.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
        }
        window.appearance = NSAppearance(named: .aqua)
    }

}
