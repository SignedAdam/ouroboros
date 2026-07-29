import Foundation

/// What Ouroboros knows about the harnesses it dispatches to.
///
/// Only three things differ between them, and nothing else does: how you tell
/// one which conversation to file the work under, how you get back into that
/// conversation afterwards, and — for the ones that will not be told — how you
/// find out what they called it.
///
/// Everything here is derived from the argv template in config.json, so
/// pointing "claude" at a wrapper script keeps working: the harness is
/// recognised by the executable it actually runs, and an unrecognised one
/// simply loses the resume features rather than breaking dispatch.
public enum Harness: String, Sendable, CaseIterable {
    case claude, codex, gemini, other

    public static func of(agent: String, template: [String]?) -> Harness {
        let executable = ((template?.first ?? agent) as NSString).lastPathComponent.lowercased()
        for candidate in [Harness.claude, .codex, .gemini]
        where executable.contains(candidate.rawValue) || agent.lowercased() == candidate.rawValue {
            return candidate
        }
        return .other
    }

    /// Can this harness be *told* its conversation id before it starts?
    ///
    /// Claude Code can (`--session-id`), which means Ouroboros knows how to get
    /// back into the conversation before the agent has said a word. Codex
    /// cannot, so its id is discovered afterwards from the rollout it writes.
    public var acceptsSessionId: Bool { self == .claude }

    /// Whether a conversation can be reopened at all.
    public var canResume: Bool { self == .claude || self == .codex }

    /// A human sentence for the panel, because "codex" alone does not say
    /// whether resuming will work.
    public var resumeHint: String {
        switch self {
        case .claude: return "claude --resume"
        case .codex:  return "codex resume"
        default:      return "this harness cannot reopen a conversation"
        }
    }
}

public enum Agents {
    /// The argv to launch: `{prompt}` filled in, and — where the harness takes
    /// one — the session id we intend the conversation to have.
    ///
    /// `{session}` in a user's own template wins over anything we would inject,
    /// so a hand-written invocation stays exactly as written.
    public static func dispatchArgv(template: [String], prompt: String,
                                    sessionId: String, harness: Harness) -> [String] {
        var argv = template
        let templated = argv.contains { $0.contains("{session}") }
        if !templated, harness.acceptsSessionId, !argv.contains("--session-id"), !argv.isEmpty {
            argv.insert(contentsOf: ["--session-id", sessionId], at: 1)
        }
        return argv.map { token in
            token == "{prompt}"
                ? prompt
                : token.replacingOccurrences(of: "{session}", with: sessionId)
        }
    }

    /// How to reopen a conversation in a terminal. Nil when the harness has no
    /// way back in — the caller must not offer the action at all rather than
    /// launch something that fails in a window the user then has to close.
    public static func resumeArgv(harness: Harness, template: [String]?,
                                  sessionId: String) -> [String]? {
        let executable = template?.first ?? harness.rawValue
        switch harness {
        case .claude: return [executable, "--resume", sessionId]
        case .codex:  return [executable, "resume", sessionId]
        default:      return nil
        }
    }

    /// Claude Code's fleet view of *your own* background sessions in a repo.
    ///
    /// Deliberately scoped to the project rather than pointed at Ouroboros runs:
    /// a supervised run belongs to the supervisor, which owns its worktree, its
    /// gate and its merge. Agent view is for the sessions you started yourself,
    /// and this is the shortcut to the ones for this repo.
    public static func agentViewArgv(cwd: String, template: [String]?) -> [String] {
        [(template?.first ?? "claude"), "agents", "--cwd", cwd]
    }

    // MARK: - discovery

    public static var codexSessionsRoot: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
    }

    /// Codex will not be told which conversation to use, but it writes exactly
    /// one rollout per session and states the working directory in its first
    /// line. The newest rollout whose `cwd` is the run's is the run's.
    ///
    /// `since` guards against adopting a conversation from before this run
    /// started; the slack absorbs a clock that ticks between our timestamp and
    /// the file's.
    public static func discoverCodexSession(cwd: String, since: Date,
                                            root: String? = nil,
                                            slack: TimeInterval = 30) -> String? {
        let base = root ?? codexSessionsRoot
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: base) else { return nil }
        let floor = since.addingTimeInterval(-slack)
        let wanted = Registry.normalize(cwd)

        var best: (id: String, at: Date)?
        for case let name as String in walker where name.hasSuffix(".jsonl") {
            let path = (base as NSString).appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate]
                    as? Date, modified >= floor else { continue }
            if let current = best, modified <= current.at { continue }
            guard let meta = sessionMeta(of: path), Registry.normalize(meta.cwd) == wanted else {
                continue
            }
            best = (meta.id, modified)
        }
        return best?.id
    }

    /// The first line of a rollout is a `session_meta` record carrying the id
    /// and the directory. Read that line and nothing else — these files grow to
    /// megabytes.
    static func sessionMeta(of path: String) -> (id: String, cwd: String)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_384), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").first,
              let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let root = parsed as? [String: Any],
              let payload = root["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let cwd = payload["cwd"] as? String else { return nil }
        return (id, cwd)
    }
}

/// One harness as the UI needs to offer it.
public struct AgentInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Its CLI is on PATH. A harness that isn't installed is not offered.
    public var available: Bool
    public var isDefault: Bool
    public var canResume: Bool

    public init(name: String, available: Bool, isDefault: Bool, canResume: Bool) {
        self.name = name
        self.available = available
        self.isDefault = isDefault
        self.canResume = canResume
    }
}
