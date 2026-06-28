import Foundation

public struct AgentInvocation: Sendable, Equatable {
    public let argv: [String]
    public let cwd: String
    public let label: String
    public init(argv: [String], cwd: String, label: String) {
        self.argv = argv
        self.cwd = cwd
        self.label = label
    }
}

public struct FixOptions: Sendable, Equatable {
    public enum Finish: String, Sendable, Equatable { case mergeIntoBase, openPR }
    public var worktree: Bool
    public var finish: Finish
    public init(worktree: Bool = true, finish: Finish = .mergeIntoBase) {
        self.worktree = worktree
        self.finish = finish
    }
}

public struct Agent: Sendable {
    public let name: String
    public let template: [String]   // a "{prompt}" token is replaced with the seed prompt
    public init(name: String, template: [String]) {
        self.name = name
        self.template = template
    }
    public func invocation(prompt: String, cwd: String, label: String) -> AgentInvocation {
        let argv = template.map { $0 == "{prompt}" ? prompt : $0 }
        return AgentInvocation(argv: argv, cwd: cwd, label: label)
    }
    public static let claudeCode = Agent(name: "claude_code", template: ["claude", "{prompt}"])
    public static let codex = Agent(name: "codex", template: ["codex", "{prompt}"])
    public static let gemini = Agent(name: "gemini", template: ["gemini", "{prompt}"])
    public static let pi = Agent(name: "pi", template: ["pi", "{prompt}"])
    public static func custom(_ template: String...) -> Agent {
        Agent(name: "custom", template: template)
    }
}

// Filled in Task 5.
public func seedPrompt(issue: Issue, baseBranch: String, options: FixOptions, branch: String?) -> String {
    ""
}
