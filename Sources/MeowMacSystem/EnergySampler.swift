import Foundation
import Darwin
import MeowMacCore

public enum EnergySampler {
    public static func processes(rawOutput: ((Data) -> Void)? = nil) throws -> [ProcessEnergy] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "2", "-s", "1", "-o", "power", "-n", "10", "-stats", "pid,command,cpu,power"]
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
