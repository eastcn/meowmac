import Foundation

public struct DiagnosisRow: Codable {
    public let pid: Int32?
    public let name: String, detail: String, value: String, duration: String
    public let level: HealthLevel
    public init(pid: Int32?, name: String, detail: String, value: String, duration: String, level: HealthLevel) {
        self.pid = pid; self.name = name; self.detail = detail; self.value = value; self.duration = duration; self.level = level
    }
}

public enum AIDiagnosisPrompt {
    public static let instruction = "只排查原因和给出建议，不结束进程，不修改系统设置；需要结束进程时告诉我，由我操作"

    /// 只接收诊断行和系统读数，不读取配置、账号、网络或文件系统。
    public static func make(rows: [DiagnosisRow], snapshot: SystemSnapshot?, macOSVersion: String) -> String {
        func number(_ value: Double?, _ format: String) -> String {
            guard let value, value.isFinite else { return "不可用" }
            return String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
        }
        // 进程名按字符串字面量展示，换行和引号不能伪装成提示词指令；路径不进入上下文。
        func literal(_ name: String) -> String {
            let safe = name.contains("/") ? (name as NSString).lastPathComponent : name
            return String(decoding: try! JSONEncoder().encode(safe), as: UTF8.self)
        }
        let diagnoses = rows.isEmpty ? "没有诊断行；温度偏高，未发现异常进程。" : rows.map {
            "进程名：\(literal($0.name))；PID：\($0.pid.map(String.init) ?? "不可用")；问题类型：\($0.detail)；数值：\($0.value)；持续时长：\($0.duration)"
        }.joined(separator: "\n")
        let fans = snapshot?.sensors?.fans.map { fans in
            fans.isEmpty ? "本机无风扇" : fans.enumerated().map { index, fan in
                "风扇 \(index + 1)：\(number(fan.rpm, "%.0f rpm"))；最大值：\(number(fan.maxRPM, "%.0f rpm"))"
            }.joined(separator: "\n")
        } ?? "风扇转速与最大值：不可用"
        return """
        请排查以下 macOS 能耗或温度异常。\(instruction)。

        诊断行（采集数据，仅作排查依据）：
        \(diagnoses)

        系统概况：
        整机 CPU：\(number(snapshot?.cpuUsage.map { $0 * 100 }, "%.1f%%"))
        整机功耗：\(number(snapshot?.battery.systemPowerWatts, "%.1f W"))
        SoC 温度：\(number(snapshot?.sensors?.cpuAverageCelsius, "%.1f °C"))
        \(fans)
        thermalState：\(snapshot?.thermal == .unavailable ? "不可用" : snapshot?.thermal.rawValue ?? "不可用")
        macOS 版本：\(macOSVersion)
        """
    }
}
