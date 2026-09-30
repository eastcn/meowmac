import Foundation

public struct CleaningRecord: Codable {
    public let startedAt: Date
    public let sizeDescription: String
    public init(startedAt: Date, sizeDescription: String) {
        self.startedAt = startedAt; self.sizeDescription = sizeDescription
    }
}

public enum MoHistoryError: Error { case invalidRoot }

public enum MoHistoryParser {
    public static func latest(_ data: Data, timeZone: TimeZone = .current) throws -> CleaningRecord? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = object["sessions"] as? [[String: Any]] else { throw MoHistoryError.invalidRoot }
        let records = sessions.compactMap { session -> CleaningRecord? in
            guard let command = session["command"] as? String, command.contains("clean"),
                  let dateString = session["started_at"] as? String,
                  let date = startedAt(dateString, timeZone: timeZone) else { return nil }
            let size: String
            if let number = session["size"] as? NSNumber {
                size = ByteCountFormatter.string(fromByteCount: number.int64Value, countStyle: .file)
            } else { size = session["size"] as? String ?? "未知" }
            return CleaningRecord(startedAt: date, sizeDescription: size)
        }
        return records.max { $0.startedAt < $1.startedAt }
    }

    private static func startedAt(_ value: String, timeZone: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: value) { return date }
        guard value.count == 19 else { return nil }
        // Mole 的本地时间没有时区，按运行机器的时区解释。
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        local.isLenient = false
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            local.dateFormat = pattern
            if let date = local.date(from: value) { return date }
        }
        return nil
    }
}
