import Foundation
import MeowMacCore
import os

public struct NotificationStoreLoad {
    public let settings: NotificationSettings
    public let records: [String: NotifiedRecord]
    /// 坏文件已挪开时的说明；正常为 nil。
    public let recoveryReason: String?
}

/// 通知开关和已通知记录，存在 `notifications.json`。本机设置，不进猫包（D41）。
@MainActor
public final class NotificationStore {
    public static let filename = "notifications.json"
    static let maxBytes = 262_144
    public let rootURL: URL
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "notifications")
    public init(rootURL: URL = CatStore.defaultRoot) { self.rootURL = rootURL }
    public var fileURL: URL { rootURL.appendingPathComponent(Self.filename) }

    private struct Envelope: Codable {
        var schemaVersion = 1
        var settings: NotificationSettings
        var records: [NotifiedRecord]
    }

    public func load() -> NotificationStoreLoad {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return NotificationStoreLoad(settings: NotificationSettings(), records: [:], recoveryReason: nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maxBytes else { throw CocoaError(.fileReadTooLarge) }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.schemaVersion == 1 else { throw CocoaError(.fileReadCorruptFile) }
            let settings = envelope.settings
            let records = Dictionary(envelope.records.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            return NotificationStoreLoad(settings: settings, records: records, recoveryReason: nil)
        } catch {
            // 坏文件改名保留，之后按默认开关和空记录继续，不覆盖原文件。
            let aside = rootURL.appendingPathComponent(Self.filename + ".bad-\(Int(Date().timeIntervalSince1970))")
            let moved = (try? FileManager.default.moveItem(at: fileURL, to: aside)) != nil
            let reason = "通知记录无法读取，已" + (moved ? "改名为 \(aside.lastPathComponent)" : "保留原文件") + "，按默认设置继续"
            logger.error("\(reason, privacy: .public)：\(error.localizedDescription, privacy: .private)")
            return NotificationStoreLoad(settings: NotificationSettings(), records: [:], recoveryReason: reason)
        }
    }

    public func save(settings: NotificationSettings, records: [String: NotifiedRecord]) throws {
        let envelope = Envelope(settings: settings,
                                records: records.values.sorted { $0.key < $1.key })
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
