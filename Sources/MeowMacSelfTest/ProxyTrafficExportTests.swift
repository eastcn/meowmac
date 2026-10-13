import Foundation
import MeowMacCore
import MeowMacSystem
import MeowMacUI

@MainActor
enum ProxyTrafficExportTests {
    private static let manager = FileManager.default
    private static let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    private static let now = ProxyTrafficTime.parse("2026-10-13T18:00:00+08:00")!.addingTimeInterval(1800)

    static var tests: [(String, @MainActor () -> Bool)] {
        [
            ("Core.ProxyTraffic.ExportBackfillAndLargeDedup", backfillAndLargeDedup),
            ("Core.ProxyTraffic.ExportMissingParent", missingParent),
            ("Core.ProxyTraffic.ExportFailureKeepsLocalHistory", failureKeepsLocalHistory),
            ("Core.ProxyTraffic.ExportPermissionFailure", permissionFailure),
            ("Core.ProxyTraffic.ExportRetention", retention),
            ("Core.ProxyTraffic.ExportPartialLine", partialLine),
            ("ProxyTraffic.Export/启动补写和下次结算重试", sessionBackfillAndRetry),
            ("ProxyTraffic.Export/配置默认不导出与往返", configuration)
        ]
    }

    private static func temporary(_ body: (URL) throws -> Bool) -> Bool {
        let directory = URL(fileURLWithPath: "build/acceptance/proxy-export-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: directory) }
            return try body(directory)
        } catch { print("代理流量导出测试失败：\(error)"); return false }
    }

    private static func row(_ hour: String, up: Int64 = 10) -> ProxyTrafficRow {
        let bytes = ProxyTrafficBytes(up: up)
        return ProxyTrafficRow(hour: hour, coverageSeconds: 5, proxy: bytes, match: bytes,
            byProcess: [.init(process: "DemoBrowser", up: up, down: 0)],
            items: [.init(process: "DemoBrowser", host: "example.com", rule: "Match",
                          node: "DemoNode", group: "DemoGroup", up: up)])
    }

