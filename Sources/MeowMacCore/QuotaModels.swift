import Foundation

public enum QuotaProvider: String, CaseIterable, Codable {
    case deepseek, codex, claude, opencodego
}

public struct QuotaWindow: Codable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    public let resetDescription: String?
    public let identifier: String
    public let name: String?

    public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?, resetDescription: String?, identifier: String = "primary", name: String? = nil) {
        self.usedPercent = usedPercent; self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt; self.resetDescription = resetDescription
        self.identifier = identifier; self.name = name
    }
}

public extension QuotaProvider {
    var displayName: String {
        switch self { case .claude: return "Claude"; case .codex: return "Codex"; case .deepseek: return "DeepSeek"; case .opencodego: return "OpenCode Go" }
    }
}

public extension QuotaWindow {
    var effectiveWindowMinutes: Int? {
        if let minutes = windowMinutes { return minutes }
        return Self.inferredWindowMinutes(name: name)
    }
    static func inferredWindowMinutes(name: String?) -> Int? {
        guard let name else { return nil }
        if name.contains("5 小时") { return 300 }
        if name.contains("7 天") || name.contains("每周") { return 10080 }
        return nil
    }
    var displayName: String {
        if let name, !name.isEmpty { return name.contains("窗口") ? name : name + "窗口" }
        switch effectiveWindowMinutes {
        case 300: return "5 小时窗口"
        case 10080: return "7 天窗口"
        case 43200: return "每月窗口"
        case .some(let minutes): return "\(minutes / 60) 小时窗口"
        case nil: return "额度窗口"
        }
    }
    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
}

public struct QuotaResetCredits: Codable {
    public let availableCount: Int
    public let expiresAt: [Date]
    public init(availableCount: Int, expiresAt: [Date]) { self.availableCount = availableCount; self.expiresAt = expiresAt }
}

public struct QuotaSnapshot: Codable {
    public let provider: QuotaProvider
    public let source: String
    public let updatedAt: Date
    public let windows: [QuotaWindow]
    public let paceSummary: String?
    public let credits: Double?
    public let accountEmail: String?
    public let planName: String?
    public let codexResetCredits: QuotaResetCredits?

    public init(provider: QuotaProvider, source: String, updatedAt: Date, windows: [QuotaWindow], paceSummary: String?, credits: Double?, accountEmail: String? = nil, planName: String? = nil, codexResetCredits: QuotaResetCredits? = nil) {
        self.provider = provider; self.source = source; self.updatedAt = updatedAt
        self.windows = windows; self.paceSummary = paceSummary; self.credits = credits
        self.accountEmail = accountEmail; self.planName = planName; self.codexResetCredits = codexResetCredits
    }
}

public struct CostModel: Codable {
    public let name: String
    public let tokens: Int
    public init(name: String, tokens: Int) { self.name = name; self.tokens = tokens }
}

public struct DailyCost: Codable {
    public let date: String
    public let totalCost: Double
    public let totalTokens: Int?
    public let models: [CostModel]
    public init(date: String, totalCost: Double, totalTokens: Int? = nil, models: [CostModel] = []) {
        self.date = date; self.totalCost = totalCost; self.totalTokens = totalTokens; self.models = models
    }
}

public struct SessionActivity {
    public let provider: QuotaProvider
    public let active: Bool
    public init(provider: QuotaProvider, active: Bool) { self.provider = provider; self.active = active }
}

public enum QuotaParseError: Error { case invalidRoot, missingProvider, missingUsage, missingWindow }

