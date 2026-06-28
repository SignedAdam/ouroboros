# Integrating Ouroboros (for a coding agent)

You are adding the Ouroboros "report an issue → fix it with an agent" flow to a macOS
Swift app. Follow these steps. Adapt names to the host app's conventions; keep the engine
calls identical.

## 1. Add the dependency

In the app's `Package.swift` (or Xcode project's package dependencies):

```swift
dependencies: [
    // Published:
    .package(url: "https://github.com/<owner>/ouroboros-swift", branch: "main"),
    // …or local during development:
    // .package(path: "../ouroboros-swift"),
],
```

**SPM gotcha:** a path/url dependency is identified by its **repository/directory name**,
not the manifest's `name:`. The repo is `ouroboros-swift`, so the product reference is
`package: "ouroboros-swift"`:

```swift
.target(
    name: "YourApp",
    dependencies: [.product(name: "Ouroboros", package: "ouroboros-swift")]
),
```

**If a test target imports `Ouroboros`**, add the same product to that target's
dependencies too — SPM only lets you `import` a module that is a direct dependency.

## 2. Construct the facade

The engine needs the **repo root** of the project issues are filed into and fixes run
against (often a user-configurable setting). Base branch defaults to the current branch:

```swift
import Ouroboros

func makeOuroboros(agent: Agent, repoRoot: String, configuredBase: String) -> Ouroboros {
    // Empty configured base → auto-detect HEAD.
    let base: String = {
        let t = configuredBase.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let r = GitRunner.live.run(["rev-parse", "--abbrev-ref", "HEAD"], repoRoot)
        let head = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? "main" : head
    }()
    return Ouroboros(projectDir: repoRoot, agent: agent,
                     terminal: TerminalLauncher(kind: .ghosttyTmuxTab), baseBranch: base)
}
```

## 3. Harness selection (which agent)

Let the user enable Claude Code and/or Codex in settings. Resolve to the ones that are
**both enabled and installed**, and offer a choice only when more than one is available:

```swift
enum Harness: String, CaseIterable { case claude, codex
    var binary: String { self == .claude ? "claude" : "codex" }
    var label: String { self == .claude ? "Claude" : "Codex" }
}

func available(claudeEnabled: Bool, codexEnabled: Bool) -> [Harness] {
    func onPath(_ b: String) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(b)"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }
    var out: [Harness] = []
    if claudeEnabled, onPath("claude") { out.append(.claude) }
    if codexEnabled, onPath("codex") { out.append(.codex) }
    return out
}

func agent(for h: Harness) -> Agent { h == .claude ? .claudeCode : .codex }
```

UX rule:
- **0 available** → save the issue; don't offer a fix.
- **1 available** → a single "Fix it" button using that harness.
- **2 available** → "Fix with Claude" / "Fix with Codex" — pass **exactly one** harness to `handToAgent`.

## 4. The composer UI

Either drop in the default (`OuroborosUI.OuroborosMenuBarEntry(ouroboros:)`), or build your
own themed composer with two phases:

1. **Describe** — a multi-line description, a title field auto-filled from
   `IssueText.suggestTitle(description)` on every change *unless the user edited the title*
   (track a `titleEdited` flag), and the per-issue fix options: a "new worktree" toggle and
   a "merge into base / open a PR" choice.
2. **Confirm** — after `submit(...)` returns an `Issue`, show its file path and the fix
   buttons from step 3. Each button calls:

```swift
ouroboros.handToAgent(issue, options: FixOptions(worktree: worktreeOn, finish: chosenFinish))
```

Run `handToAgent` off the main thread (it shells out to git + the terminal):
`Task.detached { ouroboros.handToAgent(issue, options: opts) }`.

## 5. Entry point

Add a menu-bar command (and/or an in-app button) that opens the composer. A macOS menu
command is the most discoverable "report an issue" affordance:

```swift
CommandGroup(after: .appSettings) {
    Button("Report Issue…") { showComposer = true }
        .keyboardShortcut("i", modifiers: [.command, .shift])
}
```

## 6. Housekeeping

- Add `.ouroboros/` to the app repo's `.gitignore` (worktrees + temp launch scripts).
- Ensure `claude`/`codex`, `tmux`, Ghostty, and `gh` (only for PR finish) are on PATH.
- Non-Ghostty machines: use `TerminalLauncher(kind: .osDefault)` (Terminal.app) or
  `.custom` with your own `customLaunch` closure.

## Notes

- The seed prompt already tells the agent: this is one issue from an in-app composer;
  decide if it's actionable first, and if not, leave it blocked with a note. With a
  worktree it implements → verifies → merges back (or opens a PR); in place it commits on
  the current branch.
- Everything in the engine takes injectable runners, so you can unit-test your wiring
  without spawning anything (see the package's own tests for the pattern).