    private static func fails(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    private static func backfillAndLargeDedup() -> Bool {
        temporary { root in
            let directory = root.appendingPathComponent("mac", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            let first = row("2026-10-13T15:00:00+08:00", up: 11)
            var object = try JSONSerialization.jsonObject(with: first.encoded()) as! [String: Any]
            object["collector"] = "meowmac/" + String(repeating: "x", count: 270_000)
            var original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            original.append(10)
            let path = directory.appendingPathComponent("2026-10-13.jsonl")
            try original.write(to: path)
            let rows = [row("2026-09-12T15:00:00+08:00"), row("2026-09-13T15:00:00+08:00", up: 7),
                        row("2026-10-13T15:00:00+08:00", up: 999), row("2026-10-13T16:00:00+08:00", up: 22),
                        row("2026-10-13T18:00:00+08:00"), row("2026-10-13T19:00:00+08:00")]
            let exporter = ProxyTrafficExporter(root: root, timeZone: zone)
            try exporter.synchronize(rows: rows, now: now)
            let exported = try ProxyTrafficFiles.load(directory: directory, now: now, timeZone: zone)
            guard original.count > 256 * 1024, exported.count == 3,
                  exported.map(\.proxy.up) == [7, 11, 22],
                  !manager.fileExists(atPath: directory.appendingPathComponent("2026-09-12.jsonl").path) else { return false }
            let bytes = try Data(contentsOf: path)
            guard bytes.starts(with: original) else { return false }
            let boundary = directory.appendingPathComponent("2026-09-13.jsonl")
            let boundaryBytes = try Data(contentsOf: boundary)
            try exporter.synchronize(rows: rows, now: now)
            let names = try manager.contentsOfDirectory(atPath: directory.path).sorted()
            return try Data(contentsOf: path) == bytes && Data(contentsOf: boundary) == boundaryBytes &&
                names == ["2026-09-13.jsonl", "2026-10-13.jsonl"]
        }
    }

    private static func missingParent() -> Bool {
        temporary { directory in
            let parent = directory.appendingPathComponent("not-created", isDirectory: true)
            let root = parent.appendingPathComponent("nested", isDirectory: true)
            let exporter = ProxyTrafficExporter(root: root, timeZone: zone)
            return fails({ try exporter.synchronize(rows: [row("2026-10-13T15:00:00+08:00")], now: now) }) &&
                !manager.fileExists(atPath: parent.path)
        }
    }

    private static func failureKeepsLocalHistory() -> Bool {
        temporary { directory in
            let local = ProxyTrafficStore(directory: directory.appendingPathComponent("local", isDirectory: true), timeZone: zone)
            let root = directory.appendingPathComponent("export", isDirectory: true)
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            let obstruction = root.appendingPathComponent("mac")
            let sentinel = Data("keep this file".utf8)
            try sentinel.write(to: obstruction)
            let exporter = ProxyTrafficExporter(root: root, timeZone: zone)
            let first = row("2026-10-13T15:00:00+08:00", up: 11)
            let second = row("2026-10-13T16:00:00+08:00", up: 22)
            try local.append(first)
            guard fails({ try exporter.synchronize(rows: local.loadRows(now: now), now: now) }) else { return false }
            try local.append(second)
            let localRows = try local.loadRows(now: now)
            guard localRows.map(\.proxy.up) == [11, 22], try Data(contentsOf: obstruction) == sentinel else { return false }
            // 导出恢复可补上失败期间的本地行；不需丢弃或重建本地历史。
            try manager.removeItem(at: obstruction)
            try exporter.synchronize(rows: localRows, now: now)
            let exported = try ProxyTrafficFiles.load(directory: root.appendingPathComponent("mac"), now: now, timeZone: zone)
            return exported == localRows
        }
    }

    private static func permissionFailure() -> Bool {
        temporary { root in
            let directory = root.appendingPathComponent("mac", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            var reports: [String: Int] = [:]
            let exporter = ProxyTrafficExporter(root: root, timeZone: zone) { reports[$0, default: 0] += $1 }
            let sample = row("2026-10-13T15:00:00+08:00")
            let denied = fails { try exporter.synchronize(rows: [sample], now: now) }
            if denied {
                return reports["export_append_failed"] == 1 &&
                    !manager.fileExists(atPath: directory.appendingPathComponent("2026-10-13.jsonl").path)
            }
            // root 等特权环境可能绕过 chmod，改用路径为文件的确定障碍验失败行为。
            print("当前环境允许写入无写权限目录，导出失败验收改用 mac 路径为普通文件的确定障碍")
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try manager.removeItem(at: directory)
            let sentinel = Data("permission fallback".utf8)
            try sentinel.write(to: directory)
            return try fails({ try exporter.synchronize(rows: [sample], now: now) }) && Data(contentsOf: directory) == sentinel
        }
    }

    private static func retention() -> Bool {
        temporary { root in
            let directory = root.appendingPathComponent("mac", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            let old = "2026-09-12.jsonl"
            let preserved = ["2026-09-13.jsonl", "README.md", "2026-01-01.txt", "2026-02-30.jsonl"]
            let sentinel = Data("retention sentinel".utf8)
            for name in [old] + preserved { try sentinel.write(to: directory.appendingPathComponent(name)) }
            let subdirectory = directory.appendingPathComponent("2026-01-02.jsonl", isDirectory: true)
            try manager.createDirectory(at: subdirectory, withIntermediateDirectories: false)
            let link = directory.appendingPathComponent("2026-01-03.jsonl")
            try manager.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("README.md"))
            try ProxyTrafficExporter(root: root, timeZone: zone).synchronize(rows: [], now: now)
            guard !manager.fileExists(atPath: directory.appendingPathComponent(old).path),
                  manager.fileExists(atPath: subdirectory.path), manager.fileExists(atPath: link.path) else { return false }
            for name in preserved { guard try Data(contentsOf: directory.appendingPathComponent(name)) == sentinel else { return false } }
            return true
        }
    }

    private final class Client: ProxyTrafficFetching {
        func fetchConnections() throws -> Data {
            Data(#"{"connections":[],"uploadTotal":0,"downloadTotal":0}"#.utf8)
        }
    }
    private static func sessionBackfillAndRetry() -> Bool {
        temporary { directory in
            let local = ProxyTrafficStore(directory: directory.appendingPathComponent("local"), timeZone: zone)
            let first = row("2026-10-13T15:00:00+08:00", up: 11)
            try local.append(first)
            let root = directory.appendingPathComponent("export")
            var events: [String] = []
            var time = now
            let session = try ProxyTrafficSession(store: local, client: Client(), exporter: ProxyTrafficExporter(root: root, timeZone: zone),
                timeZone: zone, clock: { time }, report: { events.append($0) })
            guard events.contains("export_failed"), try local.loadRows(now: time) == [first],
                  !manager.fileExists(atPath: root.path) else { return false }
            // 导出失败不影响本地采样。父目录恢复后，下一次结算同时补上旧小时。
            session.sample()
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            time = ProxyTrafficTime.parse("2026-10-13T19:00:00+08:00")!
            session.sample()
            let exported = try ProxyTrafficFiles.load(directory: root.appendingPathComponent("mac"), now: time, timeZone: zone)
            let localRows = try local.loadRows(now: time)
            guard exported == localRows, exported.count == 2, exported.first == first else { return false }
            // 首次启用时已有本地历史，也立即走生产 Session 路径补写。
            let secondRoot = directory.appendingPathComponent("first-enable")
            try manager.createDirectory(at: secondRoot, withIntermediateDirectories: false)
            _ = try ProxyTrafficSession(store: local, client: Client(), enabled: false,
                exporter: ProxyTrafficExporter(root: secondRoot, timeZone: zone), timeZone: zone, clock: { time })
            return try ProxyTrafficFiles.load(directory: secondRoot.appendingPathComponent("mac"), now: time, timeZone: zone) == localRows
        }
    }
    private static func configuration() -> Bool {
        do {
            let old = try JSONDecoder().decode(LocalConfig.self, from: Data("{}".utf8))
            guard old.proxyTrafficExportDirectory.isEmpty, old.proxyTrafficEnabled else { return false }
            var config = LocalConfig(); config.proxyTrafficExportDirectory = "/demo/export"
            return try JSONDecoder().decode(LocalConfig.self, from: JSONEncoder().encode(config)) == config
        } catch { return false }
    }
    private static func partialLine() -> Bool {
        temporary { root in
            let directory = root.appendingPathComponent("mac", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            let path = directory.appendingPathComponent("2026-10-13.jsonl")
            let partial = Data("{unfinished".utf8)
            try partial.write(to: path)
            let exporter = ProxyTrafficExporter(root: root, timeZone: zone)
            let sample = row("2026-10-13T15:00:00+08:00", up: 17)
            try exporter.synchronize(rows: [sample], now: now)
            let bytes = try Data(contentsOf: path)
            guard bytes.starts(with: partial + Data([10])), bytes.last == 10 else { return false }
            var reports: [String: Int] = [:]
            let rows = ProxyTrafficFiles.decode(bytes, day: "2026-10-13") { reports[$0, default: 0] += $1 }
            guard rows == [sample], reports == ["invalid_history_rows": 1] else { return false }
            try exporter.synchronize(rows: [sample], now: now)
            return try Data(contentsOf: path) == bytes
        }
    }
}
