import Foundation
import MeowMacCore
import MeowMacSystem
import MeowMacUI

@MainActor
enum ProxyTrafficSessionTests {
    static let tests: [(String, @MainActor () -> Bool)] = [
        ("ProxyTraffic.Runtime/配置默认与关闭不读接口", disabled),
        ("ProxyTraffic.Runtime/失败恢复与睡眠覆盖断档", interruptions),
        ("ProxyTraffic.Runtime/检查点失败阻止追加和写盘重试", persistence),
        ("ProxyTraffic.Runtime/五分钟与退出检查点", checkpoints),
        ("ProxyTraffic.Runtime/损坏检查点拒绝启动且不覆盖", corrupt),
        ("ProxyTraffic.Live/只读真实接口与行格式", live),
    ]
    private static let start = ISO8601DateFormatter().date(from: "2026-10-13T15:00:00+08:00")!
    private static let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    private enum Failure: Error { case synthetic }
    private final class Client: ProxyTrafficFetching {
        var reads = 0, fail = false, up: Int64 = 0
        func fetchConnections() throws -> Data {
            reads += 1
            if fail { throw Failure.synthetic }
            return Data("{\"uploadTotal\":\(up),\"downloadTotal\":0,\"connections\":[{\"id\":\"demo\",\"upload\":\(up),\"download\":0,\"metadata\":{\"process\":\"DemoBrowser\",\"host\":\"example.com\"},\"chains\":[\"DemoNode\",\"DemoGroup\"],\"rule\":\"Match\"}]}".utf8)
        }
    }
    private final class Store: ProxyTrafficStoring {
        var checkpoint: Data?, rows: [ProxyTrafficRow] = []
        var saves = 0, appends = 0, failSave = false, failAppend = false
        func loadCheckpoint() throws -> Data? { checkpoint }
        func saveCheckpoint(_ data: Data) throws { saves += 1; if failSave { throw Failure.synthetic }; checkpoint = data }
        func append(_ row: ProxyTrafficRow) throws {
            appends += 1
            if failAppend { throw Failure.synthetic }
            if !rows.contains(where: { $0.hour == row.hour }) { rows.append(row) }
        }
        func loadRows(now: Date) throws -> [ProxyTrafficRow] { rows }
        func trim(now: Date) throws {}
    }
    private static func disabled() -> Bool {
        do {
            let old = try JSONDecoder().decode(LocalConfig.self, from: Data("{}".utf8))
            let off = try JSONDecoder().decode(LocalConfig.self, from: Data(#"{"proxyTrafficEnabled":false}"#.utf8))
            guard old.proxyTrafficEnabled, !off.proxyTrafficEnabled else { return false }
            let client = Client(), store = Store()
            let session = try ProxyTrafficSession(store: store, client: client, enabled: false, timeZone: zone, clock: { start })
            session.sample(); session.sample()
            guard client.reads == 0, try !session.viewData().enabled else { return false }
            session.setEnabled(true); session.sample()
            session.setEnabled(false); session.sample()
            return client.reads == 1 && store.checkpoint != nil
        } catch { return false }
    }
    private static func interruptions() -> Bool {
        do {
            var now = start
            let client = Client(), store = Store()
            let session = try ProxyTrafficSession(store: store, client: client, timeZone: zone, clock: { now })
            session.sample()
            now = start.addingTimeInterval(5); client.fail = true; session.sample()
            now = start.addingTimeInterval(10); client.fail = false; client.up = 10; session.sample()
            now = start.addingTimeInterval(15); client.up = 20; session.sample()
            guard let first = try session.viewData().rows.first, first.coverageSeconds == 5,
                  first.proxy.up == 20, session.readFailures == 1, session.available else { return false }
            session.sleep(); let count = client.reads
            now = start.addingTimeInterval(600); session.sample()
            guard client.reads == count else { return false }
            session.wake(); client.up = 25; session.sample()
            guard try session.viewData().rows.first?.coverageSeconds == 5 else { return false }
            now = start.addingTimeInterval(605); client.up = 30; session.sample()
            guard try session.viewData().rows.first?.coverageSeconds == 10 else { return false }
            now = start.addingTimeInterval(610); client.up = 3; session.sample()
            let restarted = try session.viewData().rows.first
            return restarted?.coreRestarts == 1 && restarted?.proxy.up == 33 && restarted?.coverageSeconds == 15
        } catch { return false }
    }
    private static func persistence() -> Bool {
        do {
            var now = start
            let client = Client(), store = Store(); var events: [String] = []
            let session = try ProxyTrafficSession(store: store, client: client, timeZone: zone, clock: { now }, report: { events.append($0) })
            session.sample(); now = start.addingTimeInterval(5); client.up = 10; session.sample()
            store.failSave = true; now = start.addingTimeInterval(3600); client.up = 20; session.sample()
            guard store.appends == 0, events.contains("settlement_checkpoint_failed") else { return false }
            store.failSave = false; store.failAppend = true
            now = start.addingTimeInterval(3605); client.up = 25; session.sample()
            guard store.rows.isEmpty, let data = store.checkpoint,
                  try ProxyTrafficAccumulator(checkpoint: data, timeZone: zone).rows().count == 2 else { return false }
            store.failAppend = false; now = start.addingTimeInterval(3610); client.up = 30; session.sample()
            guard store.rows.count == 1, store.rows[0].proxy.up == 10, events.contains("append_failed") else { return false }
            // 恢复同一检查点：日文件已经有第一小时，不能重复追加或计数。
            let resumed = try ProxyTrafficSession(store: store, client: client, timeZone: zone, clock: { now })
            resumed.sample()
            return try store.rows.count == 1 && resumed.viewData().rows.reduce(Int64(0)) { $0 + $1.proxy.up } == 30
        } catch { return false }
    }
    private static func checkpoints() -> Bool {
        do {
            var now = start
            let client = Client(), store = Store()
            let session = try ProxyTrafficSession(store: store, client: client, timeZone: zone, clock: { now })
            session.sample(); guard store.saves == 1 else { return false }
            now = start.addingTimeInterval(5); client.up = 10; session.sample()
            guard store.saves == 1 else { return false }
            now = start.addingTimeInterval(300); client.up = 20; session.sample()
            guard store.saves == 2 else { return false }
            session.stop()
            guard store.saves == 3, let checkpoint = store.checkpoint else { return false }
            let resumed = try ProxyTrafficAccumulator(checkpoint: checkpoint, timeZone: zone)
            return try resumed.rows().first?.proxy.up == 20
        } catch { return false }
    }
    private static func corrupt() -> Bool {
        let store = Store(), client = Client(); let broken = Data("broken".utf8); store.checkpoint = broken
        do { _ = try ProxyTrafficSession(store: store, client: client, timeZone: zone, clock: { start }); return false }
        catch { return store.checkpoint == broken && store.saves == 0 && client.reads == 0 }
    }
    private static func live() -> Bool {
        do {
            let data = try ProxyTrafficClient().fetchConnections()
            let snapshot = try ProxyTrafficSnapshot.parse(data)
            var accumulator = ProxyTrafficAccumulator()
            try accumulator.accept(snapshot, at: Date())
            guard let row = try accumulator.rows().first else { return false }
            let decoded = try ProxyTrafficRow.decode(row.encoded())
            print("代理流量实测：连接数 \(snapshot.connectionCount)，行键校验通过")
            return snapshot.connectionCount > 0 && decoded == row && row.bySrc.isEmpty
        } catch { print("代理流量实测失败：\(error)"); return false }
    }
}
