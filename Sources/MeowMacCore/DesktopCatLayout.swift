import CoreGraphics
import Foundation

/// 桌面猫的版式（D1，设计稿方案 A）。坐标以窗口内容左上角为原点，y 向下。
public struct DesktopCatLayout: Equatable {
    public static let catSize = CGSize(width: 120, height: 52)
    /// 内容四周的透明边距，容纳投影和拖动时的放大与倾斜。
    public static let inset: CGFloat = 16
    public static let itemWidth: CGFloat = 66, columnGap: CGFloat = 12, rowGap: CGFloat = 7
    public static let paddingH: CGFloat = 11, paddingV: CGFloat = 8
    /// 标签 12 + 数值 18 + 间距 3 + 横线 2。
    public static let labelHeight: CGFloat = 12, valueHeight: CGFloat = 18, barGap: CGFloat = 3, barHeight: CGFloat = 2
    public static var itemHeight: CGFloat { labelHeight + valueHeight + barGap + barHeight }
    public static let bubbleGap: CGFloat = 10, radius: CGFloat = 14
    public static let tailWidth: CGFloat = 12, tailHeight: CGFloat = 6
    /// 尾巴中心到气泡对齐边的距离。
    public static let tailOffset: CGFloat = 36
    public static let labelSize: CGFloat = 10, valueSize: CGFloat = 15, minimumValueSize: CGFloat = 12

    public let count: Int
    public let mirrored: Bool
    /// 猫图格子左边到猫可见左缘的距离。落在左边的角时，猫图往左挪这么多，让可见的猫和气泡左对齐。
    public let catTrim: CGFloat

    public init(count: Int, corner: DesktopCatCorner, catTrim: CGFloat = 0) {
        self.count = min(DesktopCatConfig.maxMetrics, max(1, count)); mirrored = corner.isLeft
        self.catTrim = max(0, min(catTrim, Self.catSize.width))
    }
    /// 左边的角时内容左侧多留的透明宽度，容纳猫图格子里猫左边的空白。
    private var leading: CGFloat { mirrored ? catTrim : 0 }

    public var columns: Int { count == 1 ? 1 : 2 }
    public var rows: Int { (count + columns - 1) / columns }
    public var bubbleSize: CGSize {
        let width = CGFloat(columns) * Self.itemWidth + CGFloat(columns - 1) * Self.columnGap + 2 * Self.paddingH
        let height = CGFloat(rows) * Self.itemHeight + CGFloat(rows - 1) * Self.rowGap + 2 * Self.paddingV
        return CGSize(width: width, height: height)
    }
    /// 猫和气泡的外接区域，不含透明边距。
    public var contentSize: CGSize {
        CGSize(width: max(Self.catSize.width, bubbleSize.width), height: bubbleSize.height + Self.bubbleGap + Self.catSize.height)
    }
    public var windowSize: CGSize { CGSize(width: contentSize.width + 2 * Self.inset + leading, height: contentSize.height + 2 * Self.inset) }
    /// 内容在窗口里的位置（y 向下）。
    public var contentRect: CGRect { CGRect(origin: CGPoint(x: Self.inset + leading, y: Self.inset), size: contentSize) }

    /// 右边的角时右对齐，左边的角时左对齐。
    private func aligned(width: CGFloat) -> CGFloat {
        mirrored ? contentRect.minX : contentRect.maxX - width
    }
    public var bubbleRect: CGRect {
        CGRect(origin: CGPoint(x: aligned(width: bubbleSize.width), y: contentRect.minY), size: bubbleSize)
    }
    /// 猫图格子。左边的角时左移 `catTrim`，可见的猫左缘与气泡左缘对齐。
    public var catRect: CGRect {
        CGRect(origin: CGPoint(x: aligned(width: Self.catSize.width) - leading, y: contentRect.maxY - Self.catSize.height), size: Self.catSize)
    }
    /// 尾巴三角形：底边贴气泡下沿，尖朝下指向猫头。
    public var tail: [CGPoint] {
        let bubble = bubbleRect
        let center = mirrored ? bubble.minX + Self.tailOffset : bubble.maxX - Self.tailOffset
        return [CGPoint(x: center - Self.tailWidth / 2, y: bubble.maxY), CGPoint(x: center + Self.tailWidth / 2, y: bubble.maxY),
                CGPoint(x: center, y: bubble.maxY + Self.tailHeight)]
    }
    /// 第 index 项在气泡里的位置（y 向下，相对气泡左上角）。
    public func itemOrigin(_ index: Int) -> CGPoint {
        CGPoint(x: Self.paddingH + CGFloat(index % columns) * (Self.itemWidth + Self.columnGap),
                y: Self.paddingV + CGFloat(index / columns) * (Self.itemHeight + Self.rowGap))
    }
}

/// 文字放不下时的规则（D7）：数值等比缩小，最小 12 pt，不出现省略号；标签先去掉右侧附注。
public enum DesktopCatTextFit {
    /// `measure(size)` 返回数值在该字号下的宽度。
    public static func valueSize(available: CGFloat = DesktopCatLayout.itemWidth,
                                 preferred: CGFloat = DesktopCatLayout.valueSize,
                                 minimum: CGFloat = DesktopCatLayout.minimumValueSize,
                                 measure: (CGFloat) -> CGFloat) -> CGFloat {
        // 字形宽度并不严格与字号成正比，按 0.5 pt 逐级缩小到放得下为止。
        var size = preferred
        while size > minimum && measure(size) > available { size -= 0.5 }
        return max(minimum, size)
    }
    /// 名称和附注之间至少留 4 pt；放不下时不显示附注。
    public static func showsNote(nameWidth: CGFloat, noteWidth: CGFloat, available: CGFloat = DesktopCatLayout.itemWidth, spacing: CGFloat = 4) -> Bool {
        nameWidth + spacing + noteWidth <= available
    }
}
