import Foundation
import MeowMacCore
import MeowMacQuota

enum CodexBarProcessTests {
    static let payload = #"[{"provider":"codex","usage":{"primary":{"usedPercent":25,"windowMinutes":300}}}]"#

    static func write(_ script: URL, body: String) throws {
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }

    static func withCLI(_ body: (URL) async throws -> Bool) async -> Bool {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/acceptance/quota-process-tests/\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            return try await body(root.appendingPathComponent("cli.sh"))
        } catch { print("真实进程夹具失败：\(error)"); return false }
    }

    /// 走真实子进程和管道，不用 Executor 替代进程退出通知。
    static func repeatedExit() async -> Bool {
        await withCLI { script in
            try write(script, body: "printf '%s\\n' '\(payload)'")
            let client = CodexBarClient(path: script.path, deadlineSeconds: 2)
            for iteration in 0..<100 {
                let result = await Task.detached { Result { try client.usage(.codex) } }.value
                switch result {
                case .success(let snapshot):
                    guard snapshot.provider == .codex, snapshot.windows.first?.usedPercent == 25 else { return false }
                case .failure(let error):
                    print("真实进程第 \(iteration + 1) 次采集失败：\(error)")
                    return false
                }
            }
            return true
        }
    }

    static func failedLaunch() async -> Bool {
        await withCLI { script in
            let client = CodexBarClient(path: script.path, deadlineSeconds: 2)
            let failure = await Task.detached { Result { try client.usage(.codex) } }.value
            guard case .failure(let error) = failure, !(error is CodexBarError) else { return false }
            try write(script, body: "printf '%s\\n' '\(payload)'")
            return await Task.detached { (try? client.usage(.codex))?.windows.first?.usedPercent == 25 }.value
        }
    }

    static func largeOutputAndFailure() async -> Bool {
        await withCLI { script in
            try write(script, body: """
            printf '%131072s' ''
            printf '%131072s' '' >&2
            printf '%s\\n' '\(payload)'
            exit 7
            """)
            var stdoutBytes = 0, stderrBytes = 0
            let client = CodexBarClient(path: script.path, deadlineSeconds: 2, rawOutput: { _, output, errors in
                stdoutBytes = output.count; stderrBytes = errors.count
            })
            let failure = await Task.detached { Result { try client.usage(.codex) } }.value
            guard case .failure(CodexBarError.commandFailed(7)) = failure,
                  stdoutBytes == 131072 + payload.utf8.count + 1, stderrBytes == 131072 else { return false }
            try write(script, body: "printf '%s\\n' '\(payload)'")
            return await Task.detached { (try? client.usage(.codex))?.windows.first?.usedPercent == 25 }.value
        }
    }

    static func timeoutRecovery() async -> Bool {
        await withCLI { script in
            let marker = script.deletingLastPathComponent().appendingPathComponent("started")
            try write(script, body: """
            if [ ! -f "$MEOWMAC_TEST_STARTED" ]; then
                : > "$MEOWMAC_TEST_STARTED"
                /bin/sleep 0.5
            fi
            printf '%s\\n' '\(payload)'
            """)
            let client = CodexBarClient(path: script.path, environment: ["MEOWMAC_TEST_STARTED": marker.path], deadlineSeconds: 0.2)
            let first = Task.detached { Result { try client.usage(.codex) } }
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: marker.path) { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard FileManager.default.fileExists(atPath: marker.path) else { _ = await first.value; return false }
            let concurrent = await Task.detached { Result { try client.usage(.codex) } }.value
            guard case .failure(CodexBarError.commandBusy) = concurrent else { _ = await first.value; return false }
            guard case .failure(CodexBarError.exceededDeadline) = await first.value else { return false }
            let afterTimeout = await Task.detached { Result { try client.usage(.codex) } }.value
            guard case .failure(CodexBarError.commandBusy) = afterTimeout else { return false }
            // 让合成命令自己退出，不结束任何进程。
            try await Task.sleep(nanoseconds: 700_000_000)
            return await Task.detached { (try? client.usage(.codex))?.windows.first?.usedPercent == 25 }.value
        }
    }

    static func configInputPrivacy() async -> Bool {
        await withCLI { script in
            let syntheticKey = "synthetic-" + UUID().uuidString
            try write(script, body: """
            IFS= read -r received
            [ "$received" = "$MEOWMAC_TEST_INPUT" ] || exit 9
            printf '%s' "$received"
            printf '%s' "$received" >&2
            """)
            var callbacks = 0
            let client = CodexBarClient(path: script.path,
                environment: ["CODEXBAR_CONFIG": script.deletingLastPathComponent().appendingPathComponent("config.json").path,
                              "MEOWMAC_TEST_INPUT": syntheticKey],
                deadlineSeconds: 2, rawOutput: { _, _, _ in callbacks += 1 })
            let result = await Task.detached { Result { try client.setAPIKey(syntheticKey, provider: .opencodego) } }.value
            guard case .success = result else { return false }
            return callbacks == 0
        }
    }

    /// 显式开启才调用真实 CLI；只输出采集结论，不写历史或配置。
    static func liveUsage() async -> Bool {
        await Task.detached {
            do {
                let loaded = ConfigStore.load()
                guard loaded.error == nil else { return false }
                let config = loaded.config
                let client = CodexBarClient(path: config.codexBarCLIPath)
                let enabled = Set(try client.providers().filter(\.enabled).map(\.provider))
                let providers = QuotaSourceStore().load().list.providers.filter { enabled.contains($0) }
                guard !providers.isEmpty else { return false }
                var succeeded = true
                for provider in providers {
                    do {
                        let snapshot = try client.usage(provider)
                        let valid = snapshot.provider == provider && (!snapshot.windows.isEmpty || snapshot.balance != nil)
                        print("本机额度 \(provider.rawValue)：\(valid ? "成功" : "数据不完整")")
                        succeeded = succeeded && valid
                    } catch {
                        print("本机额度 \(provider.rawValue)：\(error.localizedDescription)")
                        succeeded = false
                    }
                }
                return succeeded
            } catch { print("本机额度启动失败：\(error.localizedDescription)"); return false }
        }.value
    }
}
