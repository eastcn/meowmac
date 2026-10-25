import CoreGraphics
import Foundation

/// 桌面猫的大小（D47，plan D14～D16）：猫的高度 36～104 pt，默认 52 pt；宽度按帧图比例，52 pt 高时 120 pt 宽。
/// 只缩放猫、投影和速度线，气泡的版式和字号不变。全部是纯函数。
public enum DesktopCatSize {
    public static let defaultHeight: CGFloat = 52
    public static let range: ClosedRange<CGFloat> = 36...104
    /// 落在这个范围时吸附到默认高度。
    public static let snapRange: ClosedRange<CGFloat> = 49...55
    /// 52 pt 高时的宽度。
    public static let defaultWidth: CGFloat = 120

    /// 配置里的值能不能直接用：有限、在 36～104 之内。
    public static func isValid(_ height: Double) -> Bool {
        height.isFinite && range.contains(CGFloat(height))
    }

    /// 夹到 36～104 并取整到点；非有限值回到默认。
    public static func clamped(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return defaultHeight }
        return min(range.upperBound, max(range.lowerBound, height.rounded()))
    }

    /// 拖把手或滑块时的结果：先夹取、取整，再在 49～55 时吸附到 52。
    public static func resolved(_ height: CGFloat) -> CGFloat {
        let value = clamped(height)
        return snapRange.contains(value) ? defaultHeight : value
    }

    /// 渲染用的高度：配置值取整到点，坏值按默认。
    public static func rendered(_ height: Double) -> CGFloat {
        isValid(height) ? CGFloat(height).rounded() : defaultHeight
    }

    /// 猫图格子的尺寸。
    public static func catSize(height: CGFloat) -> CGSize {
        CGSize(width: (defaultWidth * height / defaultHeight).rounded(), height: height)
    }

    /// 拖把手时的新高度。`delta` 是鼠标从按下处移动的距离（屏幕坐标，y 向上）。
    /// 把手在猫朝屏幕内侧的上角：往屏幕内侧拖、下方的角往上拖、上方的角往下拖都是放大。
    /// 横向距离按宽高比折成高度，取横纵两者中绝对值较大的一个。
    public static func dragged(from start: CGFloat, delta: CGVector, corner: DesktopCatCorner) -> CGFloat {
        let inward = corner.isLeft ? delta.dx : -delta.dx
        let horizontal = inward * defaultHeight / defaultWidth
        let vertical = corner.isTop ? -delta.dy : delta.dy
        let growth = abs(horizontal) > abs(vertical) ? horizontal : vertical
        return resolved(start + growth)
    }
}
