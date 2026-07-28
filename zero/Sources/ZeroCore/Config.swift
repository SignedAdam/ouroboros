import Foundation

/// Global preferences. Everything here has a working default — Zero must be
/// useful with an empty config file, because the first run is the one that
/// decides whether a tool gets used.
public struct Config: Codable, Sendable {
    /// How many agents may run at once across ALL projects. Ten issues filed in
    /// a burst become an orderly queue instead of ten agents thrashing one Mac.
    public var maxParallel: Int
    public var defaultAgent: String
    /// cinema — one Ghostty window per run, closes itself (the good one).
    /// tmux   — tabs stacked in a dedicated `ouroboros` session.
    /// silent — headless, no terminal at all.
    public var terminal: String
    public var discordWebhook: String?
    /// Which inbox kinds are worth a Discord ping.
    public var notifyOn: [String]
    public var notifyMacOS: Bool
    /// argv templates; `{prompt}` is replaced with the seed prompt.
    public var agents: [String: [String]]
    /// Optional loopback HTTP, for clients that can't speak unix sockets.
    public var httpPort: Int?
    public var token: String?
    /// Where `ouro new` suggests putting things.
    public var projectsRoot: String
    public var autoDiscoverRoots: [String]
    /// Global capture hotkey, e.g. "opt+space", "cmd+shift+space", "opt+cmd+i".
    /// If it can't be registered (another app owns it) the app walks a fallback
    /// list and reports which one it actually got.
    public var hotkey: String
    /// The checkout `/update` pulls and rebuilds from. Defaults to the path of
    /// the registered project named "ouroboros" when unset.
    public var repoPath: String?

    public init(maxParallel: Int = 3,
                defaultAgent: String = "claude",
                terminal: String = "cinema",
                discordWebhook: String? = nil,
                notifyOn: [String] = ["question", "failed", "landed", "ready"],
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

    /// Same defaults as the engine: the agent's own CLI, its own settings, its
    /// own permission prompts. Zero does not decide how much rope your agent
    /// gets — it only decides where it runs (an isolated worktree) and whether
    /// the result is allowed to land (the verification gate).
    ///
    /// For genuinely unattended overnight runs you'll want your harness's
    /// non-interactive / auto-approve flag. That is a deliberate per-machine
    /// choice, so it lives in `~/.ouroboros/config.json`, not in this default:
    ///
    ///     "agents": { "claude": ["claude", "<your-flags>", "{prompt}"] }
    public static let defaultAgents: [String: [String]] = [
        "claude": ["claude", "{prompt}"],
        "codex":  ["codex", "{prompt}"],
        "gemini": ["gemini", "{prompt}"],
        "pi":     ["pi", "{prompt}"],
    ]

    public static func load() -> Config {
        if let c = Zero.readJSON(Config.self, from: Paths.configFile) { return c }
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

    /// A harness is available iff we have a template for it and its CLI is on
    /// PATH. Probed through a login shell — a Finder-launched app has no PATH.
    public func availableAgents() -> [String] {
        agents.keys.sorted().filter { name in
            guard let tmpl = agents[name], let exe = tmpl.first else { return false }
            return Shell.which(exe) != nil
        }
    }
}

/// The Ouroboros palette, used identically by the CLI and the cinema banner.
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

    /// Visible width, ignoring escape sequences — table columns line up only if
    /// padding counts glyphs rather than bytes.
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
