import Foundation

/// 单个渠道的解析结果。只做数据转换，不读写文件。
public struct CodexBarProviderImport {
    public var rows: [QuotaHistoryLine] = []
    /// 来源里有、但不属于首选账号的曲线条数。
    public var skippedAccountSeries = 0
    /// 字段缺失、日期无法解析或百分比越界的条目。
    public var badEntries = 0
    /// 与 MeowMac 已有数据重叠（不早于最早采样时间）的条目。
    public var overlapEntries = 0
    /// 早于保留期的条目。
    public var expiredEntries = 0
    /// 同一窗口同一时间重复的条目。
    public var duplicateEntries = 0
}

public enum CodexBarImportError: Error, Equatable {
    case unreadable
    case unsupportedVersion(Int)
}

public enum CodexBarHistoryImporter {
    public static let supportedVersion = 1

    private struct Source: Decodable {
        let version: Int
        let preferredAccountKey: String?
        let accounts: [String: [Series]]?
        let unscoped: [Series]?
    }
    private struct Series: Decodable {
        let name: String?
        let windowMinutes: Int?
        let entries: [Entry]?
    }
    private struct Entry: Decodable {
        let capturedAt: String?
        let resetsAt: String?
        let usedPercent: Double?
    }

    /// - Parameters:
    ///   - existing: MeowMac 该渠道已有的行，用来确定缺口的右边界。
    ///   - notBefore: 保留期起点，更早的条目不导入。
    public static func parse(_ data: Data, provider: QuotaProvider, existing: [QuotaHistoryLine],
                             notBefore: Date) throws -> CodexBarProviderImport {
        let source: Source
        do { source = try JSONDecoder().decode(Source.self, from: data) }
        catch { throw CodexBarImportError.unreadable }
        guard source.version == supportedVersion else { throw CodexBarImportError.unsupportedVersion(source.version) }

        var result = CodexBarProviderImport()
        var series: [Series] = source.unscoped ?? []
        let accounts = source.accounts ?? [:]
        if let key = source.preferredAccountKey, let preferred = accounts[key] { series += preferred }
        let usedKeys: Set<String> = source.preferredAccountKey.map { accounts[$0] != nil ? [$0] : [] } ?? []
        result.skippedAccountSeries = accounts.filter { !usedKeys.contains($0.key) }.values.reduce(0) { $0 + $1.count }

        let cutoff = existing.map(\.sampledAt).min()
        var seen = Set<String>()
        for item in series {
            let minutes = item.windowMinutes ?? (item.name == "session" ? 300 : item.name == "weekly" ? 10080 : nil)
            for entry in item.entries ?? [] {
                guard let minutes, minutes > 0,
                      let capturedText = entry.capturedAt, let captured = parseDate(capturedText),
                      let percent = entry.usedPercent, (0...100).contains(percent) else { result.badEntries += 1; continue }
                let reset: Date?
                if let text = entry.resetsAt {
                    guard let parsed = parseDate(text) else { result.badEntries += 1; continue }
                    reset = parsed
                } else { reset = nil }
                if let cutoff, captured >= cutoff { result.overlapEntries += 1; continue }
                if captured < notBefore { result.expiredEntries += 1; continue }
                guard seen.insert("\(minutes)|\(captured.timeIntervalSince1970)").inserted else { result.duplicateEntries += 1; continue }
                result.rows.append(QuotaHistoryLine(sampledAt: captured, provider: provider, windowMinutes: minutes,
                                                    usedPercent: percent, resetsAt: reset))
            }
        }
        result.rows.sort { $0.sampledAt == $1.sampledAt ? ($0.windowMinutes ?? 0) < ($1.windowMinutes ?? 0) : $0.sampledAt < $1.sampledAt }
        return result
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

public struct CodexBarImportReport: Equatable {
    public enum Outcome: Equatable { case imported, alreadyImported, sourceMissing }
    public var outcome: Outcome
    public var imported: [QuotaProvider: Int] = [:]
    public var skippedAccountSeries = 0
    public var badEntries = 0
    public var unsupported: [QuotaProvider] = []
    public init(outcome: Outcome) { self.outcome = outcome }
    public var totalImported: Int { imported.values.reduce(0, +) }

    /// 导入完成后给用户看的原生提示。
    public var message: String {
        switch outcome {
        case .alreadyImported: return "已导入过 CodexBar 历史，没有再次写入。"
        case .sourceMissing: return "没有找到 CodexBar 的额度历史文件，未导入。"
        case .imported:
            var lines: [String] = []
            for provider in QuotaProvider.allCases {
                guard let count = imported[provider] else { continue }
                lines.append("\(provider.displayName)：\(count) 条")
            }
            var text = totalImported == 0 ? "没有需要补充的历史记录。" : "已补充 \(totalImported) 条历史记录。"
            text += "\n" + lines.joined(separator: "\n")
            if skippedAccountSeries > 0 { text += "\n跳过其他账号的 \(skippedAccountSeries) 条曲线。" }
            if badEntries > 0 { text += "\n忽略 \(badEntries) 条无法识别的记录。" }
            if !unsupported.isEmpty { text += "\n不支持的文件版本：" + unsupported.map(\.displayName).joined(separator: "、") }
            return text
        }
    }
}

public enum CodexBarImportFailure: Error, Equatable {
    case unsafePath(String)
    case writeFailed(String)
}

/// 一次性导入：读取来源目录，把缺口补进 MeowMac 的额度历史，写标记文件。
public struct CodexBarHistoryImport {
    public static let defaultSource = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.steipete.codexbar/history", isDirectory: true)

    public let source: URL
    public let store: QuotaHistoryStore
    public let marker: URL
    public let write: (Data, URL) throws -> Void

    public init(source: URL = CodexBarHistoryImport.defaultSource, store: QuotaHistoryStore = QuotaHistoryStore(),
                marker: URL? = nil, write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.source = source; self.store = store; self.write = write
        self.marker = marker ?? store.directory.deletingLastPathComponent().appendingPathComponent("codexbar-import.json")
    }

    private struct Marker: Codable {
        let version: Int
        let importedAt: Date
        let counts: [String: Int]
    }

    public func run(now: Date, retentionDays: Int) throws -> CodexBarImportReport {
        let fm = FileManager.default
        if fm.fileExists(atPath: marker.path) || isSymlink(marker) {
            try rejectSymlink(marker)
            return CodexBarImportReport(outcome: .alreadyImported)
        }
        let notBefore = now.addingTimeInterval(Double(-retentionDays) * 86400)
        var report = CodexBarImportReport(outcome: .sourceMissing)
        var plans: [(provider: QuotaProvider, rows: [QuotaHistoryLine])] = []
        for provider in QuotaProvider.allCases {
            let file = source.appendingPathComponent("\(provider.rawValue).json")
            guard let data = try? Data(contentsOf: file) else { continue }
            report.outcome = .imported
            do {
                let parsed = try CodexBarHistoryImporter.parse(data, provider: provider, existing: store.read(provider), notBefore: notBefore)
                report.skippedAccountSeries += parsed.skippedAccountSeries
                report.badEntries += parsed.badEntries
                if !parsed.rows.isEmpty { plans.append((provider, parsed.rows)) }
                report.imported[provider] = parsed.rows.count
            } catch is CodexBarImportError { report.unsupported.append(provider) }
        }
        guard report.outcome == .imported else { return report }

        try rejectSymlink(store.directory); try rejectSymlink(store.directory.deletingLastPathComponent())
        var originals: [(url: URL, data: Data?)] = []
        func rollback() {
            for item in originals.reversed() {
                if let data = item.data { try? data.write(to: item.url, options: .atomic) } else { try? fm.removeItem(at: item.url) }
            }
        }
        do {
            try fm.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            for plan in plans {
                let file = store.directory.appendingPathComponent("\(plan.provider.rawValue).jsonl")
                try rejectSymlink(file)
                let original = fm.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
                // 导入的行都早于已有数据，直接放在原字节前面，已有行（含坏行）原样保留。
                var merged = Data()
                for row in plan.rows { merged.append(try encoder.encode(row)); merged.append(0x0A) }
                merged.append(original ?? Data())
                originals.append((file, original))
                try write(merged, file)
            }
            // 有文件版本不支持或无法读取时不写标记，让用户修复后可以再点一次。
            if report.unsupported.isEmpty {
                let markerEncoder = JSONEncoder()
                markerEncoder.dateEncodingStrategy = .iso8601; markerEncoder.outputFormatting = [.sortedKeys]
                let markerData = try markerEncoder.encode(Marker(version: 1, importedAt: now,
                    counts: Dictionary(uniqueKeysWithValues: report.imported.map { ($0.key.rawValue, $0.value) })))
                originals.append((marker, nil))
                try write(markerData, marker)
            }
        } catch let failure as CodexBarImportFailure {
            rollback(); throw failure
        } catch {
            rollback(); throw CodexBarImportFailure.writeFailed(error.localizedDescription)
        }
        return report
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func rejectSymlink(_ url: URL) throws {
        if isSymlink(url) { throw CodexBarImportFailure.unsafePath(url.lastPathComponent) }
    }
}
