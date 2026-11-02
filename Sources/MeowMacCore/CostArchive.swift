import Foundation
import os

/// 每日花费存档。CodexBar 只扫描现存的会话日志，会话被清理或归档后，那几天会从结果里消失；
/// 这里把读到过的每日汇总留下来，只增不减。
public enum CostArchive {
    public static let retentionDays = 90

    /// 同一天取花费较大的一份：会话被删后 CodexBar 给出的值只会变小。存档里有而新数据没有的天原样保留。
    public static func merge(archived: [DailyCost], fresh: [DailyCost], today: Date, calendar: Calendar = .current) -> [DailyCost] {
        var byDate: [String: DailyCost] = [:]
        for day in archived { byDate[day.date] = day }
        for day in fresh {
            if let old = byDate[day.date], old.totalCost > day.totalCost { continue }
            byDate[day.date] = day
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let start = calendar.date(byAdding: .day, value: -retentionDays, to: today) ?? today
        let cutoff = formatter.string(from: start)
        return byDate.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }
}

public struct CostArchiveStore {
    public let directory: URL
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "cost-archive")

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MeowMac/history/cost", isDirectory: true)) {
        self.directory = directory
    }

    public func load(_ provider: QuotaProvider) -> [DailyCost] {
        guard let data = try? Data(contentsOf: file(provider)) else { return [] }
        return (try? JSONDecoder().decode([DailyCost].self, from: data)) ?? []
    }

    /// 合并存档并写回，返回合并后的结果。写失败只记日志，仍返回合并结果。
    public func merged(_ provider: QuotaProvider, fresh: [DailyCost], today: Date = Date()) -> [DailyCost] {
        let result = CostArchive.merge(archived: load(provider), fresh: fresh, today: today)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(result).write(to: file(provider), options: .atomic)
        } catch {
            Self.logger.error("花费存档写入失败：\(provider.rawValue, privacy: .public)")
        }
        return result
    }

    private func file(_ provider: QuotaProvider) -> URL { directory.appendingPathComponent("\(provider.rawValue).json") }
}
