import Foundation

public struct LocalConfig: Codable, Equatable {
    public var schemaVersion = 1
    public var quotaRemainingWarn = 0.20
    public var diskRemainingWarn = 0.10
    public var runawayCPU = 90.0
    public var runawaySeconds = 600.0
    public var sleepAssertionSeconds = 7200.0
    public var memoryPressureSeconds = 600.0
    public var fairThermalSeconds = 300.0
    public var fanHighFraction = 0.8
    public var fanHighSeconds = 300.0
    public var sourceFailureCount = 2
    public var memoryNormalLoad = 0.0
    public var memoryWarnLoad = 0.6
    public var memoryCriticalLoad = 0.9
    public var idleFrameSeconds = 0.5
    public var fullFrameSeconds = 0.05
    public var quotaRefreshSeconds = 1800.0
    public var sessionPollSeconds = 60.0
    public var sessionFinishDelaySeconds = 300.0
    public var manualMergeSeconds = 60.0
    public var costRefreshSeconds = 1800.0
    public var processSampleSeconds = 60.0
    public var quotaHistoryDays = 90
    public var codexBarCLIPath = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"
    public var moPath = "/opt/homebrew/bin/mo"

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, quotaRemainingWarn, diskRemainingWarn, runawayCPU, runawaySeconds
        case sleepAssertionSeconds, memoryPressureSeconds, fairThermalSeconds, fanHighFraction, fanHighSeconds, sourceFailureCount
        case memoryNormalLoad, memoryWarnLoad, memoryCriticalLoad, idleFrameSeconds, fullFrameSeconds
        case quotaRefreshSeconds, sessionPollSeconds, sessionFinishDelaySeconds, manualMergeSeconds
        case costRefreshSeconds, processSampleSeconds, quotaHistoryDays, codexBarCLIPath, moPath
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LocalConfig()
        schemaVersion = try fields.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? defaults.schemaVersion
        quotaRemainingWarn = try fields.decodeIfPresent(Double.self, forKey: .quotaRemainingWarn) ?? defaults.quotaRemainingWarn
        diskRemainingWarn = try fields.decodeIfPresent(Double.self, forKey: .diskRemainingWarn) ?? defaults.diskRemainingWarn
        runawayCPU = try fields.decodeIfPresent(Double.self, forKey: .runawayCPU) ?? defaults.runawayCPU
        runawaySeconds = try fields.decodeIfPresent(Double.self, forKey: .runawaySeconds) ?? defaults.runawaySeconds
        sleepAssertionSeconds = try fields.decodeIfPresent(Double.self, forKey: .sleepAssertionSeconds) ?? defaults.sleepAssertionSeconds
        memoryPressureSeconds = try fields.decodeIfPresent(Double.self, forKey: .memoryPressureSeconds) ?? defaults.memoryPressureSeconds
        fairThermalSeconds = try fields.decodeIfPresent(Double.self, forKey: .fairThermalSeconds) ?? defaults.fairThermalSeconds
        fanHighFraction = try fields.decodeIfPresent(Double.self, forKey: .fanHighFraction) ?? defaults.fanHighFraction
        fanHighSeconds = try fields.decodeIfPresent(Double.self, forKey: .fanHighSeconds) ?? defaults.fanHighSeconds
        sourceFailureCount = try fields.decodeIfPresent(Int.self, forKey: .sourceFailureCount) ?? defaults.sourceFailureCount
        memoryNormalLoad = try fields.decodeIfPresent(Double.self, forKey: .memoryNormalLoad) ?? defaults.memoryNormalLoad
        memoryWarnLoad = try fields.decodeIfPresent(Double.self, forKey: .memoryWarnLoad) ?? defaults.memoryWarnLoad
        memoryCriticalLoad = try fields.decodeIfPresent(Double.self, forKey: .memoryCriticalLoad) ?? defaults.memoryCriticalLoad
        idleFrameSeconds = try fields.decodeIfPresent(Double.self, forKey: .idleFrameSeconds) ?? defaults.idleFrameSeconds
        fullFrameSeconds = try fields.decodeIfPresent(Double.self, forKey: .fullFrameSeconds) ?? defaults.fullFrameSeconds
        quotaRefreshSeconds = try fields.decodeIfPresent(Double.self, forKey: .quotaRefreshSeconds) ?? defaults.quotaRefreshSeconds
        sessionPollSeconds = try fields.decodeIfPresent(Double.self, forKey: .sessionPollSeconds) ?? defaults.sessionPollSeconds
        sessionFinishDelaySeconds = try fields.decodeIfPresent(Double.self, forKey: .sessionFinishDelaySeconds) ?? defaults.sessionFinishDelaySeconds
        manualMergeSeconds = try fields.decodeIfPresent(Double.self, forKey: .manualMergeSeconds) ?? defaults.manualMergeSeconds
        costRefreshSeconds = try fields.decodeIfPresent(Double.self, forKey: .costRefreshSeconds) ?? defaults.costRefreshSeconds
        processSampleSeconds = try fields.decodeIfPresent(Double.self, forKey: .processSampleSeconds) ?? defaults.processSampleSeconds
        quotaHistoryDays = try fields.decodeIfPresent(Int.self, forKey: .quotaHistoryDays) ?? defaults.quotaHistoryDays
        codexBarCLIPath = try fields.decodeIfPresent(String.self, forKey: .codexBarCLIPath) ?? defaults.codexBarCLIPath
        moPath = try fields.decodeIfPresent(String.self, forKey: .moPath) ?? defaults.moPath
    }
}

public struct ConfigLoadResult {
    public let config: LocalConfig
    public let error: String?

    public init(config: LocalConfig, error: String?) {
        self.config = config
        self.error = error
    }
}

public enum ConfigStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeowMac/config.json")
    }

    public static func load(from url: URL = defaultURL) -> ConfigLoadResult {
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(LocalConfig.self, from: data)
            guard config.schemaVersion == 1 else {
                return ConfigLoadResult(config: LocalConfig(), error: "配置文件无效：不支持的 schemaVersion \(config.schemaVersion)")
            }
            return ConfigLoadResult(config: config, error: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ConfigLoadResult(config: LocalConfig(), error: nil)
        } catch {
            return ConfigLoadResult(config: LocalConfig(), error: "配置文件无效：\(error.localizedDescription)")
        }
    }
}
