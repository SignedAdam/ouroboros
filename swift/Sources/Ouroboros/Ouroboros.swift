import Foundation

public struct Ouroboros: Sendable {
    public let projectDir: String
    public let store: IssueStore
    public let agent: Agent
    public let terminal: TerminalLauncher
    public let baseBranch: String
    let worktrees: WorktreeManager

    public init(projectDir: String, store: IssueStore? = nil, agent: Agent = .claudeCode,
                terminal: TerminalLauncher = TerminalLauncher(), baseBranch: String = "main",
                worktrees: WorktreeManager = WorktreeManager()) {
        self.projectDir = projectDir
        self.store = store ?? IssueStore(rootDir: projectDir)
        self.agent = agent
        self.terminal = terminal
        self.baseBranch = baseBranch
        self.worktrees = worktrees
    }

    @discardableResult
    public func submit(title: String, body: String,
                       screenshot: IssueScreenshot? = nil) -> Issue? {
        store.write(title: title, body: body, screenshot: screenshot)
    }

    @discardableResult
    public func handToAgent(_ issue: Issue, options: FixOptions = FixOptions()) -> Bool {
        var cwd = projectDir
        var branch: String?
        if options.worktree {
            guard let wt = worktrees.create(repo: projectDir, base: baseBranch, slug: issue.slug) else {
                return false
            }
            cwd = wt.path
            branch = wt.branch
        }
        let prompt = seedPrompt(issue: issue, baseBranch: baseBranch, options: options, branch: branch)
        let inv = agent.invocation(prompt: prompt, cwd: cwd, label: issue.slug, title: issue.title)
        terminal.launch(inv)
        return true
    }
}
