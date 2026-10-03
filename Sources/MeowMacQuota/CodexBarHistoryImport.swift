import Foundation
import MeowMacCore

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
