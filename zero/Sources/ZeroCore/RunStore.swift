import Foundation

public final class RunStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Run] = [:]
    private let root: String

    public init(root: String = Paths.runsDir) {
        self.root = root
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        reload()
    }

    public func dir(_ id: String) -> String {
        (root as NSString).appendingPathComponent(id)
    }
    public func recordPath(_ id: String) -> String {
        (dir(id) as NSString).appendingPathComponent("run.json")
    }
    public func logPath(_ id: String) -> String {
        (dir(id) as NSString).appendingPathComponent("log")
    }
    public func resultPath(_ id: String) -> String {
        (dir(id) as NSString).appendingPathComponent("result.json")
    }
    public func promptPath(_ id: String) -> String {
        (dir(id) as NSString).appendingPathComponent("prompt.txt")
    }
    public func shimPath(_ id: String) -> String {
        (dir(id) as NSString).appendingPathComponent("shim.json")
    }

    public func reload() {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: root) else { return }
        var loaded: [String: Run] = [:]
        for id in ids where !id.hasPrefix(".") {
            if let run = Zero.readJSON(Run.self, from: recordPath(id)) { loaded[run.id] = run }
        }
        lock.lock(); cache = loaded; lock.unlock()
    }

    public func all() -> [Run] {
        lock.lock(); defer { lock.unlock() }
        return cache.values.sorted { $0.queuedAt > $1.queuedAt }
    }

    public func get(_ id: String) -> Run? {
        lock.lock(); defer { lock.unlock() }
        if let exact = cache[id] { return exact }

        let matches = cache.values.filter { $0.id.hasPrefix(id) }
        return matches.count == 1 ? matches.first : nil
    }

    public func active() -> [Run] { all().filter { $0.status.isActive } }
    public func queued() -> [Run] { all().filter { $0.status == .queued } }
    public func running() -> [Run] { all().filter { $0.status == .running } }

    public func forProject(_ projectId: String) -> [Run] {
        all().filter { $0.projectId == projectId }
    }

    @discardableResult
    public func save(_ run: Run) -> Run {
        lock.lock()
        cache[run.id] = run
        lock.unlock()
        try? FileManager.default.createDirectory(atPath: dir(run.id), withIntermediateDirectories: true)
        Zero.writeJSON(run, to: recordPath(run.id))
        return run
    }

    @discardableResult
    public func mutate(_ id: String, _ change: (inout Run) -> Void) -> Run? {
        lock.lock()
        guard var run = cache[id] else { lock.unlock(); return nil }
        change(&run)
        cache[id] = run
        lock.unlock()
        Zero.writeJSON(run, to: recordPath(run.id))
        return run
    }

    public func delete(_ id: String) {
        lock.lock(); cache.removeValue(forKey: id); lock.unlock()
        try? FileManager.default.removeItem(atPath: dir(id))
    }

    public func readResult(_ id: String) -> AgentResult? {
        Zero.readJSON(AgentResult.self, from: resultPath(id))
    }

    public func tailLog(_ id: String, lines: Int = 60) -> String {
        guard let data = FileManager.default.contents(atPath: logPath(id)),
              let text = String(data: data, encoding: .utf8) else { return "" }
        let all = text.components(separatedBy: "\n")
        return all.suffix(lines).joined(separator: "\n")
    }

    @discardableResult
    public func prune(days: Int = 30, keep: Int = 200) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let terminal = all().filter { $0.status.isTerminal }
        var removed = 0
        for (index, run) in terminal.enumerated() where index >= keep {
            if (run.endedAt ?? run.queuedAt) < cutoff {
                delete(run.id)
                removed += 1
            }
        }
        return removed
    }
}

public struct ShimReport: Codable, Sendable {
    public var phase: String
    public var pid: Int32?
    public var exitCode: Int32?
    public var at: Date

    public init(phase: String, pid: Int32? = nil, exitCode: Int32? = nil, at: Date = Date()) {
        self.phase = phase
        self.pid = pid
        self.exitCode = exitCode
        self.at = at
    }
}
