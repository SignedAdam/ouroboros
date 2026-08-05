import Foundation

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

    public var acceptsSessionId: Bool { self == .claude }

    public var canResume: Bool { self == .claude || self == .codex }

    public var resumeHint: String {
        switch self {
        case .claude: return "claude --resume"
        case .codex:  return "codex resume"
        default:      return "this harness cannot reopen a conversation"
        }
    }
}

public enum Agents {
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

    public static func resumeArgv(harness: Harness, template: [String]?,
                                  sessionId: String) -> [String]? {
        let executable = template?.first ?? harness.rawValue
        switch harness {
        case .claude: return [executable, "--resume", sessionId]
        case .codex:  return [executable, "resume", sessionId]
        default:      return nil
        }
    }

    public static func resumeArgv(harness: Harness, template: [String]?,
                                  sessionId: String, prompt: String) -> [String]? {
        let executable = template?.first ?? harness.rawValue
        switch harness {
        case .claude: return [executable, "--resume", sessionId, "-p", prompt]

        case .codex:  return [executable, "exec", "resume", sessionId, prompt]
        default:      return nil
        }
    }

    public static func agentViewArgv(cwd: String, template: [String]?) -> [String] {
        [(template?.first ?? "claude"), "agents", "--cwd", cwd]
    }

    public static var codexSessionsRoot: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
    }

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

public struct AgentInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String

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
