import Foundation

public struct QuotaHistoryLine: Codable {
    public let sampledAt: Date
    public let provider: QuotaProvider
    public let windowMinutes: Int?
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(sampledAt: Date, provider: QuotaProvider, windowMinutes: Int?, usedPercent: Double, resetsAt: Date?) {
        self.sampledAt = sampledAt; self.provider = provider; self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
}

public struct QuotaHistoryStore {
    public let directory: URL

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MeowMac/history/quota", isDirectory: true)) {
        self.directory = directory
    }

    public func append(_ snapshot: QuotaSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(snapshot.provider.rawValue).jsonl")
        let handle: FileHandle
        if FileManager.default.fileExists(atPath: file.path) {
            handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: file.path, contents: nil)
            handle = try FileHandle(forWritingTo: file)
        }
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for window in snapshot.windows {
            let line = QuotaHistoryLine(sampledAt: snapshot.updatedAt, provider: snapshot.provider,
                                        windowMinutes: window.windowMinutes, usedPercent: window.usedPercent,
                                        resetsAt: window.resetsAt)
            var data = try encoder.encode(line)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        }
    }

    public func read(_ provider: QuotaProvider) throws -> [QuotaHistoryLine] {
        let file = directory.appendingPathComponent("\(provider.rawValue).jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let text = try String(contentsOf: file, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try text.split(separator: "\n").map { try decoder.decode(QuotaHistoryLine.self, from: Data($0.utf8)) }
    }

    public func prune(before cutoff: Date) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for provider in QuotaProvider.allCases {
            let file = directory.appendingPathComponent("\(provider.rawValue).jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let kept = try read(provider).filter { $0.sampledAt >= cutoff }
            let lines = try kept.map { try encoder.encode($0) + Data([0x0A]) }
            try lines.reduce(Data(), +).write(to: file, options: .atomic)
        }
    }
}
