import Foundation

public enum QuotaBasis: String, Codable, CaseIterable { case remaining, used }
public enum EmailDisplay: String, Codable, CaseIterable {
    case full, masked, hidden
    public static func mask(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at != email.startIndex,
              let first = email.first, let domain = email[email.index(after: at)...].first else { return email }
        return "\(first)***@\(domain)***"
    }
    public func display(_ email: String?) -> String? {
        guard let email else { return nil }
        switch self { case .full: return email; case .masked: return Self.mask(email); case .hidden: return nil }
    }
}

public enum ThemeColor: String, Codable, CaseIterable {
    case `default`, orange, blue, teal, green, purple, pink, gray
    public var title: String {
        switch self {
        case .default: return "默认"; case .orange: return "橙"; case .blue: return "蓝"
        case .teal: return "青"; case .green: return "绿"; case .purple: return "紫"
        case .pink: return "粉"; case .gray: return "灰"
        }
    }
    public var hexPair: (light: String, dark: String)? {
        switch self {
        case .default: return nil
        case .orange: return ("#D97757", "#E68C6F")
        case .blue: return ("#4D6BFE", "#8091FF")
        case .teal: return ("#1E9E8F", "#48BAAB")
        case .green: return ("#3F9B4A", "#65B86D")
        case .purple: return ("#8B5CC6", "#AB83DC")
        case .pink: return ("#D6528A", "#E37BA7")
        case .gray: return ("#8E8E93", "#AAAAAF")
        }
    }
}

public enum StyleError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let reason) = self { return "样式无效：\(reason)" }
        return nil
    }
}

public struct StyleSettings: Codable, Equatable {
    public var schemaVersion = 1
    public var quotaBasis: QuotaBasis = .remaining
    public var email: EmailDisplay = .full
    public var chartMinutes = 60
    public var colors: [String: ThemeColor] = Dictionary(uniqueKeysWithValues: QuotaProvider.defaults.map { ($0.rawValue, .default) })
    public init() {}
    public static let `default` = StyleSettings()
    public func color(for provider: QuotaProvider) -> ThemeColor { colors[provider.rawValue] ?? .default }
    public func validated() throws -> StyleSettings {
        guard schemaVersion == 1, [15, 60].contains(chartMinutes),
              Set(QuotaProvider.defaults.map(\.rawValue)).isSubset(of: Set(colors.keys)),
              colors.keys.allSatisfy({ QuotaCatalog.usageNames[$0] != nil }) else { throw StyleError.invalid("版本、范围或渠道颜色不完整") }
        return self
    }
    public static func parse(_ data: Data) throws -> StyleSettings {
        func fail() -> StyleError { .invalid("字段或类型错误") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "quotaBasis", "email", "chartMinutes", "colors"],
              let version = root["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let minutes = root["chartMinutes"] as? NSNumber, CFGetTypeID(minutes) != CFBooleanGetTypeID(),
              minutes.doubleValue.isFinite, Double(minutes.intValue) == minutes.doubleValue,
              let basisName = root["quotaBasis"] as? String, let basis = QuotaBasis(rawValue: basisName),
              let emailName = root["email"] as? String, let email = EmailDisplay(rawValue: emailName),
              let rawColors = root["colors"] as? [String: String],
              Set(QuotaProvider.defaults.map(\.rawValue)).isSubset(of: Set(rawColors.keys)) else { throw fail() }
        var result = StyleSettings()
        result.quotaBasis = basis; result.email = email; result.chartMinutes = minutes.intValue
        for (provider, value) in rawColors {
            guard let color = ThemeColor(rawValue: value) else { throw fail() }
            result.colors[provider] = color
        }
        return try result.validated()
    }
}
