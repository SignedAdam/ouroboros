import Foundation

public struct ShellResult: Sendable {
    public let status: Int32
    public let output: String
    public var ok: Bool { status == 0 }
    public var trimmed: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
}

public enum Shell {
    @discardableResult
    public static func run(_ argv: [String], cwd: String? = nil, login: Bool = false,
                           env: [String: String]? = nil,
                           timeout: TimeInterval? = nil) -> ShellResult {
        guard !argv.isEmpty else { return ShellResult(status: 127, output: "empty command") }
        let process = Process()
        if login {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", argv.map(quote).joined(separator: " ")]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = argv
        }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            process.environment = merged
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            return ShellResult(status: 127, output: "\(error)")
        }

        let lock = NSLock()
        var collected = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); collected = data; lock.unlock()
            done.signal()
        }

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.3)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = done.wait(timeout: .now() + 2)
                lock.lock(); let out = String(data: collected, encoding: .utf8) ?? ""; lock.unlock()
                return ShellResult(status: 124, output: out + "\n[timed out after \(Int(timeout))s]")
            }
        }

        process.waitUntilExit()
        _ = done.wait(timeout: .now() + 5)
        lock.lock(); let out = String(data: collected, encoding: .utf8) ?? ""; lock.unlock()
        return ShellResult(status: process.terminationStatus, output: out)
    }

    @discardableResult
    public static func runLine(_ line: String, cwd: String? = nil,
                               timeout: TimeInterval? = nil) -> ShellResult {
        run(["/bin/zsh", "-lc", line], cwd: cwd, timeout: timeout)
    }

    public static func which(_ tool: String) -> String? {
        let r = run(["command", "-v", tool], login: true)
        let p = r.trimmed
        return r.ok && !p.isEmpty ? p : nil
    }

    public static func quote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./=:,@%+")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct Git {
    public let repo: String
    public init(_ repo: String) { self.repo = repo }

    @discardableResult
    public func run(_ args: [String], timeout: TimeInterval? = 120) -> ShellResult {
        Shell.run(["git"] + args, cwd: repo, timeout: timeout)
    }

    public var isRepo: Bool {
        run(["rev-parse", "--git-dir"], timeout: 10).ok
    }

    public var currentBranch: String? {
        let r = run(["rev-parse", "--abbrev-ref", "HEAD"], timeout: 10)
        guard r.ok else { return nil }
        let b = r.trimmed
        return b.isEmpty || b == "HEAD" ? nil : b
    }

    public var isClean: Bool {
        let r = run(["status", "--porcelain"], timeout: 20)
        return r.ok && r.trimmed.isEmpty
    }

    public func hasUncommittedTrackedChanges() -> Bool {
        let r = run(["status", "--porcelain"], timeout: 20)
        guard r.ok else { return true }
        for line in r.output.split(separator: "\n", omittingEmptySubsequences: true) {
            let entry = String(line)
            guard entry.count > 3 else { continue }
            let code = entry.prefix(2)
            if code == "??" || code == "!!" { continue }
            var path = String(entry.dropFirst(3))
            if path.hasPrefix("\"") { path = String(path.dropFirst().dropLast()) }
            if let arrow = path.range(of: " -> ") {
                path = String(path[arrow.upperBound...])
            }
            if path.hasPrefix(".issues/") || path.hasPrefix(".ouroboros/") { continue }
            return true
        }
        return false
    }

    public func hasCommits(on branch: String, notOn base: String) -> Bool {
        let r = run(["rev-list", "--count", "\(base)..\(branch)"], timeout: 30)
        return r.ok && (Int(r.trimmed) ?? 0) > 0
    }

    public func changedFiles(branch: String, base: String) -> [String] {
        let r = run(["diff", "--name-only", "\(base)...\(branch)"], timeout: 30)
        guard r.ok else { return [] }
        return r.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public func commitSubjects(branch: String, base: String) -> [String] {
        let r = run(["log", "--format=%s", "\(base)..\(branch)"], timeout: 30)
        guard r.ok else { return [] }
        return r.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public var defaultBranch: String {
        for candidate in ["main", "master"] {
            if run(["rev-parse", "--verify", "--quiet", candidate], timeout: 10).ok {
                return candidate
            }
        }
        return currentBranch ?? "main"
    }

    public var hasRemote: Bool {
        !run(["remote"], timeout: 10).trimmed.isEmpty
    }

    public var localBranches: [String] {
        let r = run(["for-each-ref", "--sort=-committerdate",
                     "--format=%(refname:short)", "refs/heads/"], timeout: 20)
        guard r.ok else { return [] }
        return r.output.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("fix/") }
    }

    public func rebase(branch: String, onto base: String) -> (ok: Bool, message: String) {
        let checkout = run(["checkout", branch], timeout: 60)
        guard checkout.ok else {
            return (false, "could not check out \(branch)")
        }
        let result = run(["rebase", base], timeout: 300)
        guard result.ok else {
            run(["rebase", "--abort"], timeout: 60)
            return (false, "\(branch) does not rebase onto \(base) cleanly — it needs a person")
        }
        return (true, "rebased \(branch) onto \(base)")
    }

    public static func repoRoot(containing path: String) -> String? {
        let r = Shell.run(["git", "rev-parse", "--show-toplevel"], cwd: path, timeout: 10)
        guard r.ok else { return nil }
        let root = r.trimmed
        return root.isEmpty ? nil : root
    }
}
