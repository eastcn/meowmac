import Foundation
import MeowMacCore
import MeowMacUI

@MainActor
enum QuotaProviderTests {
    static func legacyRoundTrip() -> Bool {
        do {
            let encoder = JSONEncoder(), decoder = JSONDecoder()
            for (id, provider) in zip(["deepseek", "codex", "claude", "opencodego"], QuotaProvider.defaults) {
                let legacy = Data("\"\(id)\"".utf8)
                guard try decoder.decode(QuotaProvider.self, from: legacy) == provider,
                      try encoder.encode(provider) == legacy else { return false }
            }
            let style = Data(#"{"schemaVersion":1,"quotaBasis":"remaining","email":"full","chartMinutes":60,"colors":{"claude":"default","codex":"default","deepseek":"default","opencodego":"default"}}"#.utf8)
            let parsedStyle = try StyleSettings.parse(style)
            guard parsedStyle == .default,
                  try StyleSettings.parse(encoder.encode(parsedStyle)) == parsedStyle else { return false }
            let panel = PanelLayout.default
            guard try PanelLayout.parse(encoder.encode(panel)) == panel else { return false }
            encoder.dateEncodingStrategy = .iso8601; decoder.dateDecodingStrategy = .iso8601
            let history = Data(#"{"sampledAt":"2026-10-01T00:00:00Z","provider":"claude","windowMinutes":300,"usedPercent":42,"resetsAt":"2026-10-01T05:00:00Z","windowID":"primary"}"#.utf8)
            let line = try decoder.decode(QuotaHistoryLine.self, from: history)
            let restored = try decoder.decode(QuotaHistoryLine.self, from: encoder.encode(line))
            guard restored.provider == .claude, restored.sampledAt == line.sampledAt,
                  restored.usedPercent == 42, restored.resetsAt == line.resetsAt,
                  restored.windowID == "primary", restored.windowMinutes == 300 else { return false }
            let cat = try CatPackageLoader.builtin("builtin.slim")
            let package = try CatPackage.parse(cat.files["manifest.json"]!, builtin: true)
            guard package.panel == cat.package.panel,
                  try CatPackage.parse(JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: cat.files["manifest.json"]!)), builtin: true).panel == package.panel else { return false }
            let other = QuotaProvider(rawValue: "openrouter")!
            return try decoder.decode(QuotaProvider.self, from: encoder.encode(other)) == other
                && QuotaProvider(rawValue: "../outside") == nil
                && (try? decoder.decode(QuotaProvider.self, from: Data("{}".utf8))) == nil
        } catch { print("渠道旧格式往返失败：\(error)"); return false }
    }
}