public enum CodexBarParser {
    public static func dashboard(_ data: Data, at now: Date) throws -> (snapshots: [QuotaProvider: QuotaSnapshot], errors: [QuotaProvider: String]) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["providers"] as? [[String: Any]] else { throw QuotaParseError.invalidRoot }
        var snapshots: [QuotaProvider: QuotaSnapshot] = [:]
        var errors: [QuotaProvider: String] = [:]
        for row in rows {
            guard let id = row["id"] as? String, let provider = QuotaProvider(rawValue: id.lowercased()) else { continue }
            if let error = row["error"] as? String { errors[provider] = error; continue }
            if let error = row["error"] as? [String: Any] { errors[provider] = error["message"] as? String ?? "采集失败"; continue }
            guard let windowRows = row["windows"] as? [[String: Any]] else {
                errors[provider] = "窗口数据缺失"
                continue
            }
            let windows = windowRows.prefix(3).compactMap { window -> QuotaWindow? in
                guard let used = number(window["usedPercent"]) else { return nil }
                let kind = window["kind"] as? String ?? "primary"
                let minutes = window["windowMinutes"] as? Int
                    ?? (kind == "session" ? 300 : kind == "weekly" ? 10080 : QuotaWindow.inferredWindowMinutes(name: window["label"] as? String))
                return QuotaWindow(usedPercent: used, windowMinutes: minutes,
                    resetsAt: (window["resetAt"] as? String).flatMap(parseDate),
                    resetDescription: nil, identifier: kind, name: window["label"] as? String)
            }
            guard !windows.isEmpty else { errors[provider] = "窗口数据无效"; continue }
            let pace = (row["display"] as? [String: Any])?["paceSummary"] as? String
            let credits = number((row["credits"] as? [String: Any])?["remaining"])
            let updated = (row["updatedAt"] as? String).flatMap(parseDate) ?? now
            snapshots[provider] = QuotaSnapshot(provider: provider, source: row["source"] as? String ?? "未知",
                updatedAt: updated, windows: windows, paceSummary: pace, credits: credits)
        }
        return (snapshots, errors)
    }

    public static func usage(_ data: Data, at now: Date) throws -> QuotaSnapshot {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let row = rows.first else {
            throw QuotaParseError.invalidRoot
        }
        guard let name = row["provider"] as? String, let provider = QuotaProvider(rawValue: name.lowercased()) else {
            throw QuotaParseError.missingProvider
        }
        guard let usage = row["usage"] as? [String: Any] else { throw QuotaParseError.missingUsage }
        let windows = ["primary", "secondary", "tertiary"].compactMap { key -> QuotaWindow? in
            guard let item = usage[key] as? [String: Any], let percent = number(item["usedPercent"]) else { return nil }
            let date = (item["resetsAt"] as? String).flatMap(parseDate)
            return QuotaWindow(usedPercent: percent, windowMinutes: item["windowMinutes"] as? Int,
                               resetsAt: date, resetDescription: item["resetDescription"] as? String, identifier: key,
                               name: provider == .codex && key == "secondary" ? "每周" : nil)
        }
        guard !windows.isEmpty else { throw QuotaParseError.missingWindow }
        let pace = ((row["pace"] as? [String: Any])?["secondary"] as? [String: Any])?["summary"] as? String
            ?? (usage["pace"] as? [String: Any])?["summary"] as? String
        let creditsObject = row["credits"] as? [String: Any] ?? usage["credits"] as? [String: Any]
        let credits = number(creditsObject?["remaining"] ?? creditsObject?["balance"] ?? usage["credits"])
        let identity = usage["identity"] as? [String: Any] ?? [:]
        let resetObject = usage["codexResetCredits"] as? [String: Any]
        let resetCredits = resetObject.map { object in
            QuotaResetCredits(availableCount: object["availableCount"] as? Int ?? 0,
                expiresAt: (object["credits"] as? [[String: Any]] ?? []).compactMap { ($0["expires_at"] as? String).flatMap(parseDate) })
        }
        return QuotaSnapshot(provider: provider, source: row["source"] as? String ?? "未知", updatedAt: (usage["updatedAt"] as? String).flatMap(parseDate) ?? now,
                             windows: windows, paceSummary: pace, credits: credits,
                             accountEmail: usage["accountEmail"] as? String ?? identity["accountEmail"] as? String,
                             planName: usage["planName"] as? String ?? usage["plan"] as? String,
                             codexResetCredits: resetCredits)
    }

    public static func cost(_ data: Data) throws -> [DailyCost] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let object = rows.first,
              let days = object["daily"] as? [[String: Any]] else { throw QuotaParseError.invalidRoot }
        return days.compactMap { day in
            guard let date = day["date"] as? String, let cost = number(day["totalCost"]) else { return nil }
            return DailyCost(date: date, totalCost: cost, totalTokens: day["totalTokens"] as? Int,
                models: (day["modelBreakdowns"] as? [[String: Any]] ?? []).compactMap { model in
                    guard let name = model["modelName"] as? String, let tokens = model["totalTokens"] as? Int else { return nil }
                    return CostModel(name: name, tokens: tokens)
                })
        }
    }

    public static func sessions(_ data: Data) throws -> [SessionActivity] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw QuotaParseError.invalidRoot
        }
        return rows.compactMap { row in
            guard let name = row["provider"] as? String, let provider = QuotaProvider(rawValue: name.lowercased()),
                  let state = row["state"] as? String else { return nil }
            return SessionActivity(provider: provider, active: state == "active")
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }
}
