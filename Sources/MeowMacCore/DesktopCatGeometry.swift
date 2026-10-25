import CoreGraphics
import Foundation

/// 一块屏幕：稳定标识、可见区域（AppKit 坐标，y 向上）和是否主屏。
public struct DesktopCatScreen: Equatable {
    public let id: String
    public let visibleFrame: CGRect
    public let isMain: Bool
    public init(id: String, visibleFrame: CGRect, isMain: Bool) {
        self.id = id; self.visibleFrame = visibleFrame; self.isMain = isMain
    }
}

/// 落位、吸附和多屏规则（D4、D13）。全部是纯函数。
public enum DesktopCatGeometry {
    /// 内容离可见区域侧边 16 pt、上下边 8 pt。
    public static let sideMargin: CGFloat = 16, verticalMargin: CGFloat = 8
    /// 移动不到 4 pt 算单击。
    public static let clickThreshold: CGFloat = 4

    /// 窗口在屏幕上的位置。透明边距算在窗口里，边距要求只看猫和气泡。
    public static func windowFrame(layout: DesktopCatLayout, corner: DesktopCatCorner, visibleFrame: CGRect) -> CGRect {
        let content = layout.contentSize, inset = DesktopCatLayout.inset
        let x = corner.isLeft ? visibleFrame.minX + sideMargin : visibleFrame.maxX - sideMargin - content.width
        let y = corner.isTop ? visibleFrame.maxY - verticalMargin - content.height : visibleFrame.minY + verticalMargin
        return CGRect(x: x - inset, y: y - inset, width: layout.windowSize.width, height: layout.windowSize.height)
    }

    /// 离窗口中心最近的角。正好在中线上时取右、下。
    public static func nearestCorner(windowFrame: CGRect, visibleFrame: CGRect) -> DesktopCatCorner {
        let left = windowFrame.midX < visibleFrame.midX
        let top = windowFrame.midY > visibleFrame.midY
        switch (left, top) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    public static func isClick(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) < clickThreshold
    }

    /// 已存的屏幕还在就用它；不在时放到主屏，已存的标识不改（屏幕接回后回到原屏）。
    public static func resolve(_ placement: DesktopCatPlacement, screens: [DesktopCatScreen]) -> (screen: DesktopCatScreen, fallback: Bool)? {
        let main = screens.first(where: \.isMain) ?? screens.first
        guard let main else { return nil }
        guard let id = placement.display else { return (main, false) }
        if let stored = screens.first(where: { $0.id == id }) { return (stored, false) }
        return (main, true)
    }

    /// 松手时窗口中心所在的屏幕；中心落在所有可见区域之外时取最近的一块。
    public static func screen(containing point: CGPoint, screens: [DesktopCatScreen]) -> DesktopCatScreen? {
        if let inside = screens.first(where: { $0.visibleFrame.contains(point) }) { return inside }
        return screens.min { distance(point, $0.visibleFrame) < distance(point, $1.visibleFrame) }
    }

    static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX), dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// 松手后的位置：所在屏幕和最近的角。
    public static func drop(windowFrame: CGRect, screens: [DesktopCatScreen]) -> (screen: DesktopCatScreen, corner: DesktopCatCorner)? {
        guard let screen = screen(containing: CGPoint(x: windowFrame.midX, y: windowFrame.midY), screens: screens) else { return nil }
        return (screen, nearestCorner(windowFrame: windowFrame, visibleFrame: screen.visibleFrame))
    }
}

/// 猫图的 alpha 掩码，y 向下，行优先。
public struct DesktopCatAlphaMask: Equatable {
    public let width: Int, height: Int
    public let alpha: [UInt8]
    public init(width: Int, height: Int, alpha: [UInt8]) { self.width = width; self.height = height; self.alpha = alpha }
    /// `x`、`y` 是 0～1 的相对位置。
    public func opaque(x: CGFloat, y: CGFloat, threshold: UInt8 = 24) -> Bool {
        guard width > 0, height > 0, x >= 0, x < 1, y >= 0, y < 1, alpha.count == width * height else { return false }
        return alpha[Int(y * CGFloat(height)) * width + Int(x * CGFloat(width))] > threshold
    }
}

/// 点击判断（D11）：只有猫的不透明像素、气泡圆角矩形和尾巴接收鼠标。坐标以窗口左上角为原点，y 向下。
public struct DesktopCatHitShape {
    public let layout: DesktopCatLayout
    public let catMask: DesktopCatAlphaMask?
    public init(layout: DesktopCatLayout, catMask: DesktopCatAlphaMask?) { self.layout = layout; self.catMask = catMask }

    public func contains(_ point: CGPoint) -> Bool {
        inBubble(point) || inTail(point) || inCat(point)
    }

    func inBubble(_ p: CGPoint) -> Bool {
        let rect = layout.bubbleRect, r = DesktopCatLayout.radius
        guard rect.contains(p) else { return false }
        let cx = min(max(p.x, rect.minX + r), rect.maxX - r), cy = min(max(p.y, rect.minY + r), rect.maxY - r)
        return hypot(p.x - cx, p.y - cy) <= r
    }

    func inTail(_ p: CGPoint) -> Bool {
        let t = layout.tail
        func sign(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y) }
        let d1 = sign(p, t[0], t[1]), d2 = sign(p, t[1], t[2]), d3 = sign(p, t[2], t[0])
        let negative = d1 < 0 || d2 < 0 || d3 < 0, positive = d1 > 0 || d2 > 0 || d3 > 0
        return !(negative && positive)
    }

    func inCat(_ p: CGPoint) -> Bool {
        let rect = layout.catRect
        guard rect.contains(p) else { return false }
        guard let catMask else { return true }
        return catMask.opaque(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
    }
}
