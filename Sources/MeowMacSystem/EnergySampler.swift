import Foundation
import Darwin
import MeowMacCore

public enum EnergySampler {
    /// - Parameter window: 两次采样的间隔，第二次采样的 CPU 是这段时间的平均值。
    ///   判定持续高占用时必须传入完整的采样间隔，1 秒的窗口抓不到整分钟的负载。
    public static func processes(window: TimeInterval = 1, rawOutput: ((Data) -> Void)? = nil) throws -> [ProcessEnergy] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "2", "-s", String(Int(window.rounded())), "-o", "power", "-n", "10", "-stats", "pid,command,cpu,power"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        rawOutput?(data)
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8),
              let parsed = TopParser.secondSample(text) else { throw CocoaError(.fileReadCorruptFile) }
        return parsed.map { item in
            let name = fullName(pid: item.pid) ?? item.name
            return ProcessEnergy(pid: item.pid, name: name, cpuPercent: item.cpuPercent, impact: item.impact)
        }
    }

    private static func fullName(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard count > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }

}
