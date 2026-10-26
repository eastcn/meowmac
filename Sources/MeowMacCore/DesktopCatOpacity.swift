import Foundation

/// 桌面猫的不透明度（D48）：猫和气泡分开调，20%～100%，步长 5%，默认 100%。
public enum DesktopCatOpacity {
    public static let defaultValue = 1.0
    public static let range: ClosedRange<Double> = 0.2...1.0
    public static let step = 0.05

    /// 配置里的值能不能直接用：有限、在 0.2～1.0 之内。不在 5% 步长上的合法值照原值用。
    public static func isValid(_ value: Double) -> Bool {
        value.isFinite && range.contains(value)
    }

    /// 写入前：先吸附到 5% 步长，再夹到 0.2～1.0；非有限值回到默认。
    public static func resolved(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        let snapped = (value / step).rounded() / (1 / step)
        return min(range.upperBound, max(range.lowerBound, snapped))
    }

    /// 显示用：坏值按 100%。
    public static func rendered(_ value: Double) -> Double {
        isValid(value) ? value : defaultValue
    }

    /// 滑块位置和百分比文字：四舍五入到 5%。
    public static func sliderValue(_ value: Double) -> Double { resolved(rendered(value)) }

    /// 例如 0.33 →“35%”。
    public static func percentText(_ value: Double) -> String {
        "\(Int((sliderValue(value) * 100).rounded()))%"
    }
}

/// 调哪一部分，值是 `desktopCat` 里的键名。
public enum DesktopCatOpacityPart: String, CaseIterable, Sendable {
    case cat = "catOpacity"
    case bubble = "bubbleOpacity"

    public var title: String {
        switch self {
        case .cat: return "猫的不透明度"
        case .bubble: return "气泡不透明度"
        }
    }

    /// 读取时的诊断，不含路径。
    var invalidNote: String {
        switch self {
        case .cat: return "桌面猫的猫不透明度无效，已按 100% 显示"
        case .bubble: return "桌面猫的气泡不透明度无效，已按 100% 显示"
        }
    }
}
