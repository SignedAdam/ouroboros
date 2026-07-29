import Foundation

/// The capture field's command line.
///
/// Typing a sentence is already the fastest way to file an issue, so everything
/// else Zero can do had to become reachable from that same field rather than
/// from a settings window nobody opens. Every command below is one HTTP call an
/// AI operator could make with `curl` — the panel keeps its promise of having no
/// private powers.
///
/// It lives in ZeroCore rather than next to the SwiftUI palette because none of
/// it is UI: the table, the matcher and the tokenizer are the grammar of the
/// product, and the app, the CLI and the tests all deserve the same one.
public struct SlashCommand: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let aliases: [String]
    public let argHint: String
    public let summary: String

    public init(name: String, aliases: [String], argHint: String, summary: String) {
        self.name = name
        self.aliases = aliases
        self.argHint = argHint
        self.summary = summary
    }
}

public enum SlashCommands {

    /// Declaration order is what a bare "/" shows, so it runs from the two
    /// commands the product is shaped around down to the app's own plumbing.
    ///
    /// `/add` adopts a directory that already exists; `/new` brings one into
    /// being. Keeping those separate is the whole reason there are two verbs:
    /// one of them can destroy an afternoon by scaffolding over your work.
    public static let all: [SlashCommand] = [
        SlashCommand(name: "add", aliases: ["add-project"], argHint: "[path]",
                     summary: "adopt a directory that already exists"),
        SlashCommand(name: "new", aliases: ["new-project"], argHint: "<name> [description]",
                     summary: "scaffold one that doesn't exist yet"),
        SlashCommand(name: "project", aliases: ["p", "use"], argHint: "<name>",
                     summary: "capture into this project"),
        SlashCommand(name: "open", aliases: ["reveal"], argHint: "[project]",
                     summary: "reveal the directory in Finder"),

        SlashCommand(name: "fix", aliases: [], argHint: "[issue-id]",
                     summary: "put an agent on an issue"),
        SlashCommand(name: "idea", aliases: ["note"], argHint: "<text>",
                     summary: "park it — no issue, no run"),
        SlashCommand(name: "promote", aliases: [], argHint: "[idea-id]",
                     summary: "turn a parked idea into an issue"),
        SlashCommand(name: "task", aliases: ["do"], argHint: "<prompt>",
                     summary: "dispatch an agent on a one-off prompt"),

        SlashCommand(name: "issues", aliases: [], argHint: "[project]",
                     summary: "what's open"),
        SlashCommand(name: "inbox", aliases: ["needs"], argHint: "",
                     summary: "what needs you"),
        SlashCommand(name: "runs", aliases: ["ps"], argHint: "",
                     summary: "what's in flight"),

        SlashCommand(name: "reply", aliases: ["answer"], argHint: "[run] <answer>",
                     summary: "answer an agent's question"),
        SlashCommand(name: "merge", aliases: ["land"], argHint: "[run]",
                     summary: "land a verified run"),
        SlashCommand(name: "retry", aliases: [], argHint: "[run]",
                     summary: "dispatch it again"),
        SlashCommand(name: "undo", aliases: ["revert"], argHint: "[run]",
                     summary: "revert a merged run"),
        SlashCommand(name: "stop", aliases: [], argHint: "[run]",
                     summary: "abandon a run mid-flight"),

        SlashCommand(name: "rename", aliases: [], argHint: "<old> <new>",
                     summary: "rename a registered project"),
        SlashCommand(name: "verify", aliases: [], argHint: "<cmd>",
                     summary: "the command that decides a fix is real"),
        SlashCommand(name: "autonomy", aliases: [], argHint: "<manual|assist|auto>",
                     summary: "how far agents may go alone"),
        SlashCommand(name: "agent", aliases: ["harness"], argHint: "<name>",
                     summary: "which harness this project uses"),
        SlashCommand(name: "finish", aliases: [], argHint: "<merge|pr|leave>",
                     summary: "what happens when a fix passes"),
        SlashCommand(name: "discover", aliases: ["scan"], argHint: "<root>",
                     summary: "register every repo under a root"),
        SlashCommand(name: "forget", aliases: ["rm", "remove"], argHint: "<project>",
                     summary: "unregister it — the files stay"),

        SlashCommand(name: "setup", aliases: [], argHint: "[roots]",
                     summary: "find and adopt your projects"),
        SlashCommand(name: "update", aliases: ["upgrade"], argHint: "",
                     summary: "pull and rebuild ouroboros itself"),
        // Distinct from /update, which pulls first. /rebuild takes the source
        // exactly as it stands on disk, which is what you want the moment an
        // agent has merged a fix into it and you want to be running that fix.
        SlashCommand(name: "rebuild", aliases: [], argHint: "from source",
                     summary: "rebuild from the code on disk and restart"),
        SlashCommand(name: "hotkey", aliases: [], argHint: "<combo>",
                     summary: "the global capture shortcut"),
        SlashCommand(name: "health", aliases: ["daemon"], argHint: "",
                     summary: "daemon, projects, runs, inbox"),
        SlashCommand(name: "help", aliases: ["?", "commands"], argHint: "",
                     summary: "every command"),
        SlashCommand(name: "quit", aliases: ["exit"], argHint: "",
                     summary: "quit Ouroboros Zero"),
    ]

    /// input is the raw field text. Returns [] when it is not a slash command.
    public static func suggestions(for input: String) -> [SlashCommand] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return [] }
        let query = String(text.dropFirst())
        // A space means the command has been chosen and the user is typing its
        // arguments — the palette must get out of the way, and out of the way of
        // the return key, or there is no way to ever submit `/idea …`.
        guard !query.contains(where: { $0.isWhitespace }) else { return [] }
        guard !query.isEmpty else { return all }

        let needle = query.lowercased()
        var exact: [SlashCommand] = []
        var byName: [SlashCommand] = []
        var byAlias: [SlashCommand] = []
        for command in all {
            if command.name == needle || command.aliases.contains(needle) {
                exact.append(command)
            } else if command.name.hasPrefix(needle) {
                byName.append(command)
            } else if command.aliases.contains(where: { $0.hasPrefix(needle) }) {
                byAlias.append(command)
            }
        }
        return exact + byName + byAlias
    }

    /// nil when the text does not resolve to a known command.
    public static func parse(_ input: String) -> (command: SlashCommand, args: [String])? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/"), text.count > 1 else { return nil }
        let tokens = tokenize(String(text.dropFirst()))
        guard let head = tokens.first?.lowercased(), let command = named(head) else { return nil }
        return (command, Array(tokens.dropFirst()))
    }

    public static func named(_ token: String) -> SlashCommand? {
        let needle = token.lowercased()
        return all.first { $0.name == needle || $0.aliases.contains(needle) }
    }

    /// Whitespace-separated, but `"quoted runs"` survive as one argument —
    /// `/rename "old name" new` is a thing people will type on day one.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var quoted = false

        for ch in text {
            if let open = quote {
                if ch == open { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                quoted = true
                continue
            }
            if ch.isWhitespace {
                if quoted || !current.isEmpty { tokens.append(current) }
                current = ""
                quoted = false
                continue
            }
            current.append(ch)
        }
        if quoted || !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// The directory names itself, exactly as it is spelled on disk: `/add
    /// ~/dev/Acme` registers "Acme", capital N and all. Only trailing
    /// slashes are noise, so `/dev/acme/` is still "acme".
    public static func projectName(forPath path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return (trimmed as NSString).lastPathComponent
    }
}
