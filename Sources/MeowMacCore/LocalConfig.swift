import Foundation

public struct LocalConfig: Codable, Equatable {
    public var schemaVersion = 1
    public var alertRules = AlertRuleSet()
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
    public var proxyTrafficEnabled = true
    public var proxyTrafficExportDirectory = ""
    public var quotaHistoryDays = 90
    public var codexBarCLIPath = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"
    public var cleanTerminal = CleanTerminal.automatic
    public var aiAgent = AIAgent.automatic
    public var aiDiagnosisEntry = true
    public var moPath = "/opt/homebrew/bin/mo"
    /// 桌面猫（D45）。本机配置，不进猫包。
    public var desktopCat = DesktopCatConfig()
    /// 菜单栏的形象，缺省与桌面猫相同。本机配置，不进猫包。
    public var menuBarPet = MenuBarPetConfig.desktop
    /// 读取 `menuBarPet` 时的回退原因，不写回文件。
    public var menuBarPetDiagnostics: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case alertRules, schemaVersion, quotaRemainingWarn, diskRemainingWarn, runawayCPU, runawaySeconds
        case sleepAssertionSeconds, memoryPressureSeconds, fairThermalSeconds, fanHighFraction, fanHighSeconds, sourceFailureCount
        case memoryNormalLoad, memoryWarnLoad, memoryCriticalLoad, idleFrameSeconds, fullFrameSeconds
        case quotaRefreshSeconds, sessionPollSeconds, sessionFinishDelaySeconds, manualMergeSeconds
        case proxyTrafficEnabled, proxyTrafficExportDirectory
        case costRefreshSeconds, processSampleSeconds, quotaHistoryDays, codexBarCLIPath, moPath, cleanTerminal, aiAgent, aiDiagnosisEntry
        case desktopCat, menuBarPet
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LocalConfig()
        do { alertRules = try fields.decodeIfPresent(AlertRuleSet.self, forKey: .alertRules) ?? AlertRuleSet() }
        catch { alertRules = AlertRuleSet(diagnostics: ["提醒规则结构无效，已回退默认规则"]) }
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
        // 采样间隔直接传给 `top -s`：负值、0 和极大值会让采样崩溃或空转，越界回退默认值。
        let sampleSeconds = try fields.decodeIfPresent(Double.self, forKey: .processSampleSeconds) ?? defaults.processSampleSeconds
        processSampleSeconds = (10...600).contains(sampleSeconds) ? sampleSeconds : defaults.processSampleSeconds
        proxyTrafficEnabled = try fields.decodeIfPresent(Bool.self, forKey: .proxyTrafficEnabled) ?? defaults.proxyTrafficEnabled
        proxyTrafficExportDirectory = try fields.decodeIfPresent(String.self, forKey: .proxyTrafficExportDirectory) ?? defaults.proxyTrafficExportDirectory
        quotaHistoryDays = try fields.decodeIfPresent(Int.self, forKey: .quotaHistoryDays) ?? defaults.quotaHistoryDays
        codexBarCLIPath = try fields.decodeIfPresent(String.self, forKey: .codexBarCLIPath) ?? defaults.codexBarCLIPath
        cleanTerminal = try fields.decodeIfPresent(CleanTerminal.self, forKey: .cleanTerminal) ?? defaults.cleanTerminal
        aiAgent = try fields.decodeIfPresent(AIAgent.self, forKey: .aiAgent) ?? defaults.aiAgent
        aiDiagnosisEntry = try fields.decodeIfPresent(Bool.self, forKey: .aiDiagnosisEntry) ?? defaults.aiDiagnosisEntry
        moPath = try fields.decodeIfPresent(String.self, forKey: .moPath) ?? defaults.moPath
        // 类型错误时整个桌面猫按默认值运行，不改写文件，直到用户在界面里修改（D8）。
        do { desktopCat = try fields.decodeIfPresent(DesktopCatConfig.self, forKey: .desktopCat) ?? DesktopCatConfig() }
        catch { desktopCat = DesktopCatConfig(diagnostics: ["桌面猫配置结构无效，已按默认值运行"]) }
        do { menuBarPet = try fields.decodeIfPresent(MenuBarPetConfig.self, forKey: .menuBarPet) ?? .desktop }
        catch { menuBarPet = .desktop; menuBarPetDiagnostics = ["菜单栏形象配置无效，已与桌面猫相同"] }
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

    /// 只更新清理终端字段，保留用户配置的其他字段和未知字段。
    public static func saveCleanTerminal(_ preference: CleanTerminal, to url: URL = defaultURL) throws {
        try saveField("cleanTerminal", value: preference.rawValue, to: url)
    }

