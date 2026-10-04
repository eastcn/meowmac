import Foundation
import MeowMacCore
import MeowMacSystem
import MeowMacQuota
import os

private final class RawCapture: @unchecked Sendable {
    let directory: URL?
    private let lock = NSLock()
    private var failures: [Error] = []
    init(_ directory: URL?) throws {
        self.directory = directory
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }
    func write(_ data: Data, name: String) {
        guard let directory else { return }
        do { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
        catch { lock.lock(); failures.append(error); lock.unlock() }
    }
    func verify() throws { lock.lock(); defer { lock.unlock() }; if let error = failures.first { throw error } }
}
public enum SnapshotCollector {
    @MainActor public static func collect(rawDirectory: URL? = nil) async throws -> PanelState {
        let raw = try RawCapture(rawDirectory)
        let state = PanelState()
        CatRuntime.initialize(state: state, store: CatStore())
        let config = state.configResult.config
        let client = CodexBarClient(path: config.codexBarCLIPath) { args, output, errors in
            let provider = args.indices.contains(2) ? args[2] : "all"
            let name = "codexbar-\(args[0])-\(provider)"
            raw.write(output, name: name + ".json"); raw.write(errors, name: name + ".stderr.txt")
        }
        let logger = Logger(subsystem: AppIdentity.bundleID, category: "snapshot")
        let system = SystemCollector()
        let initial = system.sample(); state.chartHistory.append(initial)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let latest = system.sample(); state.snapshot = latest; state.chartHistory.append(latest, force: true)
        state.lastRefreshedAt = latest.timestamp
        if latest.thermal == .fair { state.fairSince = latest.timestamp }
        state.fanHighSince = FanHighTracker.next(since: nil, readings: latest.sensors, at: latest.timestamp, config: config)
        let energy = try await Task.detached {
            let processes = try EnergySampler.processes { raw.write($0, name: "top.txt") }
            var tracker = EnergyTracker()
            return tracker.evaluate(processes: processes, pressure: latest.memoryPressure, now: Date(), config: config)
        }.value
        state.energyUpdatedAt = Date()
        state.energy = energy
        for provider in QuotaProvider.allCases {
            do {
                state.quotas[provider] = try await Task.detached { try client.usage(provider) }.value
                state.quotaHistory[provider] = try QuotaHistoryStore().read(provider)
            } catch {
                state.quotaErrors[provider] = error.localizedDescription
                state.failures["quota.\(provider.rawValue)"] = config.sourceFailureCount
                logger.error("快照额度采集失败：\(provider.rawValue, privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
        for provider in [QuotaProvider.codex, .claude] {
            do { state.costs[provider] = try await Task.detached { try client.cost(provider) }.value }
            catch { logger.error("快照花费采集失败：\(provider.rawValue, privacy: .public) \(error.localizedDescription, privacy: .private)") }
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".\(provider.rawValue)")
            do { state.localStorage[provider] = try await Task.detached { try LocalStorageCollector.scan(directory: url, provider: provider) }.value }
            catch { logger.error("快照存储统计失败：\(error.localizedDescription, privacy: .private)") }
        }
        do { state.lastCleaning = try MoHistoryReader.latest(executable: config.moPath) }
        catch { logger.error("快照清理历史失败：\(error.localizedDescription, privacy: .private)") }
        let networkHistoryDirectory = rawDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/acceptance", isDirectory: true)
        try FileManager.default.createDirectory(at: networkHistoryDirectory, withIntermediateDirectories: true)
        let networkHistory = networkHistoryDirectory.appendingPathComponent("snapshot-egress-\(UUID().uuidString).json")
        let applicationHistory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MeowMac/tuncanary/egress-history.json")
        if FileManager.default.fileExists(atPath: applicationHistory.path) {
            try FileManager.default.copyItem(at: applicationHistory, to: networkHistory)
        }
        // 快照从应用历史副本采集，新的出口记录只写入验收目录。
        let network = try await NetworkBridge.collectOnce(historyFile: networkHistory)
        state.networkModel = network.model; state.networkTone = network.model.meowMacDisplay.tone
        state.networkCapture = network.capture
        raw.write(Data(network.raw.utf8), name: "tuncanary.json")
        if rawDirectory != nil {
            try await Task.detached {
                for args in [["-g", "assertions"], ["-g", "therm"]] {
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); process.arguments = args
                    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = Pipe(); try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
                    raw.write(data, name: "pmset-\(args[1]).txt")
                }
            }.value
        }
        try raw.verify()
        let completedAt = Date(); state.now = { completedAt }
        let last = UserDefaults.standard.string(forKey: "lastPanelTab").flatMap(PanelTab.init(rawValue:)) ?? .system
        state.selectedTab = last
        return state
    }
}
