import Foundation

public enum CleanTerminal: String, Codable, CaseIterable {
    case automatic, ghostty, iterm, terminal

    public var name: String {
        switch self {
        case .automatic: return "自动"
        case .ghostty: return "Ghostty"
        case .iterm: return "iTerm2"
        case .terminal: return "系统终端"
        }
    }

    public var bundleID: String? {
        switch self {
        case .automatic: return nil
        case .ghostty: return "com.mitchellh.ghostty"
        case .iterm: return "com.googlecode.iterm2"
        case .terminal: return "com.apple.Terminal"
        }
    }

    public func resolved(available: Set<CleanTerminal>) -> CleanTerminal? {
        if self != .automatic { return available.contains(self) ? self : nil }
        return [Self.ghostty, .iterm, .terminal].first(where: available.contains)
    }
}

public enum CleaningCommand {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func command(executable: String) -> String { quote(executable) + " clean" }

    /// 始终执行已检测的绝对路径。运行前复查；完成后等用户确认关闭。
    public static func script(executable: String) -> String {
        let path = quote(executable)
        let parent = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        return """
        #!/bin/sh
        trap '/bin/rm -f -- "$0"' EXIT
        export PATH=\(quote(parent + ":/opt/homebrew/bin:/usr/local/bin")):"$PATH"
        if [ ! -f \(path) ] || [ ! -x \(path) ]; then
            printf '%s\\n' '未找到可执行的 Mole，请返回 MeowMac 检查配置。'
            status=127
        else
            \(command(executable: executable))
            status=$?
        fi
        printf '\\n清理命令已退出（状态 %s）。按回车关闭窗口。\\n' "$status"
        read -r acknowledgement
        exit "$status"

        """
    }
}
