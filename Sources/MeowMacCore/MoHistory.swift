import Foundation

public struct CleaningRecord {
    public let startedAt: Date
    public let sizeDescription: String
    public init(startedAt: Date, sizeDescription: String) {
        self.startedAt = startedAt; self.sizeDescription = sizeDescription
    }
}

public enum MoHistoryError: Error { case invalidRoot }

public enum MoHistoryParser {
    public static func latest(_ data: Data) throws -> CleaningRecord? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = object["sessions"] as? [[String: Any]] else { throw MoHistoryError.invalidRoot }
        let records = sessions.compactMap { session -> CleaningRecord? in
            guard let command = session["command"] as? String, command.contains("clean"),
                  let dateString = session["started_at"] as? String,
                  let date = ISO8601DateFormatter().date(from: dateString) else { return nil }
            let size: String
            if let number = session["size"] as? NSNumber {
                size = ByteCountFormatter.string(fromByteCount: number.int64Value, countStyle: .file)
            } else { size = session["size"] as? String ?? "未知" }
            return CleaningRecord(startedAt: date, sizeDescription: size)
        }
        return records.max { $0.startedAt < $1.startedAt }
    }
}
