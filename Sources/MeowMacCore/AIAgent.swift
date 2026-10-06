import Foundation

public enum AIAgent: String, Codable, CaseIterable {
    case automatic, claudeCode, codex, openCode, gemini, qoder, claudeDesktop, chatGPT, deepSeekHarness

    public var name: String {
        switch self {
        case .automatic: return "自动"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .gemini: return "Gemini"
        case .qoder: return "Qoder"
        case .claudeDesktop: return "Claude 桌面版"
        case .chatGPT: return "ChatGPT（Codex 桌面版）"
        case .deepSeekHarness: return "DeepSeek Harness"
        }
    }
    public var executableName: String? {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .openCode: return "opencode"
        case .gemini: return "gemini"
        case .qoder: return "qodercli"
        default: return nil
        }
    }
    public var bundleIDs: [String] {
        switch self {
        case .claudeDesktop: return ["com.anthropic.claudefordesktop"]
        case .chatGPT: return ["com.openai.codex", "com.openai.chat"]
        case .deepSeekHarness: return ["com.deepseek.dsh"]
        default: return []
        }
    }
    public var launchDescription: String {
        if executableName != nil { return self == .qoder ? "终端 · 复制后粘贴" : "终端" }
        return self == .claudeDesktop ? "预填" : "复制后打开"
    }
    public static var agents: [Self] { allCases.filter { $0 != .automatic } }
    public func resolved(available: Set<Self>, lastSuccessful: Self? = nil) -> Self? {
        if self != .automatic, available.contains(self) { return self }
        if let lastSuccessful, lastSuccessful != .automatic, available.contains(lastSuccessful) { return lastSuccessful }
        let order: [Self] = [.claudeCode, .codex, .openCode, .claudeDesktop, .gemini, .qoder, .chatGPT, .deepSeekHarness]
        return order.first(where: available.contains)
    }
    public func arguments(prompt: String) -> [String] {
        switch self {
        case .claudeCode, .codex: return [prompt]
        case .openCode: return ["--prompt", prompt]
        case .gemini: return ["-i", prompt]
        default: return []
        }
    }
    public func promptURL(_ prompt: String) -> URL? {
        guard self == .claudeDesktop else { return nil }
        var parts = URLComponents()
        parts.scheme = "claude"; parts.host = "code"; parts.path = "/new"
        parts.queryItems = [URLQueryItem(name: "q", value: prompt)]
        // URL 的表单式查询解码会把裸加号视为空格，必须编码字面量加号。
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }
}

public enum AIAgentCommand {
    public static func script(agent: AIAgent, executable: String, prompt: String, workingDirectory: String) -> String {
        let quote = CleaningCommand.quote
        let parent = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        let arguments = agent.arguments(prompt: prompt).map(quote).joined(separator: " ")
        return """
        #!/bin/sh
        trap '/bin/rm -f -- "$0"' EXIT
        export PATH=\(quote(parent + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")):"$PATH"
        if ! cd -- \(quote(workingDirectory)); then
            printf '%s\\n' '无法进入 AI 排查工作目录。请返回 MeowMac 重试或复制提示词。'
            status=1
        elif [ ! -f \(quote(executable)) ] || [ ! -x \(quote(executable)) ]; then
            printf '%s\\n' 'agent 不再可执行。请返回 MeowMac 重新检测或复制提示词。'
            status=127
        else
            \(quote(executable)) \(arguments)
            status=$?
        fi
        printf '\\nAI 排查命令已退出（状态 %s）。按回车关闭窗口。\\n' "$status"
        read -r acknowledgement
        exit "$status"

        """
    }
}
