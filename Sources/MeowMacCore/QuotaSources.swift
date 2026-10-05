import Foundation

public struct QuotaCatalogEntry: Equatable, Identifiable, Codable, Sendable {
    public let provider: QuotaProvider
    public let displayName: String
    public let usageName: String
    public var enabled: Bool
    public var id: String { provider.rawValue }
    public var supportsAPIKey: Bool { QuotaCatalog.apiKeyIDs.contains(id) && ![.claude, .codex].contains(provider) }
    public init(provider: QuotaProvider, displayName: String, usageName: String, enabled: Bool) {
        self.provider = provider; self.displayName = displayName; self.usageName = usageName; self.enabled = enabled
    }
}

public enum QuotaCatalog {
    // CodexBarCLI 0.70.0：对照 config providers 与 usage --help，87 个渠道全部有映射。
    public static let usageNames: [String: String] = [
        "codex": "codex",
        "openai": "openai",
        "azureopenai": "azure-openai",
        "claude": "claude",
        "clinepass": "clinepass",
        "cursor": "cursor",
        "opencode": "opencode",
        "opencodego": "opencodego",
        "alibaba": "alibaba-coding-plan",
        "alibabatokenplan": "alibaba-token-plan",
        "qwencloud": "qwen-cloud",
        "factory": "factory",
        "fireworks": "fireworks",
        "gemini": "gemini",
        "antigravity": "antigravity",
        "copilot": "copilot",
        "devin": "devin",
        "zai": "zai",
        "minimax": "minimax",
        "manus": "manus",
        "kimi": "kimi",
        "kilo": "kilo",
        "kiro": "kiro",
        "vertexai": "vertexai",
        "augment": "augment",
        "jetbrains": "jetbrains",
        "moonshot": "moonshot",
        "amp": "amp",
        "t3chat": "t3chat",
        "ollama": "ollama",
        "synthetic": "synthetic",
        "openrouter": "openrouter",
        "elevenlabs": "elevenlabs",
        "warp": "warp",
        "windsurf": "windsurf",
        "zed": "zed",
        "perplexity": "perplexity",
        "mimo": "mimo",
        "doubao": "doubao",
        "sakana": "sakana",
        "abacus": "abacusai",
        "mistral": "mistral",
        "deepseek": "deepseek",
        "deepinfra": "deepinfra",
        "codebuff": "codebuff",
        "venice": "venice",
        "commandcode": "commandcode",
        "qoder": "qoder",
        "stepfun": "stepfun",
        "bedrock": "bedrock",
        "grok": "grok",
        "groq": "groqcloud",
        "llmproxy": "llmproxy",
        "litellm": "litellm",
        "bifrost": "bifrost",
        "aixy": "aixy",
        "deepgram": "deepgram",
        "poe": "poe",
        "chutes": "chutes",
        "neuralwatt": "neuralwatt",
        "helmcode": "helmcode",
        "clawrouter": "clawrouter",
        "longcat": "longcat",
        "sub2api": "sub2api",
        "wayfinder": "wayfinder",
        "zenmux": "zenmux",
        "aiand": "aiand",
        "zoommate": "zoommate",
        "xai": "xai",
        "notion": "notion",
        "ibmbob": "ibmbob",
        "nous": "nous",
        "muse": "muse",
        "coderabbit": "coderabbit",
        "replicate": "replicate",
        "huggingface": "huggingface",
        "raycast": "raycast",
        "pi": "pi",
        "v0": "v0",
        "typesafe": "typesafe",
        "hyper": "hyper",
        "gitkraken": "gitkraken",
        "devpass": "devpass",
        "atlascloud": "atlascloud",
        "vercel": "vercel",
        "llmman": "llmman",
        "xkiro": "xkiro",
    ]
    public static let displayNames: [String: String] = [
        "codex": "Codex",
        "openai": "OpenAI",
        "azureopenai": "Azure OpenAI",
        "claude": "Claude",
        "clinepass": "ClinePass",
        "cursor": "Cursor",
        "opencode": "OpenCode",
        "opencodego": "OpenCode Go",
        "alibaba": "Alibaba",
        "alibabatokenplan": "Alibaba Token Plan",
        "qwencloud": "Qwen Cloud",
        "factory": "Droid",
        "fireworks": "Fireworks",
        "gemini": "Gemini",
        "antigravity": "Antigravity",
        "copilot": "Copilot",
        "devin": "Devin",
        "zai": "z.ai / GLM",
        "minimax": "MiniMax",
        "manus": "Manus",
        "kimi": "Kimi Code",
        "kilo": "Kilo",
        "kiro": "Kiro",
        "vertexai": "Vertex AI",
        "augment": "Augment",
        "jetbrains": "JetBrains AI",
        "moonshot": "Moonshot / Kimi Open Platform",
        "amp": "Amp",
        "t3chat": "T3 Chat",
        "ollama": "Ollama",
        "synthetic": "Synthetic",
        "openrouter": "OpenRouter",
        "elevenlabs": "ElevenLabs",
        "warp": "Warp",
        "windsurf": "Windsurf",
        "zed": "Zed",
        "perplexity": "Perplexity",
        "mimo": "Xiaomi MiMo",
        "doubao": "Doubao",
        "sakana": "Sakana AI",
        "abacus": "Abacus AI",
        "mistral": "Mistral",
        "deepseek": "DeepSeek",
        "deepinfra": "DeepInfra",
        "codebuff": "Codebuff",
        "venice": "Venice",
        "commandcode": "Command Code",
        "qoder": "Qoder",
        "stepfun": "StepFun",
        "bedrock": "AWS Bedrock",
        "grok": "Grok",
        "groq": "Groq",
        "llmproxy": "LLM Proxy",
        "litellm": "LiteLLM",
        "bifrost": "Bifrost",
        "aixy": "Aixy",
        "deepgram": "Deepgram",
        "poe": "Poe",
        "chutes": "Chutes",
        "neuralwatt": "Neuralwatt",
        "helmcode": "Helmcode",
        "clawrouter": "ClawRouter",
        "longcat": "LongCat",
        "sub2api": "sub2api",
        "wayfinder": "Wayfinder",
        "zenmux": "ZenMux",
        "aiand": "ai&",
        "zoommate": "ZoomMate",
        "xai": "xAI",
        "notion": "Notion AI",
        "ibmbob": "IBM Bob",
        "nous": "Nous Portal",
        "muse": "Muse Code",
        "coderabbit": "CodeRabbit",
        "replicate": "Replicate",
        "huggingface": "Hugging Face",
        "raycast": "Raycast",
        "pi": "Pi",
        "v0": "v0",
        "typesafe": "TypeSafe",
        "hyper": "Charm Hyper",
        "gitkraken": "GitKraken AI",
        "devpass": "DevPass",
        "atlascloud": "Atlas Cloud",
        "vercel": "Vercel AI Gateway",
        "llmman": "llmman",
        "xkiro": "xKiro",
    ]
    // CLI 0.70.0 的 config API key 支持清单；Claude 和 Codex 的编辑入口另行排除。
    public static let apiKeyIDs = Set("openai azureopenai claude clinepass opencodego alibaba factory fireworks copilot zai minimax kimi kilo moonshot amp ollama synthetic openrouter elevenlabs warp doubao deepinfra codebuff venice groq llmproxy litellm bifrost aixy deepgram poe chutes neuralwatt clawrouter sub2api zenmux aiand xai ibmbob huggingface v0 hyper gitkraken devpass atlascloud vercel llmman xkiro".split(separator: " ").map(String.init))
    public static func provider(forUsageName name: String) -> QuotaProvider? {
        usageNames.first { $0.value == name }.flatMap { QuotaProvider(rawValue: $0.key) }
    }
    public static func entry(_ provider: QuotaProvider, enabled: Bool = true) -> QuotaCatalogEntry? {
        guard let name = usageNames[provider.rawValue] else { return nil }
        return QuotaCatalogEntry(provider: provider, displayName: displayNames[provider.rawValue] ?? provider.rawValue, usageName: name, enabled: enabled)
    }
    public static func providers(_ data: Data) throws -> [QuotaCatalogEntry] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw QuotaParseError.invalidRoot }
        return rows.compactMap { row in
            guard let id = row["provider"] as? String, let provider = QuotaProvider(rawValue: id),
                  let usage = usageNames[id], let name = row["displayName"] as? String,
                  let enabled = row["enabled"] as? Bool else { return nil }
            return QuotaCatalogEntry(provider: provider, displayName: name, usageName: usage, enabled: enabled)
        }
    }
    /// 只取脱敏凭据的存在状态，不保留 dump 中的其他字段。
    public static func credentialStatus(_ data: Data) throws -> [QuotaProvider: Bool] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [[String: Any]] else { throw QuotaParseError.invalidRoot }
        return Dictionary(providers.compactMap { row -> (QuotaProvider, Bool)? in
            guard let id = row["id"] as? String, let provider = QuotaProvider(rawValue: id) else { return nil }
            let configured = (row["apiKey"] as? String) == "[REDACTED]"
                || ((row["tokenAccounts"] as? [[String: Any]]) ?? []).contains { ($0["token"] as? String) == "[REDACTED]" }
            return (provider, configured)
        }, uniquingKeysWith: { $0 || $1 })
    }
}

