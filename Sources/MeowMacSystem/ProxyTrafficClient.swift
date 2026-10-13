import Darwin
import Foundation
import TunCanarySystem

public protocol ProxyTrafficFetching {
    func fetchConnections() throws -> Data
}

/// 错误只包含类别和 errno，不包含控制接口路径或连接明细。
public enum ProxyTrafficClientError: Error, Equatable, LocalizedError {
    case unavailable, timedOut, invalidResponse, unsupportedEncoding, responseTooLarge
    case httpStatus(Int)
    case socketFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "未找到代理控制接口"
        case .timedOut: return "代理控制接口请求超时"
        case .invalidResponse: return "代理控制接口应答不完整或格式无效"
        case .unsupportedEncoding: return "代理控制接口应答使用了不支持的编码"
        case .responseTooLarge: return "代理控制接口应答超过 16 MB"
        case .httpStatus(let status): return "代理控制接口返回 HTTP \(status)"
        case .socketFailure(let code): return "代理控制接口读取失败（errno \(code)）"
        }
    }
}

/// 同步只读客户端；由采集协调器在后台队列调用。
public final class ProxyTrafficClient: ProxyTrafficFetching {
    public typealias SocketLocator = () throws -> String
    public typealias ResponseExchange = (String, Data) throws -> Data
    public static let responseLimit = 16 * 1024 * 1024
    private let socketLocator: SocketLocator
    private let now: () -> Date
    private let exchange: ResponseExchange?
    private let lock = NSLock()
    private var socketPath: String?
    private var retryAt: Date?

    public convenience init() {
        self.init(socketLocator: {
            switch MihomoController.locate() {
            case .success(let controller): return controller.socketPath
            case .failure: throw ProxyTrafficClientError.unavailable
            }
        })
    }

    /// exchange 只供离线夹具注入完整 HTTP 应答；实际请求使用非阻塞 unix socket。
    public init(socketLocator: @escaping SocketLocator, now: @escaping () -> Date = Date.init,
                exchange: ResponseExchange? = nil) {
        self.socketLocator = socketLocator
        self.now = now
        self.exchange = exchange
    }

    public func fetchConnections() throws -> Data { try fetch(path: "/connections") }
    public func fetchVersion() throws -> Data { try fetch(path: "/version") }

    private func fetch(path: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let date = now()
        if socketPath == nil {
            if let retryAt, date < retryAt { throw ProxyTrafficClientError.unavailable }
            do { socketPath = try socketLocator(); retryAt = nil }
            catch { retryAt = date.addingTimeInterval(60); throw ProxyTrafficClientError.unavailable }
        }
        guard let socketPath else { throw ProxyTrafficClientError.unavailable }
        let request = Data("GET \(path) HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n".utf8)
        do {
            if let exchange {
                var decoder = ProxyTrafficResponseDecoder()
                guard let body = try decoder.feed(exchange(socketPath, request), closed: true) else {
                    throw ProxyTrafficClientError.invalidResponse
                }
                return body
            }
            return try Self.readSocket(socketPath, request: request)
        } catch {
            self.socketPath = nil
            retryAt = now().addingTimeInterval(60)
            throw error
        }
    }

    private static func readSocket(_ path: String, request: Data) throws -> Data {
        // 使用单调时钟，连接、发送和全部读取共用一个五秒截止时间。
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyTrafficClientError.socketFailure(errno) }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw ProxyTrafficClientError.socketFailure(errno) }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw ProxyTrafficClientError.socketFailure(errno)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard !path.utf8.contains(0), path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ProxyTrafficClientError.unavailable
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else { throw ProxyTrafficClientError.socketFailure(errno) }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { throw ProxyTrafficClientError.socketFailure(errno) }
            guard socketError == 0 else { throw ProxyTrafficClientError.socketFailure(socketError) }
        }
        var sent = 0
        while sent < request.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: sent), request.count - sent, 0) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw ProxyTrafficClientError.socketFailure(errno)
            }
            guard count > 0 else { throw ProxyTrafficClientError.invalidResponse }
            sent += count
        }
        var decoder = ProxyTrafficResponseDecoder()
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw ProxyTrafficClientError.socketFailure(errno)
            }
            if let body = try decoder.feed(Data(bytes.prefix(max(0, count))), closed: count == 0) { return body }
        }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ProxyTrafficClientError.timedOut }
            var entry = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&entry, 1, Int32(max(1, ceil(remaining * 1000))))
            if result < 0 {
                if errno == EINTR { continue }
                throw ProxyTrafficClientError.socketFailure(errno)
            }
            if result == 0 { continue }
            guard entry.revents & Int16(POLLNVAL) == 0 else { throw ProxyTrafficClientError.socketFailure(EBADF) }
            return
        }
    }
}

