import Foundation

public enum QuotaProvider: String, CaseIterable, Codable {
    case deepseek, codex, claude, opencodego
}

public struct QuotaWindow: Codable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    public let resetDescription: String?

    public init(usedPercent: Double, windowMinutes: Int?, resetsAt: Date?, resetDescription: String?) {
        self.usedPercent = usedPercent; self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt; self.resetDescription = resetDescription
    }
}

public struct QuotaSnapshot {
    public let provider: QuotaProvider
    public let source: String
    public let updatedAt: Date
    public let windows: [QuotaWindow]
    public let paceSummary: String?
    public let credits: Double?

    public init(provider: QuotaProvider, source: String, updatedAt: Date, windows: [QuotaWindow], paceSummary: String?, credits: Double?) {
        self.provider = provider; self.source = source; self.updatedAt = updatedAt
        self.windows = windows; self.paceSummary = paceSummary; self.credits = credits
    }
}

public struct DailyCost {
    public let date: String
    public let totalCost: Double
    public init(date: String, totalCost: Double) { self.date = date; self.totalCost = totalCost }
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
                return QuotaWindow(usedPercent: used, windowMinutes: window["windowMinutes"] as? Int,
                    resetsAt: (window["resetAt"] as? String).flatMap(parseDate),
                    resetDescription: window["label"] as? String)
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
                               resetsAt: date, resetDescription: item["resetDescription"] as? String)
        }
        guard !windows.isEmpty else { throw QuotaParseError.missingWindow }
        let pace = (usage["pace"] as? [String: Any])?["summary"] as? String
        let creditsObject = usage["credits"] as? [String: Any]
        let credits = number(creditsObject?["balance"] ?? usage["credits"])
        return QuotaSnapshot(provider: provider, source: row["source"] as? String ?? "未知", updatedAt: now,
                             windows: windows, paceSummary: pace, credits: credits)
    }

    public static func cost(_ data: Data) throws -> [DailyCost] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let object = rows.first,
              let days = object["daily"] as? [[String: Any]] else { throw QuotaParseError.invalidRoot }
        return days.compactMap { day in
            guard let date = day["date"] as? String, let cost = number(day["totalCost"]) else { return nil }
            return DailyCost(date: date, totalCost: cost)
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
        ISO8601DateFormatter().date(from: string)
    }
}
