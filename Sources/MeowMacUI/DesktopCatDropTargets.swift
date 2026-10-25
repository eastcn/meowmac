import AppKit
import SwiftUI
import MeowMacCore

/// 拖动时的四角落点框（plan D14，设计稿拖动态）。坐标相对落点所在屏幕的可见区域左上角，y 向下。
@MainActor
public final class DesktopCatDropModel: ObservableObject {
    public struct Target: Equatable {
        public let corner: DesktopCatCorner
        public let rect: CGRect
        public let highlighted: Bool
    }
    @Published public var targets: [Target] = []
    @Published public var size: CGSize = .zero
    public init() {}

    /// 换成相对可见区域的坐标；没变时不发布。
    public func update(_ targets: [DesktopCatDropTarget], visibleFrame: CGRect) {
        let local = targets.map { target in
            Target(corner: target.corner, highlighted: target.highlighted,
                   rect: CGRect(x: target.rect.minX - visibleFrame.minX, y: visibleFrame.maxY - target.rect.maxY,
                                width: target.rect.width, height: target.rect.height))
        }
        if local != self.targets { self.targets = local }
        if visibleFrame.size != size { size = visibleFrame.size }
    }
}

extension DesktopCatDropModel.Target {
    init(corner: DesktopCatCorner, highlighted: Bool, rect: CGRect) {
        self.corner = corner; self.rect = rect; self.highlighted = highlighted
    }
}

/// 四个角显示虚线落点，离窗口中心最近的变蓝色实线。
struct DesktopCatDropTargetsView: View {
    @ObservedObject var model: DesktopCatDropModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.targets, id: \.corner) { target in
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                shape.fill(target.highlighted ? Color(nsColor: .systemBlue).opacity(0.14) : Color.clear)
                    .overlay(shape.strokeBorder(target.highlighted ? Color(nsColor: .systemBlue) : Color.primary.opacity(0.35),
                                                style: StrokeStyle(lineWidth: 1.5, dash: target.highlighted ? [] : [5, 4])))
                    .frame(width: target.rect.width, height: target.rect.height)
                    .offset(x: target.rect.minX, y: target.rect.minY)
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
    }
}
