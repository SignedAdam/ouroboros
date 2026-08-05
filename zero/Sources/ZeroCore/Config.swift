import Foundation

public struct Config: Codable, Sendable {
    public var maxParallel: Int
    public var defaultAgent: String

    public var terminal: String
    public var discordWebhook: String?

    public var notifyOn: [String]
    public var notifyMacOS: Bool

    public var agents: [String: [String]]

    public var httpPort: Int?
    public var token: String?

    public var projectsRoot: String
    public var autoDiscoverRoots: [String]

    public var hotkey: String

    public var repoPath: String?

    public init(maxParallel: Int = 3,
                defaultAgent: String = "claude",
                terminal: String = "cinema",
                discordWebhook: String? = nil,
                notifyOn: [String] = ["question", "failed", "merged", "review"],
                notifyMacOS: Bool = true,
                agents: [String: [String]] = Config.defaultAgents,
                httpPort: Int? = nil,
                token: String? = nil,
                projectsRoot: String = "~/dev",
                autoDiscoverRoots: [String] = [],
                hotkey: String = "opt+space",
                repoPath: String? = nil) {
        self.hotkey = hotkey
        self.repoPath = repoPath
        self.maxParallel = maxParallel
        self.defaultAgent = defaultAgent
        self.terminal = terminal
        self.discordWebhook = discordWebhook
        self.notifyOn = notifyOn
        self.notifyMacOS = notifyMacOS
        self.agents = agents
        self.httpPort = httpPort
        self.token = token
        self.projectsRoot = projectsRoot
        self.autoDiscoverRoots = autoDiscoverRoots
    }

    public static let defaultAgents: [String: [String]] = [
        "claude": ["claude", "-p", "{prompt}"],
        "codex":  ["codex", "exec", "{prompt}"],
        "gemini": ["gemini", "-p", "{prompt}"],
        "pi":     ["pi", "-p", "{prompt}"],
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        maxParallel = try c.decodeIfPresent(Int.self, forKey: .maxParallel) ?? d.maxParallel
        defaultAgent = try c.decodeIfPresent(String.self, forKey: .defaultAgent) ?? d.defaultAgent
        terminal = try c.decodeIfPresent(String.self, forKey: .terminal) ?? d.terminal
        discordWebhook = try c.decodeIfPresent(String.self, forKey: .discordWebhook)
        notifyOn = try c.decodeIfPresent([String].self, forKey: .notifyOn) ?? d.notifyOn
        notifyMacOS = try c.decodeIfPresent(Bool.self, forKey: .notifyMacOS) ?? d.notifyMacOS
        agents = try c.decodeIfPresent([String: [String]].self, forKey: .agents) ?? d.agents
        httpPort = try c.decodeIfPresent(Int.self, forKey: .httpPort)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        projectsRoot = try c.decodeIfPresent(String.self, forKey: .projectsRoot) ?? d.projectsRoot
        autoDiscoverRoots = try c.decodeIfPresent([String].self, forKey: .autoDiscoverRoots) ?? d.autoDiscoverRoots
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath)
    }

    public static func load() -> Config {
        if let c = Zero.readJSON(Config.self, from: Paths.configFile) { return c }

        if FileManager.default.fileExists(atPath: Paths.configFile) {
            let backup = Paths.configFile + ".broken"
            try? FileManager.default.removeItem(atPath: backup)
            try? FileManager.default.copyItem(atPath: Paths.configFile, toPath: backup)
        }
        let fresh = Config()
        Zero.writeJSON(fresh, to: Paths.configFile)
        return fresh
    }

    @discardableResult
    public func save() -> Bool {
        Zero.writeJSON(self, to: Paths.configFile)
    }

    public func agentTemplate(_ name: String) -> [String]? {
        agents[name] ?? Config.defaultAgents[name]
    }

    public func availableAgents() -> [String] {
        agents.keys.sorted().filter { name in
            guard let tmpl = agents[name], let exe = tmpl.first else { return false }
            return Shell.which(exe) != nil
        }
    }
}

public enum Ansi {
    public static var enabled: Bool = isatty(1) == 1 &&
        ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    static func wrap(_ code: String, _ s: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    public static func orange(_ s: String) -> String { wrap("38;2;255;122;24", s) }
    public static func dim(_ s: String) -> String { wrap("2", s) }
    public static func bold(_ s: String) -> String { wrap("1", s) }
    public static func green(_ s: String) -> String { wrap("38;2;126;217;87", s) }
    public static func red(_ s: String) -> String { wrap("38;2;255;95;86", s) }
    public static func yellow(_ s: String) -> String { wrap("38;2;255;189;46", s) }
    public static func blue(_ s: String) -> String { wrap("38;2;120;170;255", s) }
    public static func grey(_ s: String) -> String { wrap("38;5;245", s) }

    public static func width(_ s: String) -> Int {
        var count = 0
        var inEscape = false
        for ch in s {
            if ch == "\u{1B}" { inEscape = true; continue }
            if inEscape { if ch == "m" { inEscape = false }; continue }
            count += 1
        }
        return count
    }

    public static func pad(_ s: String, _ n: Int) -> String {
        let w = width(s)
        return w >= n ? s : s + String(repeating: " ", count: n - w)
    }
}
