import AppKit
import SwiftUI
import MeowMacCore

/// 气泡的指标、贴角和拖动状态。只在数值或版式变化时发布，逐帧的猫图在 `DesktopCatFrameModel`。
@MainActor
public final class DesktopCatViewModel: ObservableObject {
    @Published public var items: [DesktopCatItem] = []
    @Published public var corner: DesktopCatCorner = .bottomRight
    @Published public var dragging = false
    public let frame = DesktopCatFrameModel()
    public init() {}
    public var layout: DesktopCatLayout { DesktopCatLayout(count: items.count, corner: corner) }
}

/// 逐帧更新的猫图。单独发布，换帧不重新计算气泡。
@MainActor
public final class DesktopCatFrameModel: ObservableObject {
    @Published public var image: NSImage?
    @Published public var dark = false
    public init() {}
}

/// 窗口的全部内容：头顶的气泡、猫和脚下的投影。透明边距之外不画任何东西。
public struct DesktopCatContentView: View {
    @ObservedObject private var model: DesktopCatViewModel
    public init(model: DesktopCatViewModel) { self.model = model }
    public var body: some View {
        let layout = model.layout
        let bubble = layout.bubbleRect, cat = layout.catRect
        ZStack(alignment: .topLeading) {
            DesktopCatBubble(items: model.items, layout: layout)
                .frame(width: bubble.width, height: bubble.height + DesktopCatLayout.tailHeight, alignment: .topLeading)
                .offset(x: bubble.minX, y: bubble.minY)
            DesktopCatFigure(model: model.frame)
                .frame(width: cat.width, height: cat.height)
                .offset(x: cat.minX, y: cat.minY)
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height, alignment: .topLeading)
        .scaleEffect(model.dragging ? 1.06 : 1)
        .rotationEffect(.degrees(model.dragging ? -4 : 0))
    }
}

struct DesktopCatFigure: View {
    @ObservedObject var model: DesktopCatFrameModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            // 脚下柔和的投影。
            Ellipse().fill(Color.black.opacity(model.dark ? 0.4 : 0.165)).blur(radius: 2)
                .frame(width: DesktopCatLayout.catSize.width - 28, height: 7)
                .offset(x: 18, y: DesktopCatLayout.catSize.height - 3)
            if let image = model.image {
                Image(nsImage: image).renderingMode(.original).interpolation(.high)
                    .frame(width: DesktopCatLayout.catSize.width, height: DesktopCatLayout.catSize.height)
            }
        }.frame(width: DesktopCatLayout.catSize.width, height: DesktopCatLayout.catSize.height, alignment: .topLeading)
    }
}

/// 圆角矩形加一个朝下的尾巴。尾巴在对齐边一侧，指向猫头。
struct DesktopCatBubbleShape: Shape {
    let tailCenter: CGFloat
    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - DesktopCatLayout.tailHeight)
        var path = Path(roundedRect: body, cornerRadius: DesktopCatLayout.radius, style: .continuous)
        path.move(to: CGPoint(x: tailCenter - DesktopCatLayout.tailWidth / 2, y: body.maxY - 0.5))
        path.addLine(to: CGPoint(x: tailCenter, y: body.maxY + DesktopCatLayout.tailHeight))
        path.addLine(to: CGPoint(x: tailCenter + DesktopCatLayout.tailWidth / 2, y: body.maxY - 0.5))
        path.closeSubpath()
        return path
    }
}

