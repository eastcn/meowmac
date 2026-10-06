import Foundation
import MeowMacCore

@MainActor
enum AIAgentCoreTests {
    static func prompt() -> Bool {
        let snapshot = SystemSnapshot(timestamp: Date(timeIntervalSince1970: 123), cpuUsage: 0.42, memoryPressure: .warn,
            swapUsedBytes: nil, diskAvailableBytes: nil, diskTotalBytes: nil, networkReceivedBytesPerSecond: 999,
            networkSentBytesPerSecond: 888, battery: BatteryMetrics(temperatureCelsius: 30, systemPowerWatts: 25.5), thermal: .fair,
            sensors: SensorReadings(cpuAverageCelsius: 65.5, cpuMaxCelsius: 70, cpuSource: .smc, gpuAverageCelsius: nil,
                fans: [FanReading(rpm: 2000, maxRPM: 5000), FanReading(rpm: 3000, maxRPM: nil)]))
        let name = "Example 'worker' \"two\"\n$(touch injected)"
        let row = DiagnosisRow(pid: 123, name: name, detail: "失控进程", value: "98%", duration: "已持续 12 分钟", level: .warn)
        let prompt = AIDiagnosisPrompt.make(rows: [row], snapshot: snapshot, macOSVersion: "26.5")
        guard ["PID：123", "失控进程", "98%", "12 分钟", "42.0%", "25.5 W", "65.5 °C", "2000 rpm", "5000 rpm", "3000 rpm", "最大值：不可用", "thermalState：fair", "26.5", AIDiagnosisPrompt.instruction].allSatisfy(prompt.contains),
              prompt.contains("\\n$(touch injected)"), prompt.contains("\\\"two\\\""), !prompt.contains("999"), !prompt.contains("888") else { return false }
        let missing = AIDiagnosisPrompt.make(rows: [], snapshot: nil, macOSVersion: "14.0")
        let pathRow = DiagnosisRow(pid: nil, name: "/Users/synthetic/Library/worker", detail: "内存压力持续偏高", value: "偏高", duration: "10 分钟", level: .warn)
        let sanitized = AIDiagnosisPrompt.make(rows: [pathRow], snapshot: nil, macOSVersion: "14.0")
        return missing.contains("没有诊断行") && missing.components(separatedBy: "不可用").count >= 6
            && !sanitized.contains("/Users/") && !sanitized.contains("synthetic") && sanitized.contains("worker")
    }
    static func catalog() -> Bool {
        let all = Set(AIAgent.agents)
        var remaining = all
        for expected in [AIAgent.claudeCode, .codex, .openCode, .claudeDesktop, .gemini, .qoder, .chatGPT, .deepSeekHarness] {
            guard AIAgent.automatic.resolved(available: remaining) == expected else { return false }
            remaining.remove(expected)
        }
        let text = "空格 ' \" & + ? #\n中文"
        guard let url = AIAgent.claudeDesktop.promptURL(text), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return all.count == 8 && AIAgent.automatic.resolved(available: []) == nil
            && AIAgent.automatic.resolved(available: all, lastSuccessful: .gemini) == .gemini
            && AIAgent.gemini.resolved(available: [.codex]) == .codex
            && AIAgent.codex.resolved(available: all, lastSuccessful: .gemini) == .codex
            && parts.scheme == "claude" && parts.host == "code" && parts.path == "/new" && parts.queryItems == [URLQueryItem(name: "q", value: text)]
            && AIAgent.claudeCode.arguments(prompt: text) == [text] && AIAgent.codex.arguments(prompt: text) == [text]
            && AIAgent.openCode.arguments(prompt: text) == ["--prompt", text] && AIAgent.gemini.arguments(prompt: text) == ["-i", text]
            && AIAgent.qoder.arguments(prompt: text).isEmpty && CleaningCommand.quote("a'b") == "'a'\\''b'"
    }
    static func config() -> Bool {
        let root = URL(fileURLWithPath: "build/acceptance/ai-agent-launch/core-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("config.json")
            try Data(#"{"schemaVersion":1,"cleanTerminal":"ghostty","future":123}"#.utf8).write(to: url)
            let old = ConfigStore.load(from: url)
            guard old.error == nil, old.config.aiAgent == .automatic, old.config.aiDiagnosisEntry else { return false }
            try ConfigStore.saveAIAgent(.openCode, to: url); try ConfigStore.saveAIDiagnosisEntry(false, to: url)
            try ConfigStore.saveCleanTerminal(.terminal, to: url)
            let new = ConfigStore.load(from: url)
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            guard new.error == nil, new.config.aiAgent == .openCode, !new.config.aiDiagnosisEntry,
                  new.config.cleanTerminal == .terminal, raw["future"] as? Int == 123,
                  try JSONDecoder().decode(LocalConfig.self, from: JSONEncoder().encode(new.config)) == new.config else { return false }
            try Data("broken".utf8).write(to: url)
            do { try ConfigStore.saveAIAgent(.codex, to: url); return false } catch {}
            do { try ConfigStore.saveAIDiagnosisEntry(true, to: url); return false } catch {}
            return try String(contentsOf: url) == "broken"
        } catch { print("AI 配置测试失败：\(error)"); return false }
    }
}
