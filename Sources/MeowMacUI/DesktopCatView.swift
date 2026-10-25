import AppKit
import SwiftUI
import MeowMacCore

/// 气泡的指标、贴角和拖动状态。只在数值或版式变化时发布，逐帧的猫图在 `DesktopCatFrameModel`。
@MainActor
public final class DesktopCatViewModel: ObservableObject {
    @Published public var items: [DesktopCatItem] = []
    @Published public var corner: DesktopCatCorner = .bottomRight
    @Published public var dragging = false
    /// 当前猫图的可见左缘，见 `DesktopCatLayout.catTrim`。
    @Published public var catTrim: CGFloat = 0
    /// 猫的高度（pt）。拖把手时实时变化，松手才写配置（D47）。
    @Published public var catHeight: CGFloat = DesktopCatSize.defaultHeight
    /// 鼠标停在猫身上时显示缩放把手（plan D15）。
    @Published public var handleVisible = false
    /// 结束提示（D46），第 0 条贴着气泡（上方的角贴着猫）。只在选了“AI 会话”时有内容。
    @Published public var toasts: [AgentSessionToast] = [] {
        didSet { toastMetrics = toasts.prefix(DesktopCatLayout.maxToasts).map(DesktopCatToastText.metrics) }
    }
    /// 按真实字体量好的提示宽度和名称宽度，设置提示时算一次。
    public private(set) var toastMetrics: [DesktopCatToastText.Metrics] = []
    public let frame = DesktopCatFrameModel()
    public init() {}
    public var layout: DesktopCatLayout {
        DesktopCatLayout(count: items.count, corner: corner, catTrim: catTrim, catHeight: catHeight, toastWidths: toastMetrics.map(\.width))
    }
}

/// 逐帧更新的猫图。单独发布，换帧不重新计算气泡。
@MainActor
public final class DesktopCatFrameModel: ObservableObject {
    @Published public var image: NSImage?
    @Published public var dark = false
    @Published public var shadow = DesktopCatShadow.cat
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
            DesktopCatFigure(model: model.frame, size: cat.size)
                .frame(width: cat.width, height: cat.height)
                .offset(x: cat.minX, y: cat.minY)
            if model.handleVisible {
                let handle = layout.handleRect
                DesktopCatHandle().frame(width: handle.width, height: handle.height).offset(x: handle.minX, y: handle.minY)
            }
            ForEach(Array(zip(model.toasts.prefix(DesktopCatLayout.maxToasts), model.toastMetrics).enumerated()), id: \.element.0.id) { index, pair in
                let rect = layout.toastRect(index)
                DesktopCatToast(toast: pair.0, metrics: pair.1)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height, alignment: .topLeading)
        .scaleEffect(model.dragging ? 1.06 : 1)
        .rotationEffect(.degrees(model.dragging ? -4 : 0))
    }
}