    public static func saveAIAgent(_ preference: AIAgent, to url: URL = defaultURL) throws {
        try saveField("aiAgent", value: preference.rawValue, to: url)
    }

    public static func saveAIDiagnosisEntry(_ enabled: Bool, to url: URL = defaultURL) throws {
        try saveField("aiDiagnosisEntry", value: enabled, to: url)
    }

    private static func saveField(_ key: String, value: Any, to url: URL) throws {
        try updateObject(at: url) { $0[key] = value }
    }

    static func updateField(_ key: String, value: Any, at url: URL) throws {
        try updateObject(at: url) { $0[key] = value }
    }

    /// 只修正原文件中未编辑的坏覆盖；新提交的越界字段仍按严格校验拒绝。
    public static func prepareAlertRules(_ rules: AlertRuleSet, changedBuiltin: Set<BuiltinAlertRule> = [],
                                        restoringDefaults: Bool = false, to url: URL = defaultURL) throws -> AlertRuleSet {
        let loaded = load(from: url)
        guard loaded.error == nil else { throw AlertRuleError.invalid("配置文件无效，未覆盖原文件") }
        var next = rules
        if restoringDefaults {
            next.quotaProviders = [:]
            for rule in BuiltinAlertRule.allCases { next.builtin.removeValue(forKey: rule.id) }
        } else {
            for (id, value) in rules.builtin {
                guard let rule = BuiltinAlertRule(rawValue: id), !changedBuiltin.contains(rule),
                      loaded.config.alertRules.builtin[id] == value else { continue }
                do { _ = try AlertRuleSet(builtin: [id: value]).validated() }
                catch { next.builtin[id] = loaded.config.alertRules.effective(rule, config: loaded.config) }
            }
        }
        return try next.validated()
    }

    public static func saveAlertRules(_ rules: AlertRuleSet, changedBuiltin: Set<BuiltinAlertRule> = [],
                                      restoringDefaults: Bool = false, to url: URL = defaultURL) throws {
        let valid = try prepareAlertRules(rules, changedBuiltin: changedBuiltin, restoringDefaults: restoringDefaults, to: url)
        try updateObject(at: url) { object in
            var root = object["alertRules"] as? [String: Any] ?? [:]
            var builtin = root["builtin"] as? [String: Any] ?? [:]
            let repaired = Set(BuiltinAlertRule.allCases.filter { valid.builtin[$0.id] != rules.builtin[$0.id] })
            let targets = restoringDefaults ? Set(BuiltinAlertRule.allCases) : changedBuiltin.union(repaired)
            for rule in targets {
                for key in rule.legacyKeys { object.removeValue(forKey: key) }
                if restoringDefaults { builtin.removeValue(forKey: rule.id); continue }
                var fields = builtin[rule.id] as? [String: Any] ?? [:]
                let value = valid.builtin[rule.id] ?? rule.defaults
                let data = try JSONEncoder().encode(value)
                let encoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rule.defaults)) as! [String: Any]
                for key in ["enabled", "threshold", "durationSeconds", "fairThermalSeconds", "fanHighSeconds"] {
                    fields.removeValue(forKey: key)
                    if let item = encoded[key], (item as? NSObject) != (defaults[key] as? NSObject) { fields[key] = item }
                }
                if fields.isEmpty { builtin.removeValue(forKey: rule.id) } else { builtin[rule.id] = fields }
            }
            var providers = root["quotaProviders"] as? [String: Any] ?? [:]
            for provider in Set(providers.keys).union(valid.quotaProviders.keys) {
                var fields = providers[provider] as? [String: Any] ?? [:]
                let value = valid.quotaProviders[provider] ?? QuotaAlertProviderOverride()
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
                for key in ["remainingEnabled", "paceEnabled", "balanceEnabled", "remainingThreshold"] {
                    fields.removeValue(forKey: key)
                    if let item = encoded[key] { fields[key] = item }
                }
                if fields.isEmpty { providers.removeValue(forKey: provider) } else { providers[provider] = fields }
            }
            if providers.isEmpty { root.removeValue(forKey: "quotaProviders") } else { root["quotaProviders"] = providers }
            root["builtin"] = builtin
            root["custom"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid.custom))
            object["alertRules"] = root
        }
    }

    private static func updateObject(at url: URL, update: (inout [String: Any]) throws -> Void) throws {
        var object: [String: Any]
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(LocalConfig.self, from: data)
            guard decoded.schemaVersion == 1,
                  let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            object = existing
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            object = ["schemaVersion": 1]
        }
        try update(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
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
