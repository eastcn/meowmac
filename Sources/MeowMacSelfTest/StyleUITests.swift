import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum StyleUITests {
    private static let root = URL(fileURLWithPath: "build/acceptance/style-tests/panel-app", isDirectory: true)
    static func rendering() -> Bool {
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
            let state = PanelPreviewRenderer.syntheticState()
            CatRuntime.initialize(state: state, store: CatStore(rootURL: root))
            let baseline = state.overviewMetrics
            guard baseline.map(\.item) == [.cpu, .memory, .quota, .network],
                  baseline[2].title == "Claude", baseline[2].value == "72%",
                  baseline[2].detail == "5 小时 · 剩余", baseline[2].fraction == 0.72 else { return false }
            let raw = state.quotas[.codex]!.windows[0].usedPercent
            let health = state.health.level
            var layout = PanelLayout.default
            layout.overview.order = [.network, .quota, .cpu, .memory]
            layout.overview.hidden = [.memory]
            layout.overview.quota = OverviewQuota(provider: .codex, window: "minutes:10080")
            try state.saveLayout(layout, for: "builtin.slim")
            guard state.overviewMetrics.map(\.item) == [.network, .quota, .cpu],
                  state.overviewMetrics[1].value == "62%", state.overviewMetrics[1].detail == "7 天 · 剩余" else { return false }
            var style = StyleSettings.default
            style.quotaBasis = .used; style.email = .masked; style.chartMinutes = 15
            style.colors[QuotaProvider.codex.rawValue] = .pink
            state.applyStyle(style)
            guard state.overviewMetrics[1].value == "38%", state.overviewMetrics[1].fraction == 0.38,
                  state.overviewMetrics[1].detail == "7 天 · 已用",
                  state.chartMinutes == 15, state.style.email.display("name@example.com") == "n***@e***",
                  state.quotas[.codex]!.windows[0].usedPercent == raw, state.health.level == health,
                  state.quotaBasisLabel == "已用" else { return false }
            let window = state.quotas[.codex]!.windows[0]
            let pace = QuotaPace.calculate(window: window, now: state.now())
            guard state.quotaPercent(window) == raw,
                  state.quotaPaceMarker(pace).map({ abs($0 - (1 - pace!.expectedRemainingFraction)) < 0.00001 }) == true else { return false }
            guard style.email.display("name@example.com") == "n***@e***" else { return false }
            style.email = .hidden
            guard style.email.display("name@example.com") == nil else { return false }
            style.email = .full
            guard style.email.display("name@example.com") == "name@example.com" else { return false }
            var changed = false
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
                let selected = QuotaPalette.color(.codex, style: style)
                let original = QuotaPalette.color(.codex)
                changed = selected != original
            }
            guard changed else { return false }
            layout.overview.quota.window = "id:missing"
            try state.saveLayout(layout, for: "builtin.slim")
            guard state.overviewMetrics[1].value == "—", state.quotas[.codex]!.windows[0].usedPercent == raw else { return false }
            layout.overview.quota.window = "auto"
            try state.saveLayout(layout, for: "builtin.slim")
            return state.overviewMetrics[1].value == "40%"
        } catch { print("样式视图测试失败：\(error)"); return false }
    }
}
