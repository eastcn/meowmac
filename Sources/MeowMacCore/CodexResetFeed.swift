import Foundation

public enum CodexResetError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}

/// 公开重置消息独立于账号的额度窗口与重置卡余额。
public struct CodexResetFeed: Decodable {
    public let schemaVersion: Int
    public let checkedAt: Date?
    public let events: [CodexResetEvent]
    public let monitor: Monitor?
    public struct Monitor: Decodable {
        public let status: String
        public let lastCollectedAt: Date?
        public let lastVerifiedAt: Date?
    }
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 262_144 else { throw CodexResetError.invalid("重置消息超过 256 KiB") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ResetDate.parse(text) else { throw CodexResetError.invalid("重置消息时间无效") }
            return date
        }
        let feed = try decoder.decode(Self.self, from: data)
        guard feed.schemaVersion == 1, feed.events.count <= 128,
              Set(feed.events.map(\.id)).count == feed.events.count else {
            throw CodexResetError.invalid("重置消息版本、数量或身份无效")
        }
        for event in feed.events {
            guard !event.id.isEmpty, event.id.utf8.count <= 160,
                  event.title.utf8.count <= 4096, (event.displayLabel?.utf8.count ?? 0) <= 4096 else {
                throw CodexResetError.invalid("重置消息字段无效")
            }
            for range in [event.schedule, event.estimate].compactMap({ $0 }) where range.from > range.through {
                throw CodexResetError.invalid("重置消息时间范围倒置")
            }
            if let day = event.occurredOn, ResetDate.day(day) == nil {
                throw CodexResetError.invalid("重置消息日期无效")
            }
        }
        return feed
    }
}

public struct CodexResetEvent: Decodable {
    public let id: String
    public let type: String
    public let status: String
    public let title: String
    public let displayLabel: String?
    public let scope: String?
    public let updatedAt: Date
    public let confirmedAt: Date?
    public let occurredOn: String?
    public let presentation: Presentation?
    public let schedule: TimeRange?
    public let estimate: TimeRange?
    public struct Presentation: Decodable {
        public let status: String
        public let scopeKnown: Bool
        public let scopeLabel: String?
        public let audienceZh: String?
        public let productsZh: String?
        public let kindExplicit: Bool
        public let timeInferred: Bool
    }
    public struct TimeRange: Decodable {
        public let from: Date
        public let through: Date
        public let label: String
        public let precision: String?
    }
    public var isConfirmed: Bool { status == "confirmed" }
    public var confirmationDate: Date? { confirmedAt ?? occurredOn.flatMap(ResetDate.day) }
}

public enum ResetDate {
    public static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) { return value }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
    public static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let value = formatter.date(from: text), formatter.string(from: value) == text else { return nil }
        return value
    }
    public static func text(_ date: Date, timezone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timezone
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}

public struct CodexResetRow: Codable, Identifiable {
    public let id: String
    public let label: String
    public let status: String
    public let scope: String
    public let announcement: String?
    public let estimate: String?
    public let confirmation: String?
    public let previewTime: String
    public var preview: String { previewTime + " · " + label }
}
public struct CodexResetDisplay: Codable {
    public let headline: String
    public let pending: [CodexResetRow]
    public let latest: CodexResetRow?
    public let fetchedAt: Date?
    public let verifiedAt: Date?
    public let siteStatus: String?
    public let error: String?
    public let cacheError: String?
    public static let sourceURL = URL(string: "https://aihot.news/codex-reset")!

    public init(feed: CodexResetFeed?, fetchedAt: Date?, error: String?, cacheError: String? = nil,
                timezone: TimeZone = .current) {
        self.fetchedAt = fetchedAt; self.error = error; self.cacheError = cacheError
        verifiedAt = feed?.monitor?.lastVerifiedAt ?? feed?.checkedAt
        siteStatus = feed?.monitor.map {
            switch $0.status {
            case "healthy": return "站点采集正常"
            case "delayed": return "站点采集有延迟"
            case "attention": return "站点采集待核验"
            default: return "站点采集状态未知"
            }
        }
        func row(_ event: CodexResetEvent) -> CodexResetRow {
            let phase = event.isConfirmed ? "confirmed" : event.presentation?.status ?? event.status
            let statuses = ["announced": "有重置预告 · 尚未确认", "in_progress": "正在发放 · 尚未确认完成",
                            "confirmed": "已确认", "expired_unconfirmed": "预计窗口已过 · 尚未确认",
                            "likely_completed": "站点推测已落地 · 尚未确认"]
            // 只有事件本身确认才展示确认状态，未知状态保留原值。
            let status = !event.isConfirmed && phase == "confirmed" ? "尚未确认" : statuses[phase] ?? "状态未知（\(phase)）"
            let qualified = event.presentation?.scopeKnown == true
                ? event.presentation?.audienceZh ?? event.presentation?.scopeLabel : nil
            let audience = qualified?.isEmpty == false ? qualified! : "适用范围未说明"
            let scope = [event.presentation?.productsZh, audience].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            func range(_ value: CodexResetEvent.TimeRange) -> String {
                if value.precision == "date" { return value.label }
                return ResetDate.text(value.from, timezone: timezone) + "～" + ResetDate.text(value.through, timezone: timezone)
            }
            func previewRange(_ value: CodexResetEvent.TimeRange) -> String {
                if value.precision == "date" { return value.label }
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
                formatter.timeZone = timezone; formatter.dateFormat = "HH:mm"
                let end = calendar.isDate(value.from, inSameDayAs: value.through)
                    ? formatter.string(from: value.through) : ResetDate.text(value.through, timezone: timezone)
                return ResetDate.text(value.from, timezone: timezone) + "～" + end
            }
            let label = event.presentation?.kindExplicit == false ? "额外重置（形式未说明）"
                : event.displayLabel ?? "额外重置消息"
            let confirmation = event.confirmedAt.map { "确认消息：" + ResetDate.text($0, timezone: timezone) }
                ?? event.occurredOn.map { "发生日期：" + $0 + "（北京时间）" }
            return CodexResetRow(id: event.id, label: label, status: status, scope: scope,
                announcement: event.schedule.map { "公告时间：" + range($0) + (event.presentation?.timeInferred == true ? "（时间为推断）" : "") },
                estimate: event.isConfirmed ? nil : event.estimate.map { "AIHOT 估算：" + range($0) + "（非官方承诺）" },
                confirmation: event.isConfirmed ? confirmation ?? "确认时间未说明" : nil,
                previewTime: event.estimate.map { "估算 " + previewRange($0) } ?? "时间待估算")
        }
        pending = (feed?.events ?? []).filter { !$0.isConfirmed }.sorted { $0.updatedAt > $1.updatedAt }.map(row)
        latest = (feed?.events ?? []).filter(\.isConfirmed).sorted {
            ($0.confirmationDate ?? $0.updatedAt) > ($1.confirmationDate ?? $1.updatedAt)
        }.first.map(row)
        headline = error != nil ? (feed == nil ? "采集失败 · 暂无缓存" : "采集失败 · 保留上次结果")
            : feed == nil ? "等待首次采集" : pending.isEmpty ? "暂无重置预告" : "有 \(pending.count) 条待确认消息"
    }
}