struct DesktopCatBubble: View {
    @Environment(\.previewMaterial) private var previewMaterial
    @Environment(\.colorScheme) private var colorScheme
    let items: [DesktopCatItem]
    let layout: DesktopCatLayout
    private var shape: DesktopCatBubbleShape {
        let width = layout.bubbleSize.width
        return DesktopCatBubbleShape(tailCenter: layout.mirrored ? DesktopCatLayout.tailOffset : width - DesktopCatLayout.tailOffset)
    }
    var body: some View {
        let rows = stride(from: 0, to: items.count, by: layout.columns).map { Array(items[$0..<min($0 + layout.columns, items.count)]) }
        let content = VStack(alignment: .leading, spacing: DesktopCatLayout.rowGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: DesktopCatLayout.columnGap) {
                    ForEach(row, id: \.id) { DesktopCatMetricView(item: $0) }
                }
            }
        }
        .padding(.horizontal, DesktopCatLayout.paddingH).padding(.vertical, DesktopCatLayout.paddingV)
        .frame(width: layout.bubbleSize.width, height: layout.bubbleSize.height, alignment: .topLeading)
        .frame(height: layout.bubbleSize.height + DesktopCatLayout.tailHeight, alignment: .top)
        let edge = colorScheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.8)
        // 液态玻璃，不叠加面板的暖色渐变（D33）。离线预览用设计稿的半透明底色代替玻璃。
        if previewMaterial {
            content.background {
                shape.fill(colorScheme == .dark ? Color(red: 40 / 255, green: 41 / 255, blue: 46 / 255).opacity(0.7) : Color(red: 250 / 255, green: 251 / 255, blue: 253 / 255).opacity(0.78))
                    .overlay(shape.stroke(edge, lineWidth: 0.5))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.15), radius: 10, y: 6)
            }
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background {
                DesktopCatMaterial().clipShape(shape).overlay(shape.stroke(edge, lineWidth: 0.5))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.15), radius: 10, y: 6)
            }
        }
    }
}

/// macOS 14～15 的退路：`.hudWindow` 材质。
struct DesktopCatMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// 文字测量与气泡里一项的排版。
enum DesktopCatText {
    static func valueFont(_ size: CGFloat, missing: Bool) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: missing ? .medium : .semibold)
    }
    static func width(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    static func valueSize(_ item: DesktopCatItem) -> CGFloat {
        DesktopCatTextFit.valueSize { width(item.value, font: valueFont($0, missing: item.missing)) }
    }
    static func showsNote(_ item: DesktopCatItem) -> Bool {
        guard let note = item.note, !note.isEmpty else { return false }
        let font = NSFont.systemFont(ofSize: DesktopCatLayout.labelSize)
        return DesktopCatTextFit.showsNote(nameWidth: width(item.label, font: font), noteWidth: width(note, font: font))
    }
}

struct DesktopCatMetricView: View {
    let item: DesktopCatItem
    var body: some View {
        let valueSize = DesktopCatText.valueSize(item)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(item.label).fixedSize()
                Spacer(minLength: 4)
                if DesktopCatText.showsNote(item), let note = item.note { Text(note).fixedSize() }
            }
            .font(.system(size: DesktopCatLayout.labelSize)).monospacedDigit().foregroundStyle(Design.secondary)
            .frame(height: DesktopCatLayout.labelHeight)
            Text(item.value)
                .font(Font(DesktopCatText.valueFont(valueSize, missing: item.missing)))
                .foregroundStyle(item.missing ? Design.secondary : item.valueLevel.map { Design.stateText($0) } ?? Design.label)
                .lineLimit(1).fixedSize()
                .frame(height: DesktopCatLayout.valueHeight, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(item.bar == nil ? Color.clear : Design.track)
                if let bar = item.bar {
                    Capsule().fill(Self.color(item.color)).frame(width: DesktopCatLayout.itemWidth * bar)
                }
            }
            .frame(width: DesktopCatLayout.itemWidth, height: DesktopCatLayout.barHeight)
            .padding(.top, DesktopCatLayout.barGap)
        }
        .frame(width: DesktopCatLayout.itemWidth, height: DesktopCatLayout.itemHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .help(item.tooltip())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.tooltip())
    }
    static func color(_ color: DesktopCatColor) -> Color {
        switch color {
        case .blue: return Design.blue
        case .teal: return Design.teal
        case .gray: return Design.gray
        case .orange: return Design.orange
        case .indigo: return Design.indigo
        case .brown: return Design.brown
        case .state(let level): return Design.state(level)
        }
    }
}

/// 按真实字体测量的缩字和附注规则，视图与测试共用。
public enum DesktopCatTextMetrics {
    public static func valueSize(_ item: DesktopCatItem) -> CGFloat { DesktopCatText.valueSize(item) }
    public static func fits(_ item: DesktopCatItem, size: CGFloat) -> Bool {
        DesktopCatText.width(item.value, font: DesktopCatText.valueFont(size, missing: item.missing)) <= DesktopCatLayout.itemWidth
    }
    public static func showsNote(_ item: DesktopCatItem) -> Bool { DesktopCatText.showsNote(item) }
}
