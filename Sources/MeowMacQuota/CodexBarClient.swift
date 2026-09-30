import Foundation
import MeowMacCore
import os

public enum CodexBarError: Error {
    case commandFailed(Int32)
    case exceededDeadline
    case commandBusy
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

    private let executable: URL
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "quota")
    private let lock = NSLock()
    private var running = false

    public init(path: String) { self.executable = URL(fileURLWithPath: path) }

    public func dashboard() throws -> (snapshots: [QuotaProvider: QuotaSnapshot], errors: [QuotaProvider: String]) {
        let data = try run(["dashboard", "--timeout", "60", "--identity", "redacted"])
        return try CodexBarParser.dashboard(data, at: Date())
    }

    public func usage(_ provider: QuotaProvider) throws -> QuotaSnapshot {
        let data = try run(["usage", "--provider", provider.rawValue, "--json"])
        return try CodexBarParser.usage(data, at: Date())
    }

    public func cost(_ provider: QuotaProvider) throws -> [DailyCost] {
        let data = try run(["cost", "--provider", provider.rawValue, "--days", "30", "--breakdown", "--json"])
        return try CodexBarParser.cost(data)
    }

    public func sessions() throws -> [SessionActivity] {
        try CodexBarParser.sessions(run(["sessions", "--json-v2"]))
    }

    private func run(_ arguments: [String]) throws -> Data {
        lock.lock()
        guard !running else { lock.unlock(); throw CodexBarError.commandBusy }
        running = true
        lock.unlock()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() }
        catch {
            lock.lock(); running = false; lock.unlock()
            throw error
        }
        let output = OutputBox()
        let group = DispatchGroup()
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
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }
        guard group.wait(timeout: .now() + 60) == .success else {
            group.notify(queue: .global(qos: .utility)) { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.running = false; self.lock.unlock()
            }
            logger.error("CLI 命令超过 60 秒：\(arguments.first ?? "未知", privacy: .public)")
            throw CodexBarError.exceededDeadline
        }
        lock.lock(); running = false; lock.unlock()
        let (data, errors) = output.read()
        if !errors.isEmpty, let message = String(data: errors, encoding: .utf8) {
            logger.warning("CLI stderr：\(message, privacy: .private)")
        }
        guard process.terminationStatus == 0 else {
            logger.error("CLI 命令失败：\(arguments.first ?? "未知", privacy: .public)，退出码 \(process.terminationStatus)")
            throw CodexBarError.commandFailed(process.terminationStatus)
        }
        return data
    }
}
