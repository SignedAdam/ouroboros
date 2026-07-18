# Integrating Ouroboros (for a coding agent)

You are adding the Ouroboros "report an issue → fix it with an agent" flow to a macOS
Swift app. Follow these steps. Adapt names to the host app's conventions; keep the engine
calls identical.

## 1. Copy the package into your app

This Swift version lives in the multi-language `ouroboros` repo under `swift/`. SPM can't
depend on a subfolder of a repo by URL, and the whole point is that your app **owns a copy**
of the pattern — so copy `swift/` into your app as a local package:

```sh
# from your app's repo root, with the ouroboros repo checked out somewhere:
cp -R /path/to/ouroboros/swift Packages/Ouroboros
```

Then add it as a path dependency. **SPM gotcha:** a path dependency's identity is its
**directory name**, so a folder named `Ouroboros` gives `package: "Ouroboros"`:

```swift
dependencies: [
    .package(path: "Packages/Ouroboros"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "Ouroboros", package: "Ouroboros")]
    ),
]
```

(You could instead add the whole `ouroboros` repo as a git submodule and path-dep
`<submodule>/swift`, but then the SPM identity is `swift` — copying in as
`Packages/Ouroboros` reads better and keeps your app self-contained.)

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
                     terminal: TerminalLauncher(kind: .ghosttyCinemaWindow), baseBranch: base)
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

// The probe. ⚠ waitUntilExit PUMPS THE RUN LOOP: never call this from a SwiftUI
// body / the main thread — it re-enters the UI update cycle mid-render and segfaults.
func onPath(_ b: String) -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "command -v \(b)"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit(); return p.terminationStatus == 0
}

// So: probe ONCE, off-main, into observable state (at launch + when the composer
// opens), and make the getter the UI reads a PURE function of that cache:
// in your @Observable store —
var installedHarnessBinaries: Set<String> = []      // the cache the UI reads

func refreshHarnessAvailability() {                  // call at launch / composer open
    Task.detached(priority: .utility) {
        let found = Set(Harness.allCases.map(\.binary).filter { onPath($0) })
        await MainActor.run { self.installedHarnessBinaries = found }
    }
}

var availableHarnesses: [Harness] {                  // pure — safe in any view body
    var out: [Harness] = []
    if claudeEnabled, installedHarnessBinaries.contains("claude") { out.append(.claude) }
    if codexEnabled, installedHarnessBinaries.contains("codex") { out.append(.codex) }
    return out
}

func agent(for h: Harness) -> Agent { h == .claude ? .claudeCode : .codex }
```

Pin the purity with a test: empty cache + CLIs genuinely installed ⇒ `availableHarnesses`
is empty (proves the getter never probes live).

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
- Ensure `claude`/`codex` and Ghostty are on PATH (`tmux` only for `.ghosttyTmuxTab`;
  `gh` only for PR finish).
- Non-Ghostty machines: use `TerminalLauncher(kind: .osDefault)` (Terminal.app) or
  `.custom` with your own `customLaunch` closure.
- `.ghosttyCinemaWindow` (recommended default): one Ghostty window per fix — splash
  banner, then the agent runs live in it (user can type to it); the window closes
  itself when the agent exits. Launched via the Ghostty binary, never `open -na`
  (that adds the instance's default window as a second tab).
- `.ghosttyTmuxTab`: fixes stack as tabs in a dedicated `ouroboros` tmux session,
  never the user's own; the post-agent shell runs `zsh -f` (no rc files, so a
  .zshrc session picker can't hijack the tab). `sessionName:` renames the session.

## Notes

- The seed prompt already tells the agent: this is one issue from an in-app composer;
  decide if it's actionable first, and if not, leave it blocked with a note. With a
  worktree it implements → verifies → merges back (or opens a PR); in place it commits on
  the current branch.
- Everything in the engine takes injectable runners, so you can unit-test your wiring
  without spawning anything (see the package's own tests for the pattern).
