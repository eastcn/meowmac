import AppKit
import Foundation
import MeowMacCore
import MeowMacUI

/// 猫与气泡视图（plan 条目 3）。
@MainActor
enum DesktopCatViewTests {
    static var tests: [(String, @MainActor () async -> Bool)] {
        var list: [(String, @MainActor () async -> Bool)] = [
            ("Core.DesktopCat/气泡版式尺寸、对齐与尾巴", { layout() }),
            ("Core.DesktopCat/缩字最小 12 pt 与附注去除", { textFit() }),
            ("UI.DesktopCat/猫图缓存同一帧不重复光栅化", { imageCache() }),
            ("UI.DesktopCat/真实字体下的缩字与附注", { realText() }),
        ]
        if ProcessInfo.processInfo.environment["MEOWMAC_RENDER_DIR"] != nil {
            list.append(("UI.DesktopCat.Preview/方案 A 合成预览浅深", { previews() }))
        }
        return list
    }

    static func layout() -> Bool {
        let four = DesktopCatLayout(count: 4, corner: .bottomRight)
        guard four.columns == 2, four.rows == 2, four.bubbleSize == CGSize(width: 166, height: 93),
              four.contentSize == CGSize(width: 166, height: 155), four.windowSize == CGSize(width: 198, height: 187) else { return false }
        // 右边的角：气泡和猫右对齐；气泡离猫 10 pt；尾巴在右侧 36 pt 处朝下。
        guard four.bubbleRect.maxX == four.catRect.maxX, four.catRect.minY - four.bubbleRect.maxY == 10,
              four.tail[2] == CGPoint(x: four.bubbleRect.maxX - 36, y: four.bubbleRect.maxY + 6) else { return false }
        let left = DesktopCatLayout(count: 4, corner: .topLeft)
        guard left.mirrored, left.bubbleRect.minX == left.catRect.minX, left.tail[2].x == left.bubbleRect.minX + 36 else { return false }
        let one = DesktopCatLayout(count: 1, corner: .bottomRight)
        guard one.columns == 1, one.bubbleSize == CGSize(width: 88, height: 51), one.contentSize.width == 120,
              one.bubbleRect.maxX == one.catRect.maxX else { return false }
        let three = DesktopCatLayout(count: 3, corner: .bottomLeft)
        guard three.rows == 2, three.itemOrigin(2) == CGPoint(x: 11, y: 50), three.itemOrigin(1) == CGPoint(x: 89, y: 8) else { return false }
        // 越界的数量按 1～4 处理。
        return DesktopCatLayout(count: 0, corner: .bottomRight).count == 1 && DesktopCatLayout(count: 9, corner: .bottomRight).count == 4
    }

    static func textFit() -> Bool {
        // 宽度与字号成正比的测量。
        func linear(_ widthAt15: CGFloat) -> (CGFloat) -> CGFloat { { size in widthAt15 * size / 15 } }
        guard DesktopCatTextFit.valueSize(measure: linear(40)) == 15,
              DesktopCatTextFit.valueSize(measure: linear(66)) == 15 else { return false }
        let shrunk = DesktopCatTextFit.valueSize(measure: linear(80))
        guard shrunk < 15, shrunk >= 12, linear(80)(shrunk) <= 66 else { return false }
        guard DesktopCatTextFit.valueSize(measure: linear(200)) == 12 else { return false }
        return DesktopCatTextFit.showsNote(nameWidth: 20, noteWidth: 30)
            && !DesktopCatTextFit.showsNote(nameWidth: 30, noteWidth: 40)
            && DesktopCatTextFit.showsNote(nameWidth: 31, noteWidth: 31)
    }

    static func imageCache() -> Bool {
        let state = PanelPreviewRenderer.syntheticState()
        let cache = DesktopCatImage()
        let display = state.catDisplay(reducedMotion: false)
        let first = cache.image(cat: state.selectedCat, display: display, frame: 1, dark: false, scale: 2)
        let again = cache.image(cat: state.selectedCat, display: display, frame: 6, dark: false, scale: 2)
        guard first === again, cache.rasterizations == 1, first.size == DesktopCatLayout.catSize else { return false }
        _ = cache.image(cat: state.selectedCat, display: display, frame: 2, dark: false, scale: 2)
        _ = cache.image(cat: state.selectedCat, display: display, frame: 2, dark: true, scale: 2)
        guard cache.rasterizations == 3 else { return false }
        // 减少动态效果：所有帧都是第 1 帧。
        let still = state.catDisplay(reducedMotion: true)
        let a = cache.image(cat: state.selectedCat, display: still, frame: 3, dark: false, scale: 2)
        let b = cache.image(cat: state.selectedCat, display: still, frame: 4, dark: false, scale: 2)
        guard a === b, cache.rasterizations == 4 else { return false }
        // 严重睡姿只有一帧。
        state.catLevelOverride = .severe
        let severe = state.catDisplay(reducedMotion: false)
        let s1 = cache.image(cat: state.selectedCat, display: severe, frame: 1, dark: false, scale: 2)
        let s2 = cache.image(cat: state.selectedCat, display: severe, frame: 3, dark: false, scale: 2)
        guard s1 === s2, cache.rasterizations == 5 else { return false }
        // 像素尺寸按显示尺度，猫图不透明。
        guard let rep = s1.representations.first as? NSBitmapImageRep, rep.pixelsWide == 240, rep.pixelsHigh == 104 else { return false }
        var opaque = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 } }
        return opaque > 100
    }

    static func realText() -> Bool {
        let wide = DesktopCatItem(id: "network.speed", label: "网络", note: "↑1023.9M", value: "↓1023.9M", bar: 1, color: .gray, fullName: "整机网速")
        let size = DesktopCatTextMetrics.valueSize(wide)
        let normal = DesktopCatTextMetrics.valueSize(DesktopCatItem(id: "system.cpu", label: "CPU", value: "24%", bar: 0.24, color: .blue, fullName: "CPU"))
        let short = DesktopCatItem(id: "quota.claude.minutes:300", label: "Claude", note: "5h", value: "72%", bar: 0.72, color: .state(.normal), fullName: "")
        let longNote = DesktopCatItem(id: "network.status", label: "网络", note: "主网络 DNS 失败", value: "异常", bar: 1, color: .state(.severe), fullName: "")
        return normal == 15 && size < 15 && size >= 12 && DesktopCatTextMetrics.fits(wide, size: size)
            && DesktopCatTextMetrics.showsNote(short) && !DesktopCatTextMetrics.showsNote(longNote)
    }

    static func previews() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["MEOWMAC_RENDER_DIR"] else { return false }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var count = 0
            let cache = DesktopCatImage()
            for kind in DesktopCatPreview.Case.allCases {
                for dark in [false, true] {
                    guard let data = DesktopCatPreview.png(kind, dark: dark, cache: cache), !data.isEmpty else { return false }
                    try data.write(to: directory.appendingPathComponent("desktop-cat-\(kind.rawValue)-\(dark ? "dark" : "light").png"))
                    count += 1
                }
            }
            for dark in [false, true] {
                guard let data = DesktopCatPreview.dragPNG(dark: dark, cache: cache), !data.isEmpty else { return false }
                try data.write(to: directory.appendingPathComponent("desktop-cat-drag-\(dark ? "dark" : "light").png"))
                count += 1
            }
            print("桌面猫合成预览：\(count) 张，输出 \(directory.path)")
            return count == DesktopCatPreview.Case.allCases.count * 2 + 2
        } catch { print("桌面猫预览失败：\(error)"); return false }
    }
}
