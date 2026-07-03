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

public func seedPrompt(issue: Issue, baseBranch: String, options: FixOptions, branch: String?) -> String {
    let fileLine = issue.path.map { "(Issue file: \($0))\n\n" } ?? ""
    let header =
        "A user filed this issue from an in-app composer. It may be ill-defined — " +
        "decide first whether it is clear enough to implement.\n\n" +
        "## \(issue.title)\n\n\(issue.body)\n\n" + fileLine +
        "If it is NOT clearly actionable, do not guess: note what's ambiguous in the " +
        "issue file and stop — leave it blocked. "
    let br = branch ?? "fix/\(issue.slug)"
    let action: String
    switch (options.worktree, options.finish) {
    case (true, .mergeIntoBase):
        action = "If it IS clear, you are in a dedicated git worktree on branch `\(br)`. " +
            "Implement it fully, verify it, rebase on `\(baseBranch)`, then merge back into `\(baseBranch)`. " +
            "If there are conflicts you cannot cleanly resolve, stop and leave the branch with a note. " +
            "When merged cleanly, remove this worktree, then summarize what you changed. " +
            "Also append a short `## Resolution` section (what changed, and the date) to the issue file " +
            "and move it from `.issues/new/` to `.issues/done/` with `git mv`, committed on `\(baseBranch)`."
    case (true, .openPR):
        action = "If it IS clear, you are in a dedicated git worktree on branch `\(br)`. " +
            "Implement it fully, verify it, push the branch, and open a PR into `\(baseBranch)` with `gh pr create`. " +
            "Do not merge. Then summarize what you changed. " +
            "Append the PR URL to the issue file (it stays in `.issues/new/` until the PR lands)."
    case (false, .mergeIntoBase):
        action = "If it IS clear, implement it fully on the current branch, verify it, then commit. " +
            "Then summarize what you changed. " +
            "Also append a short `## Resolution` section to the issue file and move it from " +
            "`.issues/new/` to `.issues/done/` with `git mv`, committed with the fix."
    case (false, .openPR):
        action = "If it IS clear, create a new branch `\(br)`, implement it fully, verify it, push, and " +
            "open a PR into `\(baseBranch)` with `gh pr create`. Then summarize what you changed. " +
            "Append the PR URL to the issue file (it stays in `.issues/new/` until the PR lands)."
    }
    return header + action
}