struct DesktopCatFigure: View {
    @ObservedObject var model: DesktopCatFrameModel
    let size: CGSize
    var body: some View {
        // 投影随猫等比缩放：52 pt 时高 7 pt、模糊 2 pt、下沉 3 pt。
        let ratio = size.height / DesktopCatSize.defaultHeight
        ZStack(alignment: .topLeading) {
            // 脚下柔和的投影。
            Ellipse().fill(Color.black.opacity(model.dark ? 0.4 : 0.165)).blur(radius: 2 * ratio)
                .frame(width: model.shadow.width, height: 7 * ratio)
                .offset(x: model.shadow.x, y: size.height - 3 * ratio)
            if let image = model.image {
                Image(nsImage: image).renderingMode(.original).interpolation(.high)
                    .frame(width: size.width, height: size.height)
            }
        }.frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// 缩放把手：12 pt 圆，白底（深色外观用面板底色），1.5 pt `systemBlue` 描边（plan D15）。
struct DesktopCatHandle: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Circle()
            .fill(colorScheme == .dark ? Color(red: 0x25 / 255, green: 0x25 / 255, blue: 0x27 / 255) : Color.white)
            .overlay(Circle().strokeBorder(Design.blue, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
            .accessibilityLabel("调整桌面猫大小")
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

/// 结束提示（D46，plan D3）：玻璃胶囊，高 24 pt，最宽 220 pt，11 pt 字。
/// “✓ 名称 · 渠道 · 已完成 · 耗时”：名称过长只截断名称；合并的那条写“另有 n 个会话完成”。材质同气泡。
struct DesktopCatToast: View {
    @Environment(\.previewMaterial) private var previewMaterial
    @Environment(\.colorScheme) private var colorScheme
    let toast: AgentSessionToast
    let metrics: DesktopCatToastText.Metrics
    var body: some View {
        let content = HStack(spacing: DesktopCatToastText.spacing) {
            switch toast {
            case .single(let notice):
                Text("✓").font(DesktopCatToastText.checkFont).foregroundStyle(Design.state(.normal)).fixedSize()
                Text(notice.name).font(DesktopCatToastText.nameFont).foregroundStyle(Design.label)
                    .lineLimit(1).truncationMode(.tail).frame(width: metrics.nameWidth, alignment: .leading)
                Text(notice.detail).font(DesktopCatToastText.detailFont).foregroundStyle(Design.secondary).lineLimit(1).fixedSize()
            case .more:
                Text(toast.text).font(DesktopCatToastText.detailFont).foregroundStyle(Design.secondary).lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, DesktopCatToastText.padding)
        .frame(width: metrics.width, height: DesktopCatLayout.toastHeight, alignment: .leading)
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toast.text)
        let edge = colorScheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.8)
        if previewMaterial {
            content.background {
                Capsule().fill(colorScheme == .dark ? Color(red: 40 / 255, green: 41 / 255, blue: 46 / 255).opacity(0.7) : Color(red: 250 / 255, green: 251 / 255, blue: 253 / 255).opacity(0.78))
                    .overlay(Capsule().stroke(edge, lineWidth: 0.5))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.15), radius: 6, y: 3)
            }
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background {
                DesktopCatMaterial().clipShape(Capsule()).overlay(Capsule().stroke(edge, lineWidth: 0.5))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.15), radius: 6, y: 3)
            }
        }
    }
}

/// 结束提示的字体和测量：宽度按内容，最宽 220 pt；名称最宽 96 pt（设计稿），再放不下时只缩名称。
public enum DesktopCatToastText {
    public struct Metrics: Equatable {
        public let width: CGFloat
        public let nameWidth: CGFloat
    }
    static let padding: CGFloat = 10, spacing: CGFloat = 5, nameMaxWidth: CGFloat = 96
    static let checkFont = Font.system(size: 11, weight: .bold)
    static let nameFont = Font.system(size: 11, weight: .semibold)
    static let detailFont = Font.system(size: 11)
    static func width(_ text: String, weight: NSFont.Weight) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: weight)]).width)
    }
    public static func metrics(_ toast: AgentSessionToast) -> Metrics {
        switch toast {
        case .single(let notice):
            let fixed = 2 * padding + width("✓", weight: .bold) + 2 * spacing + width(notice.detail, weight: .regular)
            let name = min(width(notice.name, weight: .semibold), nameMaxWidth, max(0, DesktopCatLayout.toastMaxWidth - fixed))
            return Metrics(width: min(DesktopCatLayout.toastMaxWidth, fixed + name), nameWidth: name)
        case .more:
            return Metrics(width: min(DesktopCatLayout.toastMaxWidth, 2 * padding + width(toast.text, weight: .regular)), nameWidth: 0)
        }
    }
    /// 名称是否被截断。
    public static func truncatesName(_ toast: AgentSessionToast) -> Bool {
        guard case .single(let notice) = toast else { return false }
        return width(notice.name, weight: .semibold) > metrics(toast).nameWidth
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
        DesktopCatTextFit.valueSize { width(item.value, font: valueFont($0, missing: item.missing || item.muted)) }
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
                .font(Font(DesktopCatText.valueFont(valueSize, missing: item.missing || item.muted)))
                .foregroundStyle(item.missing || item.muted ? Design.secondary : item.valueLevel.map { Design.stateText($0) } ?? Design.label)
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
        DesktopCatText.width(item.value, font: DesktopCatText.valueFont(size, missing: item.missing || item.muted)) <= DesktopCatLayout.itemWidth
    }
    public static func showsNote(_ item: DesktopCatItem) -> Bool { DesktopCatText.showsNote(item) }
}
