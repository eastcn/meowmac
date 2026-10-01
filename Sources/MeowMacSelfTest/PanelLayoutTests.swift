import AppKit
import SwiftUI
import MeowMacCore
import MeowMacUI

@MainActor
enum PanelLayoutTests {
    static func heights() async -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        state.selectedTab = .quota; state.selectedProvider = .claude
        let panel = PanelHosting.make(state: state)
        let controller = panel.controller, measurements = panel.measurements
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { window.contentViewController = nil }
        do {
            let quota = try await PanelPreviewRenderer.settleLayout(controller)
            print("合成 Claude：面板 \(quota.height)，固定 \(measurements.fixedHeight)，内容 \(measurements.contentHeight)，可视 \(measurements.viewportHeight)")
            guard controller.sizingOptions.contains(.preferredContentSize), abs(quota.width - 360) < 0.5,
                  abs(quota.height - 820) < 0.5, measurements.contentHeight > measurements.viewportHeight else { return false }
            state.selectedTab = .system
            let system = try await PanelPreviewRenderer.settleLayout(controller)
            print("合成正常系统：面板 \(system.height)，固定 \(measurements.fixedHeight)，内容 \(measurements.contentHeight)")
            guard system.height <= 820, abs(system.height - measurements.fixedHeight - measurements.contentHeight) < 0.5,
                  measurements.contentHeight > 0, system.height < quota.height else { return false }
            state.selectedTab = .quota; state.selectedProvider = .deepseek
            let short = try await PanelPreviewRenderer.settleLayout(controller)
            print("合成短渠道：面板 \(short.height)，固定 \(measurements.fixedHeight)，内容 \(measurements.contentHeight)")
            guard short.height < quota.height, abs(short.height - measurements.fixedHeight - measurements.contentHeight) < 0.5 else { return false }
            state.quotaErrors[.deepseek] = "虚构采集错误"
            state.quotas.removeValue(forKey: .deepseek)
            let error = try await PanelPreviewRenderer.settleLayout(controller)
            guard error.height < short.height else { return false }
            state.selectedTab = .system
            let normal = try await PanelPreviewRenderer.settleLayout(controller)
            let header = measurements.headerHeight
            let alert = PanelPreviewRenderer.syntheticState(alert: true)
            state.energy = alert.energy; state.snapshot = alert.snapshot; state.fairSince = alert.fairSince
            let warning = try await PanelPreviewRenderer.settleLayout(controller)
            print("合成提醒系统：面板 \(warning.height)，固定 \(measurements.fixedHeight)，内容 \(measurements.contentHeight)")
            return warning.height > normal.height && warning.height <= 820 && measurements.headerHeight > header
        } catch { print("面板尺寸验证失败：\(error)"); return false }
    }
}
