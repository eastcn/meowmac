import Foundation
import Darwin

public struct AIAgentLaunchReport: Codable {
    public let pid: Int32?
    public let error: String?
}

/// 仅由终端里的 MeowMac 子进程调用。继承终端、进程组和标准输入输出。
public enum AIAgentProcessRunner {
    public static let option = "--run-ai-agent"
    public static func handle(_ arguments: [String]) -> Int32? {
        guard arguments.first == option else { return nil }
        guard arguments.count >= 4 else { fputs("AI 排查启动参数不完整。\n", stderr); return 1 }
        let report = URL(fileURLWithPath: arguments[1])
        func publish(pid: Int32? = nil, error: String? = nil) {
            do { try JSONEncoder().encode(AIAgentLaunchReport(pid: pid, error: error)).write(to: report, options: .atomic) }
            catch { fputs("AI 排查启动结果无法回传：\(error.localizedDescription)\n", stderr) }
        }
        func fail(_ reason: String) -> Int32 {
            publish(error: reason); fputs(reason + "\n", stderr); return 127
        }
        guard chdir(arguments[2]) == 0 else { return fail("无法进入 AI 排查工作目录：" + String(cString: strerror(errno))) }
        let executable = arguments[3]
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable, isDirectory: &directory), !directory.boolValue,
              FileManager.default.isExecutableFile(atPath: executable) else { return fail("agent 不再可执行。请重新检测。") }
        var image = executable, imageArguments = Array(arguments.dropFirst(4))
        do {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: executable))
            let header = try file.read(upToCount: 512) ?? Data()
            try file.close()
            if header.starts(with: [0x23, 0x21]) {
                let words = (String(decoding: header.dropFirst(2), as: UTF8.self).components(separatedBy: "\n").first ?? "")
                    .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                // 常见的 env node/sh 直接执行解析后的解释器，避免只确认 env 自身启动。
                if words.count == 2, words[0] == "/usr/bin/env", !words[1].hasPrefix("-") {
                    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":")
                    let candidates = words[1].contains("/") ? [words[1]] : paths.map { ($0.isEmpty ? "." : $0) + "/" + words[1] }
                    guard let interpreter = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                        return fail("agent 解释器不可用：" + words[1])
                    }
                    image = interpreter; imageArguments.insert(executable, at: 0)
                }
            }
        } catch { return fail("无法读取 agent 启动程序：" + error.localizedDescription) }
        var argv = ([image] + imageArguments).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        argv.append(nil)
        var envp = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) }
        defer { envp.forEach { free($0) } }
        envp.append(nil)
        var pid: pid_t = 0
        // Darwin 的 posix_spawn 直接回传 exec 错误，包括 shebang 解释器缺失。
        let result = posix_spawn(&pid, image, nil, nil, &argv, &envp)
        guard result == 0 else { return fail("无法执行 agent（可执行文件或解释器不可用）：" + String(cString: strerror(result))) }
        publish(pid: pid)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno == EINTR { continue }
            fputs("无法读取 agent 退出状态：\(String(cString: strerror(errno)))\n", stderr); return 1
        }
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}