public struct QuotaSourceList: Codable, Equatable, Sendable {
    public var providers: [QuotaProvider]
    public init(providers: [QuotaProvider] = [.claude, .codex, .deepseek, .opencodego]) { self.providers = providers }
    public func validated() throws -> Self {
        guard providers.count <= QuotaCatalog.usageNames.count, Set(providers).count == providers.count,
              providers.allSatisfy({ QuotaCatalog.usageNames[$0.rawValue] != nil }) else { throw QuotaSourceError.invalid }
        return self
    }
}

public enum QuotaSourceError: Error, LocalizedError {
    case invalid, unsafeFile
    public var errorDescription: String? {
        switch self {
        case .invalid: return "额度渠道清单无效，已回退默认渠道。请修复或移走 quota-sources.json 后再保存。"
        case .unsafeFile: return "额度渠道清单路径不安全，未写入。"
        }
    }
}

public struct QuotaSourceStore {
    public let file: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MeowMac")) {
        file = root.appendingPathComponent("quota-sources.json")
    }
    private func checkPath() throws {
        var url = file.standardizedFileURL
        while url.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw QuotaSourceError.unsafeFile }
            url.deleteLastPathComponent()
        }
    }
    public func load() -> (list: QuotaSourceList, recoveryReason: String?) {
        do {
            try checkPath()
            guard FileManager.default.fileExists(atPath: file.path) else { return (QuotaSourceList(), nil) }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 16384 else { throw QuotaSourceError.invalid }
            let list = try JSONDecoder().decode(QuotaSourceList.self, from: Data(contentsOf: file)).validated()
            return (list, nil)
        } catch { return (QuotaSourceList(), QuotaSourceError.invalid.localizedDescription) }
    }
    public func save(_ list: QuotaSourceList) throws {
        _ = try list.validated(); try checkPath()
        guard load().recoveryReason == nil else { throw QuotaSourceError.invalid }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try checkPath()
        try JSONEncoder().encode(list).write(to: file, options: .atomic)
    }
}

public struct QuotaAttempt: Sendable {
    public let at: Date
    public let success: Bool
    public let message: String
    public init(at: Date, success: Bool, message: String) { self.at = at; self.success = success; self.message = message }
}
