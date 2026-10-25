import Darwin
import Foundation
import MeowMacSystem

@MainActor
func proxyTrafficClientTests() -> [(String, @MainActor () -> Bool)] {
    [
        ("System.ProxyTrafficClient/固定只读请求与复用定位", {
            var requests: [String] = [], locations = 0
            let client = ProxyTrafficClient(socketLocator: { locations += 1; return "fixture.sock" }, exchange: { _, request in
                requests.append(String(decoding: request, as: UTF8.self))
                return Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
            })
            return (try? client.fetchConnections()) == Data("{}".utf8)
                && (try? client.fetchVersion()) == Data("{}".utf8) && locations == 1
                && requests.count == 2 && requests[0].hasPrefix("GET /connections HTTP/1.1\r\n")
                && requests[1].hasPrefix("GET /version HTTP/1.1\r\n")
                && requests.allSatisfy { $0.hasSuffix("\r\n\r\n") && $0.contains("Connection: close\r\n") }
        }),
        ("System.ProxyTrafficClient/Content-Length与关闭定界", {
            let responses = ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
                             "HTTP/1.0 200 OK\r\n\r\n{}", "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"]
            return proxyClientBody(responses[0]) == Data("{}".utf8)
                && proxyClientBody(responses[1]) == Data("{}".utf8)
                && proxyClientBody(responses[2]) == Data()
        }),
        ("System.ProxyTrafficClient/chunked扩展与尾部", {
            proxyClientBody("HTTP/1.1 200 OK\r\nTransfer-Encoding: Chunked\r\n\r\n1;fixture=yes\r\n{\r\n1\r\n}\r\n0\r\nX-Fixture: complete\r\n\r\n") == Data("{}".utf8)
        }),
        ("System.ProxyTrafficClient/截断与不合法应答负控", {
            let invalid = [
                "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}",
                "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n{}",
                "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}",
                "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}xx0\r\n\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n",
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\n{}\r\n0\r\n\r\n",
                "not-http 200 OK\r\n\r\n{}", "HTTP/1.1 200 OK\r\nBroken-Header\r\n\r\n{}"
            ]
            return invalid.allSatisfy { proxyClientError(Data($0.utf8)) == .invalidResponse }
        }),
        ("System.ProxyTrafficClient/拒绝编码与非成功状态", {
            proxyClientError(Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n{}".utf8)) == .unsupportedEncoding
                && proxyClientError(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n".utf8)) == .unsupportedEncoding
                && proxyClientError(Data("HTTP/1.1 503 Unavailable\r\nContent-Length: 2\r\n\r\n{}".utf8)) == .httpStatus(503)
        }),
        ("System.ProxyTrafficClient/16MB上限", {
            let oversized = Data(repeating: 65, count: ProxyTrafficClient.responseLimit + 1)
            let announced = Data("HTTP/1.1 200 OK\r\nContent-Length: 16777217\r\n\r\n".utf8)
            let chunked = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1000001\r\n".utf8)
            return proxyClientError(oversized) == .responseTooLarge && proxyClientError(announced) == .responseTooLarge
                && proxyClientError(chunked) == .responseTooLarge
        }),
        ("System.ProxyTrafficClient/定位失败60秒恢复", {
            var date = Date(timeIntervalSince1970: 1_000_000), locations = 0
            let client = ProxyTrafficClient(socketLocator: {
                locations += 1
                if locations == 1 { throw ProxyTrafficClientError.unavailable }
                return "fixture.sock"
            }, now: { date }, exchange: { _, _ in Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8) })
            guard (try? client.fetchConnections()) == nil, locations == 1 else { return false }
            date.addTimeInterval(59)
            guard (try? client.fetchConnections()) == nil, locations == 1 else { return false }
            date.addTimeInterval(1)
            return (try? client.fetchConnections()) == Data("{}".utf8) && locations == 2
        }),
        ("System.ProxyTrafficClient/已定位读取失败后重定位", {
            var date = Date(timeIntervalSince1970: 1_000_000), locations = 0, paths: [String] = []
            let client = ProxyTrafficClient(socketLocator: { locations += 1; return "fixture-\(locations).sock" }, now: { date }, exchange: { path, _ in
                paths.append(path)
                if paths.count == 1 { throw ProxyTrafficClientError.socketFailure(ECONNRESET) }
                return Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)
            })
            guard (try? client.fetchConnections()) == nil else { return false }
            date.addTimeInterval(59)
            guard (try? client.fetchConnections()) == nil, locations == 1, paths.count == 1 else { return false }
            date.addTimeInterval(1)
            return (try? client.fetchConnections()) == Data("{}".utf8) && paths == ["fixture-1.sock", "fixture-2.sock"] && locations == 2
        }),
        ("System.ProxyTrafficClient/假socket分段应答", {
            proxySocketFixtureTest(parts: ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "2\r", "\n{}\r\n0\r\n", "\r\n"], expected: Data("{}".utf8))
                && proxySocketFixtureTest(parts: ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{", "}"], expected: Data("{}".utf8))
                && proxySocketFixtureTest(parts: ["HTTP/1.0 200 OK\r\n\r\n{}"], expected: Data("{}".utf8))
        }),
        ("System.ProxyTrafficClient/假socket截断拒绝", {
            proxySocketFixtureTest(parts: ["HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n{}"], expectedError: .invalidResponse)
        }),
        ("System.ProxyTrafficClient/整次请求五秒截止", {
            let start = ProcessInfo.processInfo.systemUptime
            let correct = proxySocketFixtureTest(parts: ["HTTP/1.1 200 OK\r\n\r\n", "a", "b", "c", "d", "e", "f"], pause: 1, expectedError: .timedOut)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            return correct && elapsed >= 4.8 && elapsed < 7
        })
    ]
}

