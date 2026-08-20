import Foundation

/// What Ouroboros did, one JSON object per line.
///
/// The rule that keeps this useful: **one event, one line, one sentence.** If a
/// line needs a paragraph to explain it, the paragraph belongs in `detail`, not
/// in `message`. You should be able to read 333 of these and know what the
/// machine has been doing without expanding a single one.
public struct LogEvent: Codable, Sendable, Identifiable, Equatable {
    /// Monotonic and human-typable, so `ouro logs around -id 412` is a real
    /// thing you can do from what you just read on screen.
    public var id: Int
    public var ts: Date
    public var level: LogLevel
    /// Dotted kind: `run.queued`, `merge.failed`, `verify.passed`. Stable
    /// enough to grep and to filter on.
    public var event: String
    public var message: String

    public var project: String?
    public var run: String?
    public var issue: String?
    public var path: String?
    public var branch: String?
    public var agent: String?
    /// The agent's own session/transcript id when the harness reports one, so a
    /// line here can be traced back to the actual conversation.
    public var session: String?
    public var durationMs: Int?
    public var exitCode: Int32?
    /// Anything else worth keeping, flattened to strings so the shape never
    /// breaks a reader.
    public var detail: [String: String]?

    public init(id: Int = 0, ts: Date = Date(), level: LogLevel = .info, event: String,
                message: String, project: String? = nil, run: String? = nil,
                issue: String? = nil, path: String? = nil, branch: String? = nil,
                agent: String? = nil, session: String? = nil, durationMs: Int? = nil,
                exitCode: Int32? = nil, detail: [String: String]? = nil) {
        self.id = id
        self.ts = ts
        self.level = level
        self.event = event
        self.message = message
        self.project = project
        self.run = run
        self.issue = issue
        self.path = path
        self.branch = branch
        self.agent = agent
        self.session = session
        self.durationMs = durationMs
        self.exitCode = exitCode
        self.detail = detail
    }
}

public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug, info, warn, error

    var rank: Int {
        switch self {
        case .debug: return 0
        case .info:  return 1
        case .warn:  return 2
        case .error: return 3
        }
    }

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

