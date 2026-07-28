import Foundation

// A small HTTP/1.1 server over a unix-domain socket (and, optionally, loopback
// TCP). Deliberately dependency-free: Zero ships as three static binaries and a
// menu-bar app, and adding a server framework to get ~15 local routes would be
// the wrong trade. Filesystem permissions on the socket are the auth story for
// the local case; the TCP listener requires a bearer token.

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public var bodyString: String { String(data: body, encoding: .utf8) ?? "" }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        Zero.decode(type, from: body)
    }

    public func q(_ name: String) -> String? {
        let v = query[name]
        return (v?.isEmpty ?? true) ? nil : v
    }

    public func flag(_ name: String) -> Bool? {
        guard let v = query[name]?.lowercased() else { return nil }
        if ["1", "true", "yes", "on"].contains(v) { return true }
        if ["0", "false", "no", "off"].contains(v) { return false }
        return nil
    }
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    /// When set, the connection is handed to this closure instead of being
    /// closed — that's how `GET /v1/events` becomes a live SSE stream.
    public var stream: ((SSEConnection) -> Void)?

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data(),
                stream: ((SSEConnection) -> Void)? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.stream = stream
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: ["Content-Type": "application/json"],
                     body: Zero.encode(value))
    }

    public static func error(_ message: String, status: Int = 400) -> HTTPResponse {
        .json(APIError(message), status: status)
    }

    public static func text(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data(s.utf8))
    }

    public static let noContent = HTTPResponse(status: 204)
}

/// A live server-sent-events connection.
public final class SSEConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    public let id = UUID()

    init(fd: Int32) { self.fd = fd }

    public var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed
    }

    @discardableResult
    public func send(event: String, data: Data) -> Bool {
        let payload = "event: \(event)\ndata: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
        return writeRaw(payload)
    }

    @discardableResult
    public func comment(_ s: String) -> Bool { writeRaw(": \(s)\n\n") }

    @discardableResult
    func writeRaw(_ s: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        let bytes = Array(s.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress, buf.count)
            }
            if n <= 0 {
                closed = true
                Darwin.close(fd)
                return false
            }
            offset += n
        }
        return true
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = Darwin.close(fd)
    }
}

public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    private let handler: Handler
    private var listeners: [Int32] = []
    private let queue = DispatchQueue(label: "zero.http", attributes: .concurrent)
    private var running = true
    private let token: String?

    public init(token: String? = nil, handler: @escaping Handler) {
        self.handler = handler
        self.token = token
    }

    // MARK: listeners

    public func listenUnix(path: String) throws {
        // Never unlink unconditionally. A socket file can mean one of two very
        // different things — a crashed daemon left it behind, or a live daemon
        // owns it — and blindly removing it lets a second daemon steal the
        // socket from a running one. Both then think they own the same runs.
        // Probe first: if something answers, refuse to start.
        if FileManager.default.fileExists(atPath: path) {
            if HTTPServer.isSocketAlive(path) { throw ServerError.alreadyRunning }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw ServerError.pathTooLong }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { close(fd); throw ServerError.bind(errno) }
        // Owner-only: the socket IS the authentication for local clients.
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else { close(fd); throw ServerError.listen(errno) }
        listeners.append(fd)
    }

    public func listenLoopback(port: Int) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian   // 127.0.0.1 only
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw ServerError.bind(errno) }
        guard listen(fd, 64) == 0 else { close(fd); throw ServerError.listen(errno) }
        listeners.append(fd)
    }

    // MARK: accept loop

    public func start() {
        for fd in listeners {
            queue.async { [weak self] in self?.acceptLoop(fd) }
        }
    }

    public func stop() {
        running = false
        for fd in listeners { close(fd) }
        listeners = []
    }

    private func acceptLoop(_ listenFD: Int32) {
        while running {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if !running { return }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        guard let request = readRequest(fd) else { close(fd); return }

        if let token, !token.isEmpty {
            let provided = request.headers["authorization"]?
                .replacingOccurrences(of: "Bearer ", with: "") ?? request.query["token"]
            if provided != token {
                writeResponse(fd, .error("unauthorized", status: 401))
                close(fd)
                return
            }
        }

        let response = handler(request)
        if let stream = response.stream {
            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: text/event-stream\r\n"
            head += "Cache-Control: no-cache\r\n"
            head += "Connection: keep-alive\r\n\r\n"
            _ = head.withCString { write(fd, $0, strlen($0)) }
            stream(SSEConnection(fd: fd))
            return   // ownership of fd passes to the SSE connection
        }
        writeResponse(fd, response)
        close(fd)
    }

    // MARK: parse / write

    private func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)

        // Headers first.
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if buffer.count > 1_048_576 { return nil }
        }
        guard let hdrEnd = headerEnd,
              let headerText = String(data: buffer[..<hdrEnd.lowerBound], encoding: .utf8)
        else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0].uppercased()
        let target = requestLine[1]

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Body.
        var body = Data(buffer[hdrEnd.upperBound...])
        if let lengthText = headers["content-length"], let length = Int(lengthText) {
            while body.count < length {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                body.append(contentsOf: chunk[0..<n])
            }
            if body.count > length { body = body.prefix(length) }
        }

        let (path, query) = HTTPServer.splitTarget(target)
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private func writeResponse(_ fd: Int32, _ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(HTTPServer.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(response.body)
        out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    // MARK: helpers

    public static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let qIndex = target.firstIndex(of: "?") else {
            return (percentDecode(target), [:])
        }
        let path = percentDecode(String(target[..<qIndex]))
        var query: [String: String] = [:]
        for pair in target[target.index(after: qIndex)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = percentDecode(parts[0].replacingOccurrences(of: "+", with: " "))
            let value = parts.count > 1
                ? percentDecode(parts[1].replacingOccurrences(of: "+", with: " "))
                : ""
            query[key] = value
        }
        return (path, query)
    }

    public static func percentDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        default:  return "Status"
        }
    }

    /// Can something be connected to at this socket path right now?
    static func isSocketAlive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    public enum ServerError: Error, CustomStringConvertible {
        case socket(Int32), bind(Int32), listen(Int32), pathTooLong, alreadyRunning

        public var description: String {
            switch self {
            case .socket(let e):   return "socket() failed: \(String(cString: strerror(e)))"
            case .bind(let e):     return "bind() failed: \(String(cString: strerror(e)))"
            case .listen(let e):   return "listen() failed: \(String(cString: strerror(e)))"
            case .pathTooLong:     return "socket path too long"
            case .alreadyRunning:  return "another ouroboros daemon already owns this socket"
            }
        }
    }
}
