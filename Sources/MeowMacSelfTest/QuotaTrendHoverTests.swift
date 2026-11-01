import AppKit
import SwiftUI
import MeowMacCore
import MeowMacUI

@MainActor
enum QuotaTrendHoverTests {
    static func nativeHover() async -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        state.selectedTab = .quota; state.selectedProvider = .claude
        let root = URL(fileURLWithPath: "build/acceptance/quota-hover")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for dark in [false, true] {
                let hosting = PanelHosting.make(state: state)
                let view = hosting.controller.view
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentViewController = hosting.controller; window.orderFront(nil)
                defer { window.contentViewController = nil; window.close() }
                func settle() async throws { try await Task.sleep(nanoseconds: 100_000_000); view.layoutSubtreeIfNeeded() }
                func capture() throws -> Data {
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.coderInvalidValue) }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
                    return png
                }
                func tracker(_ prefix: String, _ parent: NSView) -> NSView? {
                    if parent.identifier?.rawValue.hasPrefix(prefix) == true { return parent }
                    return parent.subviews.lazy.compactMap { tracker(prefix, $0) }.first
                }
                _ = try await PanelPreviewRenderer.settleLayout(hosting.controller)
                try await settle()
                let baseline = try capture()
                let suffix = dark ? "-dark.png" : "-light.png"
                try baseline.write(to: root.appendingPathComponent("normal" + suffix))
                for kind in ["quota.cycle.", "quota.peaks"] {
                    guard let surface = tracker("trend." + kind, view), surface.bounds.width > 0 else { return false }
                    let cycle = state.quotaCycles(.claude)[0]
                    let sample = cycle.points[cycle.points.count / 2]
                    let fraction: CGFloat = kind == "quota.peaks" ? 0.5
                        : sample.sampledAt.timeIntervalSince(cycle.start) / cycle.reset.timeIntervalSince(cycle.start)
                    let point = surface.convert(NSPoint(x: surface.bounds.width * fraction, y: surface.bounds.midY), to: nil)
                    guard let moved = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0) else { return false }
                    surface.mouseMoved(with: moved); try await settle()
                    let hovered = try capture()
                    guard hovered != baseline else { print("悬停未改变图表：\(kind)"); return false }
                    try hovered.write(to: root.appendingPathComponent(kind + suffix))
                    guard let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil) else { return false }
                    surface.mouseExited(with: exited); try await settle()
                    guard try capture() == baseline else { print("移出未恢复：\(kind)"); return false }
                }
            }
            return true
        } catch { print("额度悬停测试失败：\(error)"); return false }
    }
}
