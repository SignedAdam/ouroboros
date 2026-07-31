import Foundation
import ZeroCore

// MARK: - Arguments

struct Args {
    var command: String = ""
    var positional: [String] = []
    var flags: [String: String] = [:]
    /// Everything after a bare `--`, untouched (the shim's agent argv).
    var rest: [String] = []

    /// Flags that consume the next token. Everything else is a boolean.
    static let valueFlags: Set<String> = [
        "p", "project", "t", "title", "a", "agent", "finish", "n", "lines", "status",
        "dir", "desc", "description", "github", "roadmap", "home", "source", "limit",
        "verify", "base", "autonomy", "name", "root", "prompt",
    ]

    static func parse(_ argv: [String]) -> Args {
        var args = Args()
        var index = 0
        // The command is the first bare word wherever it appears — global flags
        // like `--home` may legitimately precede it.
        var positionals: [String] = []
        while index < argv.count {
            let token = argv[index]
            if token == "--" {
                args.rest = Array(argv[(index + 1)...])
                break
            }
            if token.hasPrefix("--") {
                let name = String(token.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    args.flags[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if valueFlags.contains(name), index + 1 < argv.count {
                    args.flags[name] = argv[index + 1]
                    index += 1
                } else {
                    args.flags[name] = "true"
                }
            } else if token.hasPrefix("-") && token.count > 1 {
                let name = String(token.dropFirst())
                if valueFlags.contains(name), index + 1 < argv.count {
                    args.flags[name] = argv[index + 1]
                    index += 1
                } else {
                    args.flags[name] = "true"
                }
            } else {
                positionals.append(token)
            }
            index += 1
        }
        if let command = positionals.first {
            args.command = command
            args.positional = Array(positionals.dropFirst())
        }
        return args
    }

    func flag(_ names: String...) -> String? {
        for name in names { if let value = flags[name] { return value } }
        return nil
    }

    func bool(_ names: String...) -> Bool {
        for name in names where flags[name] != nil {
            return !["false", "no", "0"].contains(flags[name]!.lowercased())
        }
        return false
    }

    func has(_ names: String...) -> Bool {
        names.contains { flags[$0] != nil }
    }

    var joined: String {
        positional.joined(separator: " ")
    }
}

// MARK: - Output

enum Out {
    static func say(_ s: String = "") { print(s) }

    static func err(_ s: String) {
        FileHandle.standardError.write(Data((Ansi.red("✗ ") + s + "\n").utf8))
    }

    static func ok(_ s: String) { print(Ansi.green("✓ ") + s) }
    /// Not a failure, but not a yes either. `merge-check` needs a third answer.
    static func warn(_ s: String) { print(Ansi.yellow("! ") + s) }
    static func info(_ s: String) { print(Ansi.dim(s)) }

    static func die(_ s: String, code: Int32 = 1) -> Never {
        err(s)
        exit(code)
    }

    static func mark() -> String {
        Ansi.orange("◍")
    }

    /// The banner. Same word-art as the cinema splash — one system, one face.
    static func banner() {
        print("")
        print("  " + Ansi.orange("█▀█ █ █ █▀▄ █▀█ ██▄ █▀█ █▀▄ █▀█ ▄▀▀"))
        print("  " + Ansi.orange("█ █ █ █ ██▀ █ █ █▄█ █ █ ██▀ █ █ ▀▀▄"))
        print("  " + Ansi.orange("▀▀▀ ▀▀▀ ▀ ▀ ▀▀▀ ▀▀▀ ▀▀▀ ▀ ▀ ▀▀▀ ▀▀ "))
        print("")
    }
}

enum Fmt {
    static func ago(_ date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    static func duration(_ interval: TimeInterval?) -> String {
        guard let interval else { return "—" }
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }

    static func glyph(_ status: RunStatus) -> String {
        switch status {
        case .queued:    return Ansi.grey("○")
        case .running:   return Ansi.orange("●")
        case .verifying: return Ansi.blue("◐")
        case .finishing: return Ansi.blue("◑")
        case .awaiting:  return Ansi.yellow("?")
        case .succeeded: return Ansi.green("✓")
        case .failed:    return Ansi.red("✗")
        case .abandoned: return Ansi.grey("–")
        }
    }

    static func status(_ status: RunStatus) -> String {
        switch status {
        case .queued:    return Ansi.grey("queued")
        case .running:   return Ansi.orange("running")
        case .verifying: return Ansi.blue("verifying")
        case .finishing: return Ansi.blue("finishing")
        case .awaiting:  return Ansi.yellow("needs you")
        case .succeeded: return Ansi.green("succeeded")
        case .failed:    return Ansi.red("failed")
        case .abandoned: return Ansi.grey("abandoned")
        }
    }

    static func inboxGlyph(_ kind: InboxItem.Kind) -> String {
        switch kind {
        case .question: return Ansi.yellow("?")
        case .failed:   return Ansi.red("✗")
        case .merged:   return Ansi.green("✓")
        case .review:   return Ansi.blue("→")
        case .proposal: return Ansi.orange("◍")
        }
    }

    static func inboxLabel(_ kind: InboxItem.Kind) -> String {
        switch kind {
        case .question: return Ansi.yellow("needs you")
        case .failed:   return Ansi.red("failed")
        case .merged:   return Ansi.green("merged")
        case .review:   return Ansi.blue("review")
        case .proposal: return Ansi.orange("proposal")
        }
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= n ? flat : String(flat.prefix(n - 1)) + "…"
    }
}

// MARK: - Client

enum Zero0 {
    static var homeOverride: String?

    /// `main.swift` exports `OUROBOROS_HOME` before anything else runs, so
    /// `Paths.socket` already accounts for `--home` (including its long-path
    /// fallback). Recomputing the path here would reintroduce that bug.
    static func client() -> ZeroClient {
        ZeroClient(socketPath: Paths.socket)
    }

    /// Talk to the daemon, starting it if it isn't up. The CLI should never make
    /// the user think about a background process.
    static func connected(autostart: Bool = true) -> ZeroClient {
        let c = client()
        if c.isUp { return c }
        guard autostart, startDaemon() else {
            Out.die("the ouroboros daemon isn't running and could not be started (try: ouro daemon start)")
        }
        for _ in 0..<50 {
            if c.isUp { return c }
            usleep(100_000)
        }
        Out.die("the daemon started but never answered on \(c.socketPath)")
    }

    @discardableResult
    static func startDaemon() -> Bool {
        guard let binary = daemonBinary() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = []
        var env = ProcessInfo.processInfo.environment
        if let home = homeOverride { env["OUROBOROS_HOME"] = home }
        process.environment = env
        let logPath = (env["OUROBOROS_HOME"].map { ($0 as NSString).appendingPathComponent("ourod.log") })
            ?? Paths.daemonLog
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
        }
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        return true
    }

    static func daemonBinary() -> String? {
        let argv0 = CommandLine.arguments.first ?? "ouro"
        let resolved = (argv0 as NSString).isAbsolutePath
            ? argv0
            : FileManager.default.currentDirectoryPath + "/" + argv0
        let sibling = ((resolved as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("ourod")
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        return Shell.which("ourod")
    }

    static func cwd() -> String { FileManager.default.currentDirectoryPath }
}

extension ZeroClient.ClientError {
    var friendly: String { description }
}