/// Append-only JSONL at `~/.ouroboros/log.jsonl`, with one rotation.
///
/// Deliberately not a database and deliberately not the daemon's stderr: the
/// log has to survive a daemon restart, be readable while the daemon is down,
/// and be greppable with the tools you already have. A file does all three.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = NSLock()
    private var nextID: Int = 1
    private var loaded = false
    /// Rotate at 8MB. Big enough that a week of ordinary use never trips it,
    /// small enough that reading the whole file stays cheap when it does.
    private let rotateBytes = 8 * 1024 * 1024

    private let overridePath: String?
    public var path: String { overridePath ?? Paths.logFile }
    public var previousPath: String { overridePath.map { $0 + ".1" } ?? Paths.logFilePrevious }
    /// Off for anything that must not touch the user's home.
    public var enabled = true

    /// `shared` writes to `~/.ouroboros/log.jsonl`. An explicit path makes the
    /// whole thing testable without a singleton fighting the test runner.
    public init(path: String? = nil) {
        self.overridePath = path
        // A test suite exercising the supervisor would otherwise scribble
        // "merged fix/thing into main" into the real activity log, which is both
        // wrong and confusing to read back six hours later. Explicit-path
        // instances still write, so the log's own tests keep working.
        if path == nil, Log.underTest { enabled = false }
    }

    /// The env vars Xcode sets are absent under `swift test`, so ask the
    /// runtime whether a test framework is loaded instead. That holds for both
    /// harnesses and cannot be true in the shipped binaries.
    public static var underTest: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["OUROBOROS_TESTING"] != nil
    }

    // MARK: - writing

    public func emit(_ event: LogEvent) {
        guard enabled else { return }
        lock.lock()
        if !loaded { nextID = lastID() + 1; loaded = true }
        var stamped = event
        stamped.id = nextID
        nextID += 1
        let line = Log.encoder.encodeLine(stamped)
        rotateIfNeededLocked()
        append(line)
        lock.unlock()
    }

    /// The call site every other file uses. Keyword-heavy on purpose: a log
    /// line with no project and no run is nearly useless six hours later.
    public func write(_ event: String, _ message: String, level: LogLevel = .info,
                      project: String? = nil, run: String? = nil, issue: String? = nil,
                      path: String? = nil, branch: String? = nil, agent: String? = nil,
                      session: String? = nil, durationMs: Int? = nil,
                      exitCode: Int32? = nil, detail: [String: String]? = nil) {
        emit(LogEvent(level: level, event: event, message: message, project: project,
                      run: run, issue: issue, path: path, branch: branch, agent: agent,
                      session: session, durationMs: durationMs, exitCode: exitCode,
                      detail: detail))
    }

    public func info(_ event: String, _ message: String, project: String? = nil,
                     run: String? = nil, detail: [String: String]? = nil) {
        write(event, message, level: .info, project: project, run: run, detail: detail)
    }

    public func warn(_ event: String, _ message: String, project: String? = nil,
                     run: String? = nil, detail: [String: String]? = nil) {
        write(event, message, level: .warn, project: project, run: run, detail: detail)
    }

    public func error(_ event: String, _ message: String, project: String? = nil,
                      run: String? = nil, detail: [String: String]? = nil) {
        write(event, message, level: .error, project: project, run: run, detail: detail)
    }

    private func append(_ line: String) {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
    }

    private func rotateIfNeededLocked() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > rotateBytes else { return }
        try? fm.removeItem(atPath: previousPath)
        try? fm.moveItem(atPath: path, toPath: previousPath)
    }

    // MARK: - reading

    public struct Query: Sendable {
        public var limit: Int = 333
        public var minLevel: LogLevel?
        public var project: String?
        public var run: String?
        /// Substring match against `event`, so `merge` catches `merge.failed`.
        public var event: String?
        public var search: String?
        public init() {}
    }

    /// Most recent first. Reads backwards, so a 300-line tail of an 8MB file
    /// touches a few kilobytes.
    public func recent(_ query: Query = Query()) -> [LogEvent] {
        var out: [LogEvent] = []
        for file in [path, previousPath] {
            let lines = Log.tailLines(path: file, maxLines: max(query.limit * 4, 2000))
            for line in lines.reversed() {
                guard let event = Log.decode(line), matches(event, query) else { continue }
                out.append(event)
                if out.count >= query.limit { return out }
            }
        }
        return out
    }

    /// `span` lines centred on `id`: half before, half after, oldest first —
    /// the order you want when you are reading around something that broke.
    public func around(id: Int, span: Int = 50) -> [LogEvent] {
        let half = max(1, span / 2)
        var all: [LogEvent] = []
        for file in [path, previousPath] {
            let lines = Log.tailLines(path: file, maxLines: 200_000)
            all.insert(contentsOf: lines.compactMap(Log.decode), at: 0)
            if all.contains(where: { $0.id == id }) { break }
        }
        guard let index = all.firstIndex(where: { $0.id == id }) else { return [] }
        let lower = max(0, index - half)
        let upper = min(all.count - 1, index + half)
        return Array(all[lower...upper])
    }

    public func get(id: Int) -> LogEvent? {
        around(id: id, span: 2).first { $0.id == id }
    }

    private func matches(_ event: LogEvent, _ query: Query) -> Bool {
        if let minLevel = query.minLevel, event.level < minLevel { return false }
        if let project = query.project,
           event.project?.localizedCaseInsensitiveContains(project) != true { return false }
        if let run = query.run, event.run?.hasPrefix(run) != true { return false }
        if let kind = query.event,
           !event.event.localizedCaseInsensitiveContains(kind) { return false }
        if let search = query.search {
            let haystack = [event.message, event.event, event.project, event.run,
                            event.branch, event.path].compactMap { $0 }.joined(separator: " ")
            if !haystack.localizedCaseInsensitiveContains(search) { return false }
        }
        return true
    }

    // MARK: - file helpers

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func decode(_ line: String) -> LogEvent? {
        guard !line.isEmpty else { return nil }
        return Zero.decode(LogEvent.self, from: Data(line.utf8))
    }

    func lastID() -> Int {
        // Nothing readable at the tail of the current file falls through to the
        // rotated one, so ids keep climbing across a rotation instead of
        // restarting at 1 and colliding with everything already written.
        for file in [path, previousPath] {
            for line in Log.tailLines(path: file, maxLines: 5).reversed() {
                if let event = Log.decode(line) { return event.id }
            }
        }
        return 0
    }

    /// Last `maxLines` lines of a file, oldest first, read from the end in
    /// chunks so tailing does not cost the size of the file.
    static func tailLines(path: String, maxLines: Int) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return [] }

        let chunkSize = 64 * 1024
        var offset = end
        var buffer = Data()
        var lines: [String] = []

        while offset > 0 {
            let readSize = UInt64(chunkSize) > offset ? Int(offset) : chunkSize
            offset -= UInt64(readSize)
            try? handle.seek(toOffset: offset)
            guard let chunk = try? handle.read(upToCount: readSize) else { break }
            buffer = chunk + buffer

            // Keep the first (partial) line in the buffer until we read further back.
            var parts = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            let head = parts.removeFirst()
            lines = parts.compactMap { String(data: Data($0), encoding: .utf8) } + lines
            buffer = Data(head)

            if lines.count >= maxLines { break }
        }
        if offset == 0, let first = String(data: buffer, encoding: .utf8), !first.isEmpty {
            lines.insert(first, at: 0)
        }
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
    }
}

extension JSONEncoder {
    func encodeLine<T: Encodable>(_ value: T) -> String {
        guard let data = try? encode(value), let text = String(data: data, encoding: .utf8) else {
            return "{}\n"
        }
        return text + "\n"
    }
}
