import Foundation

/// The client every face uses. The CLI and the menu-bar app talk to `ourod`
/// through exactly this type and nothing else — which is the mechanical
/// enforcement of "the GUI has no private powers".
public final class ZeroClient: @unchecked Sendable {
    public let socketPath: String
    public let host: (String, Int)?
    public let token: String?

    public init(socketPath: String = Paths.socket, host: (String, Int)? = nil,
                token: String? = nil) {
        self.socketPath = socketPath
        self.host = host
        self.token = token
    }

    public struct Empty: Codable, Sendable { public init() {} }

    public enum ClientError: Error, CustomStringConvertible {
        case daemonDown
        case transport(String)
        case http(Int, String)
        case decode(String)

        public var description: String {
            switch self {
            case .daemonDown:            return "ouroboros daemon is not running (try: ouro daemon start)"
            case .transport(let m):      return m
            case .http(let code, let m): return "HTTP \(code): \(m)"
            case .decode(let m):         return "bad response: \(m)"
            }
        }
    }

    // MARK: connection

    private func connectSocket() throws -> Int32 {
        if let (h, port) = host {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ClientError.transport("socket() failed") }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr(h)
            let ok = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard ok == 0 else { close(fd); throw ClientError.daemonDown }
            return fd
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.transport("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            close(fd); throw ClientError.transport("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { close(fd); throw ClientError.daemonDown }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { throw ClientError.transport("write failed") }
                offset += n
            }
        }
    }

    private func requestData(_ method: String, _ path: String, body: Data?) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: ouroboros\r\n"
        head += "Accept: application/json\r\n"
        if let token, !token.isEmpty { head += "Authorization: Bearer \(token)\r\n" }
        if let body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
        } else {
            head += "Content-Length: 0\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        return out
    }

    // MARK: requests

    @discardableResult
    public func sendRaw(_ method: String, _ path: String, body: Data? = nil) throws -> (Int, Data) {
        let fd = try connectSocket()
        defer { close(fd) }
        try writeAll(fd, requestData(method, path, body: body))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let headText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8),
              let statusLine = headText.components(separatedBy: "\r\n").first
        else { throw ClientError.decode("malformed response") }
        let parts = statusLine.split(separator: " ")
        let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let responseBody = Data(buffer[headerEnd.upperBound...])
        return (status, responseBody)
    }

    public func call<R: Decodable>(_ method: String, _ path: String, bodyData: Data? = nil,
                                   as type: R.Type = R.self) throws -> R {
        let (status, data) = try sendRaw(method, path, body: bodyData)
        guard (200..<300).contains(status) else {
            let message = Zero.decode(APIError.self, from: data)?.error
                ?? String(data: data, encoding: .utf8) ?? "unknown"
            throw ClientError.http(status, message)
        }
        if R.self == Empty.self { return Empty() as! R }
        guard let decoded = Zero.decode(R.self, from: data) else {
            throw ClientError.decode(String(data: data, encoding: .utf8) ?? "empty")
        }
        return decoded
    }

    public func get<R: Decodable>(_ path: String, as type: R.Type = R.self) throws -> R {
        try call("GET", path, as: type)
    }

    public func post<B: Encodable, R: Decodable>(_ path: String, _ body: B,
                                                 as type: R.Type = R.self) throws -> R {
        try call("POST", path, bodyData: Zero.compactEncoder.encodeSafe(body), as: type)
    }

    public func post<R: Decodable>(_ path: String, as type: R.Type = R.self) throws -> R {
        try call("POST", path, as: type)
    }

    public func patch<B: Encodable, R: Decodable>(_ path: String, _ body: B,
                                                  as type: R.Type = R.self) throws -> R {
        try call("PATCH", path, bodyData: Zero.compactEncoder.encodeSafe(body), as: type)
    }

    public func delete<R: Decodable>(_ path: String, as type: R.Type = R.self) throws -> R {
        try call("DELETE", path, as: type)
    }

    public var isUp: Bool {
        (try? get("/v1/health", as: HealthDTO.self))?.ok ?? false
    }

    // MARK: streaming

    /// Follow `GET /v1/events`. `onEvent` returns false to stop. Blocking —
    /// callers run it on their own thread.
    public func stream(_ path: String, onEvent: @escaping (String, Data) -> Bool) throws {
        let fd = try connectSocket()
        defer { close(fd) }
        try writeAll(fd, requestData("GET", path, body: nil))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        var headersDone = false

        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])

            if !headersDone {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { continue }
                buffer = Data(buffer[end.upperBound...])
                headersDone = true
            }

            // Frames are separated by a blank line.
            while let sep = buffer.range(of: Data("\n\n".utf8)) {
                let frame = String(data: buffer[..<sep.lowerBound], encoding: .utf8) ?? ""
                buffer = Data(buffer[sep.upperBound...])
                var name = "message"
                var payload = ""
                for line in frame.components(separatedBy: "\n") {
                    if line.hasPrefix("event: ") { name = String(line.dropFirst(7)) }
                    if line.hasPrefix("data: ") { payload += String(line.dropFirst(6)) }
                    if line.hasPrefix(":") { continue }   // keep-alive comment
                }
                if payload.isEmpty && name == "message" { continue }
                if !onEvent(name, Data(payload.utf8)) { return }
            }
        }
    }
}

extension JSONEncoder {
    func encodeSafe<T: Encodable>(_ value: T) -> Data {
        (try? encode(value)) ?? Data("{}".utf8)
    }
}