private struct ProxyTrafficResponseDecoder {
    private enum Framing { case headers, length(Int), close, chunkSize, chunk(Int), trailers, complete }
    private var framing = Framing.headers
    private var buffer = Data()
    private var body = Data()
    private var received = 0
    private static let crlf = Data("\r\n".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)

    mutating func feed(_ data: Data, closed: Bool) throws -> Data? {
        guard data.count <= ProxyTrafficClient.responseLimit - received else { throw ProxyTrafficClientError.responseTooLarge }
        received += data.count
        buffer.append(data)
        while true {
            switch framing {
            case .headers:
                guard let end = buffer.range(of: Self.headerEnd) else {
                    guard buffer.count <= 64 * 1024 else { throw ProxyTrafficClientError.invalidResponse }
                    return try pending(closed)
                }
                guard end.lowerBound - buffer.startIndex <= 64 * 1024 else { throw ProxyTrafficClientError.invalidResponse }
                let header = Data(buffer[..<end.lowerBound])
                buffer.removeSubrange(..<end.upperBound)
                try parseHeaders(header)
            case .length(let count):
                let take = min(count, buffer.count)
                body.append(buffer.prefix(take))
                buffer.removeFirst(take)
                framing = count == take ? .complete : .length(count - take)
                if count != take { return try pending(closed) }
            case .close:
                body.append(buffer); buffer.removeAll(keepingCapacity: true)
                if closed { framing = .complete } else { return nil }
            case .chunkSize:
                guard let line = takeLine() else { return try pending(closed) }
                let number = line.split(separator: ";", omittingEmptySubsequences: false)[0]
                guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let size = Int(number, radix: 16) else { throw ProxyTrafficClientError.invalidResponse }
                guard size <= ProxyTrafficClient.responseLimit - body.count else { throw ProxyTrafficClientError.responseTooLarge }
                framing = size == 0 ? .trailers : .chunk(size)
            case .chunk(let count):
                guard buffer.count >= count + 2 else { return try pending(closed) }
                guard buffer.dropFirst(count).prefix(2) == Self.crlf else { throw ProxyTrafficClientError.invalidResponse }
                body.append(buffer.prefix(count)); buffer.removeFirst(count + 2)
                framing = .chunkSize
            case .trailers:
                guard let line = takeLine() else { return try pending(closed) }
                if line.isEmpty { framing = .complete }
                else { guard validHeader(line) != nil else { throw ProxyTrafficClientError.invalidResponse } }
            case .complete:
                guard buffer.isEmpty else { throw ProxyTrafficClientError.invalidResponse }
                return body
            }
        }
    }

    private func pending(_ closed: Bool) throws -> Data? {
        if closed { throw ProxyTrafficClientError.invalidResponse }
        return nil
    }

    private mutating func takeLine() -> String? {
        guard let end = buffer.range(of: Self.crlf) else { return nil }
        let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<end.upperBound)
        return line
    }

    private func validHeader(_ line: String) -> (String, String)? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let name = line[..<separator]
        let tokens = "!#$%&'*+-.^_`|~"
        guard !name.isEmpty, name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || tokens.utf8.contains($0) }) else { return nil }
        let value = line[line.index(after: separator)...]
        guard value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else { return nil }
        return (name.lowercased(), value.trimmingCharacters(in: .whitespaces))
    }

    private mutating func parseHeaders(_ data: Data) throws {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])),
              status[1].count == 3, status[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let code = Int(status[1]) else { throw ProxyTrafficClientError.invalidResponse }
        guard (200...299).contains(code) else { throw ProxyTrafficClientError.httpStatus(code) }
        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let (name, value) = validHeader(line) else { throw ProxyTrafficClientError.invalidResponse }
            headers[name, default: []].append(value)
        }
        if let encodings = headers["content-encoding"], encodings.contains(where: { $0.lowercased() != "identity" }) {
            throw ProxyTrafficClientError.unsupportedEncoding
        }
        if let transfers = headers["transfer-encoding"] {
            guard headers["content-length"] == nil else { throw ProxyTrafficClientError.invalidResponse }
            guard transfers.count == 1, transfers[0].lowercased() == "chunked" else { throw ProxyTrafficClientError.unsupportedEncoding }
            framing = .chunkSize
        } else if let lengths = headers["content-length"] {
            let values = lengths.flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }.map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = values.first, !first.isEmpty, values.allSatisfy({ $0 == first }),
                  first.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(first) else { throw ProxyTrafficClientError.invalidResponse }
            guard length <= ProxyTrafficClient.responseLimit else { throw ProxyTrafficClientError.responseTooLarge }
            framing = .length(length)
        } else { framing = .close }
    }
}
