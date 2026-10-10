import Foundation
import MeowMacCore
import os

public enum CodexBarError: Error {
    case commandFailed(Int32)
    case exceededDeadline
    case commandBusy
    case configFailed(Int32)
    case apiKeyUnsupported
}

public final class CodexBarClient {
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()

        func set(_ data: Data, stderr: Bool) {
            lock.lock(); defer { lock.unlock() }
            if stderr { self.stderr = data } else { stdout = data }
        }

        func read() -> (Data, Data) {
            lock.lock(); defer { lock.unlock() }
            return (stdout, stderr)
        }
    }

    private let rawOutput: (([String], Data, Data) -> Void)?
    private let executable: URL
    private let environment: [String: String]
    private let executor: Executor?
    private let deadlineSeconds: TimeInterval
    public typealias Executor = (URL, [String], [String: String], Data?) throws -> CLIOutput
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "quota")
    private let lock = NSLock()
    private var running = false

    public init(path: String, environment: [String: String] = [:], executor: Executor? = nil,
                deadlineSeconds: TimeInterval = 60, rawOutput: (([String], Data, Data) -> Void)? = nil) {
        precondition(deadlineSeconds.isFinite && deadlineSeconds > 0)
        self.executable = URL(fileURLWithPath: path); self.environment = environment
        self.executor = executor; self.rawOutput = rawOutput
        self.deadlineSeconds = deadlineSeconds
    }

    public func providers() throws -> [QuotaCatalogEntry] {
        try QuotaCatalog.providers(run(["config", "providers", "--json"]))
    }
    public func configStatus() throws -> [QuotaProvider: Bool] {
        try QuotaCatalog.credentialStatus(run(["config", "dump", "--json"]))
    }
    public func setEnabled(_ enabled: Bool, provider: QuotaProvider) throws {
        _ = try run(["config", enabled ? "enable" : "disable", "--provider", provider.rawValue, "--json"])
    }
    public func setAPIKey(_ key: String, provider: QuotaProvider) throws {
        guard QuotaCatalog.entry(provider)?.supportsAPIKey == true else { throw CodexBarError.apiKeyUnsupported }
        _ = try run(["config", "set-api-key", "--provider", provider.rawValue, "--stdin", "--no-enable", "--json"], stdin: Data((key + "\n").utf8))
    }

    public func dashboard() throws -> (snapshots: [QuotaProvider: QuotaSnapshot], errors: [QuotaProvider: String]) {
        let data = try run(["dashboard", "--timeout", "60", "--identity", "redacted"])
        return try CodexBarParser.dashboard(data, at: Date())
    }

    public func usage(_ provider: QuotaProvider) throws -> QuotaSnapshot {
        let data = try run(["usage", "--provider", QuotaCatalog.usageNames[provider.rawValue] ?? provider.rawValue, "--json"])
        return try CodexBarParser.usage(data, at: Date())
    }

    public func cost(_ provider: QuotaProvider) throws -> [DailyCost] {
        guard [.claude, .codex].contains(provider) else { return [] }
        let data = try run(["cost", "--provider", provider.rawValue, "--days", "30", "--breakdown", "--json"])
        return try CodexBarParser.cost(data)
    }

    public func sessions() throws -> [SessionActivity] {
        try CodexBarParser.sessions(run(["sessions", "--json-v2"]))
    }

    private func run(_ arguments: [String], stdin: Data? = nil) throws -> Data {
        if let executor {
            let output = try executor(executable, arguments, environment, stdin)
            return try finish(arguments, output: output)
        }
        lock.lock()
        guard !running else { lock.unlock(); throw CodexBarError.commandBusy }
        running = true
        lock.unlock()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? nil
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output = OutputBox()
        let group = DispatchGroup()
        // 启动前登记退出通知，避免跨线程 waitUntilExit 错过退出后永久等待。
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        do { try process.run() }
        catch {
            process.terminationHandler = nil
            group.leave()
            lock.lock(); running = false; lock.unlock()
            throw error
        }
        if let input, let stdin {
            DispatchQueue.global(qos: .utility).async {
                do { try input.fileHandleForWriting.write(contentsOf: stdin); try input.fileHandleForWriting.close() }
                catch {
                    try? input.fileHandleForWriting.close()
                    Logger(subsystem: AppIdentity.bundleID, category: "quota").error("CLI stdin 写入失败，未记录输入内容")
                }
            }
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            output.set(stdout.fileHandleForReading.readDataToEndOfFile(), stderr: false)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            output.set(stderr.fileHandleForReading.readDataToEndOfFile(), stderr: true)
            group.leave()
        }
        guard group.wait(timeout: .now() + deadlineSeconds) == .success else {
            group.notify(queue: .global(qos: .utility)) { [weak self, process] in
                // 超时不结束进程；保留 Process，直到退出通知和两个管道均完成。
                process.terminationHandler = nil
                guard let self else { return }
                self.lock.lock(); self.running = false; self.lock.unlock()
            }
            logger.error("CLI 命令超过 60 秒：\(arguments.first ?? "未知", privacy: .public)")
            throw CodexBarError.exceededDeadline
        }
        process.terminationHandler = nil
        lock.lock(); running = false; lock.unlock()
        let (data, errors) = output.read()
        return try finish(arguments, output: CLIOutput(status: process.terminationStatus, stdout: data, stderr: errors))
    }

    private func finish(_ arguments: [String], output: CLIOutput) throws -> Data {
        let data = output.stdout, errors = output.stderr
        // 配置输出可能含凭据；既不进入原始输出回调，也不记录 stderr。
        if arguments.first == "config" {
            guard output.status == 0 else {
                if String(data: data, encoding: .utf8)?.contains("does not support config API keys") == true {
                    throw CodexBarError.apiKeyUnsupported
                }
                throw CodexBarError.configFailed(output.status)
            }
            return data
        }
        rawOutput?(arguments, data, errors)
        if !errors.isEmpty, let message = String(data: errors, encoding: .utf8) {
            logger.warning("CLI stderr：\(message, privacy: .private)")
        }
        guard output.status == 0 else {
            logger.error("CLI 命令失败：\(arguments.first ?? "未知", privacy: .public)，退出码 \(output.status)")
            throw CodexBarError.commandFailed(output.status)
        }
        return data
    }
}


public struct CLIOutput {
    public let status: Int32
    public let stdout: Data, stderr: Data
    public init(status: Int32 = 0, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

extension CodexBarError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let code): return "额度采集失败（退出码 \(code)），请先在浏览器或对应 CLI 中登录该服务"
        case .exceededDeadline: return "CLI 命令超过 60 秒，等待原命令结束后再试"
        case .commandBusy: return "CLI 正在执行其他请求，请稍后再试"
        case .configFailed(let code): return "CodexBar 配置保存失败（退出码 \(code)）"
        case .apiKeyUnsupported: return "该渠道不支持 config API keys，未重试"
        }
    }
}