private func proxyClientBody(_ response: String) -> Data? {
    let client = ProxyTrafficClient(socketLocator: { "fixture.sock" }, exchange: { _, _ in Data(response.utf8) })
    return try? client.fetchConnections()
}

private func proxyClientError(_ response: Data) -> ProxyTrafficClientError? {
    let client = ProxyTrafficClient(socketLocator: { "fixture.sock" }, exchange: { _, _ in response })
    do { _ = try client.fetchConnections(); return nil }
    catch { return error as? ProxyTrafficClientError }
}

/// 只在 build/ 内创建虚构 socket，服务器自行结束，不操作真实代理服务。
private func proxySocketFixtureTest(parts: [String], pause: TimeInterval = 0,
                                    expected: Data? = nil, expectedError: ProxyTrafficClientError? = nil) -> Bool {
    // 用相对 cwd 的路径，长度不随仓库所在目录变化；绝对路径在较深的 worktree 里会超过 sun_path 的 104 字节。
    let directory = URL(fileURLWithPath: "build")
    let path = "build/pt-\(UUID().uuidString.prefix(8)).sock"
    guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return false }
    let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { return false }
    defer { Darwin.close(listener); try? FileManager.default.removeItem(atPath: path) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, Darwin.listen(listener, 1) == 0 else { return false }
    let finished = DispatchGroup()
    finished.enter()
    DispatchQueue.global(qos: .utility).async {
        defer { finished.leave() }
        var pollEntry = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&pollEntry, 1, 6000) > 0 else { return }
        let peer = Darwin.accept(listener, nil, nil)
        guard peer >= 0 else { return }
        defer { Darwin.close(peer) }
        var noSignal: Int32 = 1
        _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = Darwin.recv(peer, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            request.append(contentsOf: buffer.prefix(count))
        }
        guard request.starts(with: Data("GET /connections HTTP/1.1\r\n".utf8)) else { return }
        for part in parts {
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            let data = Data(part.utf8)
            var sent = 0
            while sent < data.count {
                let count = data.withUnsafeBytes { Darwin.send(peer, $0.baseAddress!.advanced(by: sent), data.count - sent, 0) }
                guard count > 0 else { return }
                sent += count
            }
        }
    }
    let client = ProxyTrafficClient(socketLocator: { path })
    var result = false
    do { result = try client.fetchConnections() == expected && expectedError == nil }
    catch { result = (error as? ProxyTrafficClientError) == expectedError && expectedError != nil }
    return finished.wait(timeout: .now() + 8) == .success && result
}
